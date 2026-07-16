#!/usr/bin/env python3
"""Local server for the Claude usage widget.

Reads the Claude Code OAuth credentials from the macOS Keychain, refreshes the
access token when expired (persisting rotated tokens back to the Keychain, same
as Claude Code itself does), and proxies the usage endpoint to the widget page.
Tokens never leave this process and are never logged or sent to the page.
"""
import json
import subprocess
import threading
import time
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = 8737
SERVICE = "Claude Code-credentials"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
UA = "claude-cli/2.1.207 (external, cli)"
DIR = Path(__file__).resolve().parent

_lock = threading.Lock()
_cache = {"at": 0.0, "data": None}
CACHE_SECONDS = 30


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
    creds = keychain_read()
    o = creds["claudeAiOauth"]
    if o.get("expiresAt", 0) / 1000 > time.time() + 120:
        return o["accessToken"]
    return refresh_token(creds)


def fetch_usage():
    with _lock:
        if time.time() - _cache["at"] < CACHE_SECONDS and _cache["data"]:
            return _cache["data"]
        try:
            token = get_access_token()
            req = urllib.request.Request(USAGE_URL, headers={
                "Authorization": "Bearer " + token,
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": UA,
            })
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    raw = json.load(r)
            except urllib.error.HTTPError as e:
                if e.code == 401:  # stale token despite expiresAt — force refresh once
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
        }
        _cache.update(at=time.time(), data=data)
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

    def do_GET(self):
        if self.path == "/api/ping":
            self._send(200, b'{"ok":true}', "application/json")
        elif self.path == "/api/usage":
            try:
                body = json.dumps(fetch_usage()).encode()
                self._send(200, body, "application/json")
            except Exception as e:
                msg = json.dumps({"error": type(e).__name__}).encode()
                self._send(502, msg, "application/json")
        elif self.path in ("/", "/index.html"):
            html = (DIR / "widget.html").read_bytes()
            self._send(200, html, "text/html; charset=utf-8")
        else:
            self._send(404, b"not found", "text/plain")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
