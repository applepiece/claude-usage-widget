#!/usr/bin/env python3
"""Local server for the Claude usage widget.

Reads the Claude Code OAuth credentials from the macOS Keychain, refreshes the
access token when expired (persisting rotated tokens back to the Keychain, same
as Claude Code itself does), and proxies the usage endpoint to the widget page.
Tokens never leave this process and are never logged or sent to the page.
"""
import json
import shlex
import subprocess
import threading
import time
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

PORT = 8737
SERVICE = "Claude Code-credentials"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
PROFILE_URL = "https://api.anthropic.com/api/oauth/profile"
UA = "claude-cli/2.1.207 (external, cli)"
DIR = Path(__file__).resolve().parent

_lock = threading.Lock()
_oauth_lock = threading.Lock()
_cache = {"at": 0.0, "key": None, "data": None}
_account_lock = threading.Lock()
_profile_cache = {"at": 0.0, "key": None, "data": None, "ttl": 0.0}
CACHE_SECONDS = 30
PROFILE_CACHE_SECONDS = 30 * 60
# a failed lookup must not pin the fallback name for the full half hour, so it
# is held only briefly and retried once the network is back
PROFILE_RETRY_SECONDS = 60


def keychain_read():
    out = subprocess.run(
        ["security", "find-generic-password", "-s", SERVICE, "-w"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return json.loads(out)


def keychain_write(creds):
    user = subprocess.run(["whoami"], capture_output=True, text=True).stdout.strip()
    subprocess.run(
        ["security", "add-generic-password", "-U", "-s", SERVICE,
         "-a", user, "-w", json.dumps(creds)],
        check=True, capture_output=True,
    )


def refresh_token(creds):
    o = creds["claudeAiOauth"]
    body = json.dumps({
        "grant_type": "refresh_token",
        "refresh_token": o["refreshToken"],
        "client_id": CLIENT_ID,
    }).encode()
    req = urllib.request.Request(
        TOKEN_URL, data=body,
        headers={"Content-Type": "application/json", "User-Agent": UA},
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        tok = json.load(r)
    o["accessToken"] = tok["access_token"]
    if tok.get("refresh_token"):
        o["refreshToken"] = tok["refresh_token"]
    o["expiresAt"] = int((time.time() + tok.get("expires_in", 3600)) * 1000)
    if tok.get("refresh_token_expires_in"):
        o["refreshTokenExpiresAt"] = int(
            (time.time() + tok["refresh_token_expires_in"]) * 1000)
    keychain_write(creds)
    return o["accessToken"]


def get_access_token():
    # Account and usage requests arrive together, so only one may rotate tokens.
    with _oauth_lock:
        creds = keychain_read()
        o = creds["claudeAiOauth"]
        if o.get("expiresAt", 0) / 1000 > time.time() + 120:
            return o["accessToken"]
        return refresh_token(creds)


def api_headers(token):
    return {
        "Authorization": "Bearer " + token,
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": UA,
    }


def local_account():
    """Read only identity fields and never let credentials escape this process."""
    try:
        creds = keychain_read()
        oauth = creds["claudeAiOauth"]
    except Exception:
        return None

    account = {}
    try:
        raw = json.loads((Path.home() / ".claude.json").read_text())
        account = raw.get("oauthAccount") or {}
    except Exception:
        pass

    email = account.get("emailAddress") or ""
    return {
        "logged_in": True,
        "email": email,
        "name": email.split("@", 1)[0] if email else "Claude user",
        "plan": oauth.get("subscriptionType"),
        "org": account.get("organizationUuid"),
    }


def fetch_account():
    local = local_account()
    if local is None:
        return {"logged_in": False}

    cache_key = (local.get("email"), local.get("org"))
    with _account_lock:
        fresh = time.time() - _profile_cache["at"] < _profile_cache["ttl"]
        if fresh and _profile_cache["key"] == cache_key:
            profile = _profile_cache["data"] or {}
        else:
            profile = {}
            try:
                req = urllib.request.Request(
                    PROFILE_URL, headers=api_headers(get_access_token()))
                with urllib.request.urlopen(req, timeout=20) as response:
                    profile = json.load(response)
            except Exception:
                pass
            _profile_cache.update(
                at=time.time(), key=cache_key, data=profile,
                ttl=(PROFILE_CACHE_SECONDS if profile else PROFILE_RETRY_SECONDS))

    remote_account = profile.get("account") or {}
    organization = profile.get("organization") or {}
    # the profile endpoint is the account the token actually belongs to.
    # ~/.claude.json only records whatever was written at the last login, so on
    # a Mac that was re-authenticated as somebody else it names the wrong person
    email = remote_account.get("email") or local.get("email") or ""
    local["email"] = email
    local["name"] = (remote_account.get("full_name")
                     or (email.split("@", 1)[0] if email else "Claude user"))
    local["org"] = organization.get("name") or local.get("org")
    return {key: value for key, value in local.items() if value is not None}


def clear_caches():
    with _lock:
        _cache.update(at=0.0, key=None, data=None)
    with _account_lock:
        _profile_cache.update(at=0.0, key=None, data=None)


def claude_command():
    for path in (
            Path.home() / ".local/bin/claude",
            Path("/opt/homebrew/bin/claude"),
            Path("/usr/local/bin/claude")):
        if path.is_file():
            return str(path)
    return None


def fetch_usage():
    account = local_account()
    if account is None:
        with _lock:
            _cache.update(at=0.0, key=None, data=None)
        return {
            "five_hour": None,
            "seven_day": None,
            "limits": None,
            "fetched_at": time.time(),
            "logged_in": False,
        }
    cache_key = (account.get("email"), account.get("org"))
    with _lock:
        if (time.time() - _cache["at"] < CACHE_SECONDS
                and _cache["key"] == cache_key and _cache["data"]):
            return _cache["data"]
        try:
            token = get_access_token()
            req = urllib.request.Request(USAGE_URL, headers=api_headers(token))
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    raw = json.load(r)
            except urllib.error.HTTPError as e:
                if e.code == 401:  # stale token despite expiresAt — force refresh once
                    with _oauth_lock:
                        token = refresh_token(keychain_read())
                    req.headers["Authorization"] = "Bearer " + token
                    with urllib.request.urlopen(req, timeout=20) as r:
                        raw = json.load(r)
                else:
                    raise
        except Exception:
            # transient failure (keychain race, token rotation, network blip):
            # serve the last good snapshot instead of blanking the widget
            if _cache["data"]:
                return _cache["data"]
            raise
        data = {
            "five_hour": raw.get("five_hour"),
            "seven_day": raw.get("seven_day"),
            "limits": raw.get("limits"),
            "fetched_at": time.time(),
            "logged_in": True,
        }
        _cache.update(at=time.time(), key=cache_key, data=data)
        return data


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, value):
        self._send(code, json.dumps(value, separators=(",", ":")).encode(),
                   "application/json")

    def _allow_widget_post(self):
        return self.headers.get("X-Widget") == "1" and "Origin" not in self.headers

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/ping":
            self._send(200, b'{"ok":true}', "application/json")
        elif path == "/api/account":
            try:
                self._json(200, fetch_account())
            except Exception:
                self._json(200, {"logged_in": False})
        elif path == "/api/usage":
            try:
                body = json.dumps(fetch_usage()).encode()
                self._send(200, body, "application/json")
            except Exception as e:
                msg = json.dumps({"error": type(e).__name__}).encode()
                self._send(502, msg, "application/json")
        elif path in ("/", "/index.html"):
            html = (DIR / "widget.html").read_bytes()
            self._send(200, html, "text/html; charset=utf-8")
        else:
            self._send(404, b"not found", "text/plain")

    def do_POST(self):
        if not self._allow_widget_post():
            self._json(403, {"ok": False, "error": "forbidden"})
            return

        parsed = urlparse(self.path)
        dry = parse_qs(parsed.query).get("dry") == ["1"]
        if parsed.path == "/api/logout":
            binary = claude_command()
            if binary:
                command = [binary, "auth", "logout"]
                method = "claude"
            else:
                command = ["security", "delete-generic-password", "-s", SERVICE]
                method = "keychain"
            if dry:
                self._json(200, {
                    "ok": True, "dry": True, "would_run": command,
                })
                return
            try:
                subprocess.run(command, check=True, capture_output=True,
                               text=True, timeout=30)
                clear_caches()
                self._json(200, {"ok": True, "method": method})
            except Exception as error:
                self._json(500, {
                    "ok": False, "error": type(error).__name__,
                })
        elif parsed.path == "/api/login":
            binary = claude_command()
            if not binary:
                self._json(404, {"ok": False, "error": "claude_not_found"})
                return
            shell_command = shlex.quote(binary) + " auth login"
            command = [
                "osascript",
                "-e", 'tell application "Terminal" to activate',
                "-e", 'tell application "Terminal" to do script '
                      + json.dumps(shell_command),
            ]
            if dry:
                self._json(200, {
                    "ok": True, "dry": True, "would_run": command,
                })
                return
            try:
                subprocess.run(command, check=True, capture_output=True,
                               text=True, timeout=30)
                clear_caches()
                self._json(200, {"ok": True})
            except Exception as error:
                self._json(500, {
                    "ok": False, "error": type(error).__name__,
                })
        else:
            self._json(404, {"ok": False, "error": "not_found"})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
