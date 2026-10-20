#!/usr/bin/env python3
"""Local server for the Claude usage widget.

Reads the Claude Code OAuth credentials from the macOS Keychain and bridge
account files. Refreshes the machine login, proxies its official usage endpoint,
and caches minimal Messages probes for inference-only subscription tokens.
Tokens never leave this process and are never logged or sent to the page.
"""
import hashlib
import json
import math
import os
import select
import shlex
import shutil
import signal
import subprocess
import threading
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone
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
_backoff = {"until": 0.0, "key": None, "error": None}
CACHE_SECONDS = 30
BACKOFF_SECONDS = 30
# a rate limit needs real quiet to clear, and the widget only refreshes once a
# minute anyway, so nothing on screen is lost by waiting this long
RATE_LIMIT_BACKOFF_SECONDS = 5 * 60
PROFILE_CACHE_SECONDS = 30 * 60
# a failed lookup must not pin the fallback name for the full half hour, so it
# is held only briefly and retried once the network is back
PROFILE_RETRY_SECONDS = 60


class SignedOut(Exception):
    """The stored credential can no longer produce a token: logged out or revoked."""


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
    if not o.get("refreshToken"):
        raise SignedOut()
    body = json.dumps({
        "grant_type": "refresh_token",
        "refresh_token": o["refreshToken"],
        "client_id": CLIENT_ID,
    }).encode()
    req = urllib.request.Request(
        TOKEN_URL, data=body,
        headers={"Content-Type": "application/json", "User-Agent": UA},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            tok = json.load(r)
    except urllib.error.HTTPError as error:
        # 400 invalid_grant / 401 mean the refresh token itself is dead, so no
        # retry can help: report signed out instead of the last known identity
        if error.code in (400, 401):
            raise SignedOut() from error
        raise
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
    # `claude auth logout` empties claudeAiOauth but keeps the Keychain item,
    # because the MCP OAuth tokens live in it too. Treating that item as signed
    # in is what put the previous account's email from ~/.claude.json on screen.
    if not (oauth.get("accessToken") or oauth.get("refreshToken")):
        return None

    account = {}
    try:
        raw = json.loads((Path.home() / ".claude.json").read_text())
        account = raw.get("oauthAccount") or {}
    except Exception:
        pass

    email = account.get("emailAddress") or ""
    # Fingerprint of the live credential, used only as a cache key. ~/.claude.json
    # can name a different account than the token, so keying the profile cache on
    # its email would keep serving the previous account's profile after a switch.
    token = oauth.get("refreshToken") or oauth.get("accessToken") or ""
    return {
        "logged_in": True,
        "email": email,
        "name": email.split("@", 1)[0] if email else "Claude user",
        "plan": oauth.get("subscriptionType"),
        "org": account.get("organizationUuid"),
        "_fingerprint": hashlib.sha256(token.encode()).hexdigest()[:16],
    }


def account_key(fingerprint):
    """Derive a stable, non-secret key for the app's identity cache."""
    return hashlib.sha256(("account:" + fingerprint).encode()).hexdigest()[:12]


def fetch_account():
    local = local_account()
    if local is None:
        return {"logged_in": False}

    cache_key = local.get("_fingerprint")
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
            except SignedOut:
                _profile_cache.update(at=0.0, key=None, data=None)
                return {"logged_in": False}
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
    # profile_ok lets the app retry sooner instead of holding a fallback name
    # behind its own 10 minute staleness gate
    local["profile_ok"] = bool(remote_account)
    local.pop("_fingerprint", None)
    return {key: value for key, value in local.items() if value is not None}


def clear_caches():
    with _lock:
        _cache.update(at=0.0, key=None, data=None)
        # a fresh sign in deserves an immediate try, not the old account's backoff
        _backoff.update(until=0.0, key=None, error=None)
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


def signed_out_usage():
    return {
        "five_hour": None,
        "seven_day": None,
        "limits": None,
        "fetched_at": time.time(),
        "logged_in": False,
    }


def fetch_usage():
    account = local_account()
    if account is None:
        with _lock:
            _cache.update(at=0.0, key=None, data=None)
        return signed_out_usage()
    cache_key = account.get("_fingerprint")
    with _lock:
        if (time.time() - _cache["at"] < CACHE_SECONDS
                and _cache["key"] == cache_key and _cache["data"]):
            return _cache["data"]
        # Back off after a failure. Without this every caller reaches upstream,
        # so a 429 keeps being fed by the very requests waiting for it to clear.
        if time.time() < _backoff["until"] and _backoff["key"] == cache_key:
            raise _backoff["error"]
        try:
            token = get_access_token()
            req = urllib.request.Request(USAGE_URL, headers=api_headers(token))
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    raw = json.load(r)
            except urllib.error.HTTPError as e:
                if e.code == 401:  # stale token despite expiresAt: force refresh once
                    with _oauth_lock:
                        token = refresh_token(keychain_read())
                    req.headers["Authorization"] = "Bearer " + token
                    with urllib.request.urlopen(req, timeout=20) as r:
                        raw = json.load(r)
                else:
                    raise
        except SignedOut:
            _cache.update(at=0.0, key=None, data=None)
            return signed_out_usage()
        except Exception as error:
            # transient failure (keychain race, token rotation, network blip):
            # serve the last good snapshot instead of blanking the widget, but
            # only if it belongs to this account. Otherwise a failed fetch right
            # after a switch would show the previous person's numbers.
            if _cache["data"] and _cache["key"] == cache_key:
                return _cache["data"]
            delay = BACKOFF_SECONDS
            if getattr(error, "code", None) == 429:
                delay = RATE_LIMIT_BACKOFF_SECONDS
                try:  # honour Retry-After when the server sends one
                    delay = max(delay, int(error.headers.get("Retry-After")))
                except Exception:
                    pass
            _backoff.update(until=time.time() + delay, key=cache_key, error=error)
            raise
        data = {
            "five_hour": raw.get("five_hour"),
            "seven_day": raw.get("seven_day"),
            "limits": raw.get("limits"),
            "fetched_at": time.time(),
            "logged_in": True,
            "account_key": account_key(cache_key),
        }
        _cache.update(at=time.time(), key=cache_key, data=data)
        return data


# The multi-account API deliberately projects a fixed set of public fields. The
# registry and caches may hold credentials; neither is ever serialized directly.
_registry_lock = threading.Lock()
_account_states = {}
MESSAGES_URL = "https://api.anthropic.com/v1/messages"


def probe_seconds():
    try:
        return max(120, int(os.environ.get("CLAUDE_USAGE_PROBE_SECONDS", "600")))
    except ValueError:
        return 600


def public_text(value):
    return value if isinstance(value, str) and "sk-ant-" not in value else None


def codex_registry():
    env = Path(os.environ.get("CLAUDE_USAGE_CODEX_ENV",
                              str(Path.home() / ".config/codex-bridge/env")))
    value = None
    try:
        for line in env.read_text().splitlines():
            line = line.strip()
            if line.startswith("export "):
                line = line[7:].lstrip()
            if line.startswith("CODEX_BRIDGE_ACCOUNTS="):
                value = line.split("=", 1)[1].strip().strip("\"'")
    except (OSError, UnicodeError):
        pass
    if value is None:
        home = Path.home() / ".codex"
        value = "codex:" + str(home) if home.is_dir() else ""
    accounts = []
    labels = set()
    for entry in value.split(","):
        label, separator, home = entry.strip().partition(":")
        label, home = label.strip(), home.strip()
        if not separator or not public_text(label) or not home or label in labels:
            continue
        labels.add(label)
        if home == "~" or home.startswith("~/"):
            home = str(Path.home()) + home[1:]
        accounts.append({
            "id": "codex-" + label, "label": label, "provider": "codex",
            "source": "codex", "machine_login": False, "expires_at": None,
            "email": None, "plan": None, "_home": home,
        })
    return accounts


def codex_seconds():
    try:
        return max(60, int(os.environ.get("CLAUDE_USAGE_CODEX_SECONDS", "300")))
    except ValueError:
        return 300


def codex_app_server_read(home, timeout=20):
    # Delegate login handling to the CLI; auth.json is never read here.
    env = os.environ.copy()
    paths = [str(Path.home() / ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin",
             env.get("PATH", "")]
    search_path = os.pathsep.join(paths)
    binary = env.get("CLAUDE_USAGE_CODEX_BIN")
    if not binary:
        for path in (Path.home() / ".local/bin/codex", Path("/opt/homebrew/bin/codex"),
                     Path("/usr/local/bin/codex")):
            if path.is_file() and os.access(str(path), os.X_OK):
                binary = str(path)
                break
        else:
            binary = shutil.which("codex", path=search_path)
    if not binary:
        raise FileNotFoundError("codex_not_found")
    env.update(CODEX_HOME=str(home), PATH=os.pathsep.join([str(Path(binary).parent)] + paths))
    env.pop("OPENAI_API_KEY", None)
    env.pop("CODEX_API_KEY", None)
    deadline = time.monotonic() + timeout
    process = subprocess.Popen([binary, "app-server"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               env=env, start_new_session=True, bufsize=0)
    buffer = b""

    def send(message):
        data = (json.dumps(dict(jsonrpc="2.0", **message)) + "\n").encode()
        while data:
            written = process.stdin.write(data)
            if not written:
                raise BrokenPipeError("codex_stdin_closed")
            data = data[written:]

    def receive():
        nonlocal buffer
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("codex_timeout")
            if b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                message = json.loads(line)
                if not isinstance(message, dict):
                    raise ValueError("invalid_codex_message")
                if "id" in message:
                    return message
                continue
            ready, _, _ = select.select([process.stdout], [], [], remaining)
            if not ready:
                raise TimeoutError("codex_timeout")
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                raise BrokenPipeError("codex_stdout_closed")
            buffer += chunk

    try:
        send({"id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "claude-usage-widget", "version": "2.1"}}})
        while True:
            message = receive()
            if "error" in message:
                raise RuntimeError("codex_initialize_error")
            if message.get("id") == 1:
                break
        send({"method": "initialized"})
        send({"id": 2, "method": "account/read", "params": {}})
        send({"id": 3, "method": "account/rateLimits/read"})
        results = {}
        while len(results) < 2:
            message = receive()
            request_id = message.get("id")
            if request_id == 2 and ("error" in message or not (message.get("result") or {}).get("account")):
                raise SignedOut()
            if "error" in message:
                raise RuntimeError("codex_rpc_error")
            if request_id in (2, 3):
                result = message.get("result")
                if not isinstance(result, dict):
                    raise ValueError("invalid_codex_result")
                results[request_id] = result
        return results[2], results[3]
    finally:
        try:
            process.stdin.close()
        except OSError:
            pass
        try:
            process.terminate()
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass
        # Also reap descendants if the app-server's parent exited first.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        process.stdout.close()


def account_registry():
    directory = Path(os.environ.get("CLAUDE_USAGE_ACCOUNTS_DIR",
                                   "~/.config/claude-bridge/accounts")).expanduser()
    env = Path(os.environ.get("CLAUDE_USAGE_BRIDGE_ENV",
                             "~/.config/claude-bridge/env")).expanduser()
    order = []
    try:
        for line in env.read_text().splitlines():
            line = line.strip()
            if line.startswith("export "):
                line = line[7:].lstrip()
            if line.startswith("CLAUDE_BRIDGE_ACCOUNTS="):
                value = line.split("=", 1)[1].strip().strip("\"'")
                order = [entry.split(":", 1)[0] for entry in value.split(",")]
    except (OSError, UnicodeError):
        pass
    accounts = []
    for path in sorted(directory.glob("*.token")):
        label = path.stem
        if not public_text(label):
            continue
        try:
            token = path.read_text().strip()
            # Never send a malformed/multiline credential as an HTTP header.
            if not token.startswith("sk-ant-oat01-") or any(c.isspace() for c in token):
                token = ""
        except (OSError, UnicodeError):
            token = ""
        try:
            metadata = json.loads(path.with_suffix(".json").read_text())
            if not isinstance(metadata, dict):
                metadata = {}
        except (OSError, ValueError, UnicodeError):
            metadata = {}
        accounts.append({
            "id": label, "label": label,
            "email": public_text(metadata.get("email")),
            "plan": public_text(metadata.get("plan")),
            "expires_at": public_text(metadata.get("expires_at")),
            "org_uuid": public_text(metadata.get("org_uuid")),
            "source": "token", "machine_login": False, "_token": token,
        })
    ranks = {label: index for index, label in reversed(list(enumerate(order)))}
    accounts.sort(key=lambda a: (ranks.get(a["id"], len(order)), a["id"]))

    try:
        local = local_account()
    except Exception:
        local = None
    if local is not None:
        try:
            profile = fetch_account()
        except Exception:
            profile = {"logged_in": False}
        if profile.get("logged_in"):
            # fetch_account has already tried the profile endpoint, and keys its
            # cache by the live credential rather than the possibly stale file.
            with _account_lock:
                remote = (_profile_cache.get("data") or {})
                org = ((remote.get("organization") or {}).get("uuid")
                       if _profile_cache.get("key") == local.get("_fingerprint") else None)
            org = org or local.get("org")
            match = next((a for a in accounts
                          if org and a["org_uuid"] == org), None)
            machine = match if match is not None else {
                "id": "machine", "label": "This Mac", "expires_at": None,
            }
            machine.update(source="keychain", machine_login=True,
                           _credential=local.get("_fingerprint"))
            # The sidecar is a better fallback than an unverified local email.
            if profile.get("profile_ok") or match is None:
                machine.update(email=public_text(profile.get("email")),
                               plan=public_text(profile.get("plan")))
            elif profile.get("plan"):
                machine["plan"] = public_text(profile.get("plan"))
            if match is None:
                accounts.append(machine)
    for account in accounts:
        account["provider"] = "claude"
    return accounts + codex_registry()


def valid_percent(value):
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
        return number if math.isfinite(number) and 0 <= number <= 100 else None
    except (TypeError, ValueError, OverflowError):
        return None


def codex_windows(limits, rollout=False):
    windows = {"five_hour": None, "seven_day": None, "limits": None}
    if not isinstance(limits, dict):
        return windows
    for key in ("primary", "secondary"):
        raw = limits.get(key)
        if not isinstance(raw, dict):
            continue
        duration = raw.get("window_minutes" if rollout else "windowDurationMins")
        name = "five_hour" if duration == 300 else "seven_day" if duration == 10080 else None
        value = valid_percent(raw.get("used_percent" if rollout else "usedPercent"))
        if name is None or value is None:
            continue
        reset = None
        try:
            seconds = float(raw.get("resets_at" if rollout else "resetsAt"))
            if math.isfinite(seconds):
                reset = datetime.fromtimestamp(seconds, timezone.utc).isoformat().replace("+00:00", "Z")
        except (ValueError, TypeError, OverflowError, OSError):
            pass
        windows[name] = {"utilization": value, "resets_at": reset,
                         "status": "rejected" if value >= 100 else "allowed"}
    return windows


def codex_live_snapshot(result):
    by_id = result.get("rateLimitsByLimitId")
    if isinstance(by_id, dict) and "codex" in by_id:
        limits = by_id["codex"]
    else:
        limits = result.get("rateLimits")
        if isinstance(limits, dict) and limits.get("limitId") not in (None, "codex"):
            limits = None
    return codex_windows(limits)


def codex_plan(value):
    value = public_text(value)
    if not value or value == "unknown":
        return None
    return {"prolite": "pro lite", "promax": "pro max"}.get(value, value.replace("_", " "))


def codex_rollout_snapshot(home, state):
    newest = None
    for directory, _, files in os.walk(str(Path(home) / "sessions")):
        for name in files:
            if not (name.startswith("rollout-") and name.endswith(".jsonl")):
                continue
            path = Path(directory) / name
            try:
                stat = path.stat()
            except OSError:
                continue
            key = (str(path), stat.st_mtime_ns, stat.st_size)
            if newest is None or key[1] > newest[1]:
                newest = key
    if newest != state.get("rollout_key"):
        snapshot = None
        if newest is not None:
            try:
                with Path(newest[0]).open("rb") as file:
                    start = max(0, newest[2] - 256 * 1024)
                    file.seek(start)
                    tail = file.read(256 * 1024)
                if start:
                    tail = tail.partition(b"\n")[2]
                for line in reversed(tail.splitlines()):
                    if b'"rate_limits"' not in line:
                        continue
                    try:
                        event = json.loads(line)
                        payload = event.get("payload") or {}
                        limits = payload.get("rate_limits") or {}
                        if (event.get("type") != "event_msg" or payload.get("type") != "token_count"
                                or limits.get("limit_id") != "codex"):
                            continue
                        as_of = datetime.fromisoformat(event["timestamp"].replace("Z", "+00:00")).timestamp()
                        if not math.isfinite(as_of):
                            continue
                        snapshot = codex_windows(limits, rollout=True)
                        snapshot.update(as_of=as_of, fetched_at=time.time(), quota_source="rollout")
                        break
                    except (ValueError, TypeError, AttributeError, KeyError, OverflowError, OSError):
                        continue
            except OSError:
                pass
        state.update(rollout_key=newest, rollout_snapshot=snapshot)
    return state.get("rollout_snapshot")


def fetch_codex_snapshot(account, state, now):
    if now >= state["next_at"]:
        state["attempt_at"] = now
        try:
            account_result, limits_result = codex_app_server_read(account["_home"])
            info = account_result.get("account")
            if not info:
                raise SignedOut()
            email = public_text(info.get("email"))
            if email != state.get("email"):
                state["snapshot"] = None
            state.update(email=email, plan=codex_plan(info.get("planType")))
            snapshot = codex_live_snapshot(limits_result)
            fetched = time.time()
            snapshot.update(fetched_at=fetched, as_of=fetched, quota_source="live")
            state.update(snapshot=snapshot, state="ok", next_at=time.time() + codex_seconds())
        except SignedOut:
            state.update(snapshot=None, email=None, plan=None,
                         state="token_rejected", next_at=time.time() + 300)
        except Exception:
            state.update(state="stale" if state["snapshot"] else "error", next_at=time.time() + 300)
    if state["state"] == "token_rejected":
        return {}, "token_rejected"
    rollout = codex_rollout_snapshot(account["_home"], state)
    snapshot = state["snapshot"] or {}
    status = state["state"]
    if rollout and (status != "ok" or rollout["as_of"] > snapshot.get("as_of", 0)):
        snapshot = dict(rollout)
        status = "ok" if status == "ok" else "stale"
        for key in ("five_hour", "seven_day"):
            window = snapshot.get(key)
            if window and window.get("resets_at"):
                reset = datetime.fromisoformat(window["resets_at"].replace("Z", "+00:00")).timestamp()
                if reset < now:
                    snapshot[key] = dict(window, utilization=0, resets_at=None, status="allowed")
    return snapshot, status


def clean_window(raw):
    if not isinstance(raw, dict):
        return None
    value = valid_percent(raw.get("utilization"))
    if value is None:
        return None
    return {"utilization": value, "resets_at": public_text(raw.get("resets_at")),
            "status": public_text(raw.get("status"))}


def parse_probe_headers(headers, rejected=False):
    # HTTPMessage is case insensitive; normalize plain mappings for tests too.
    headers = {key.lower(): value for key, value in headers.items()}
    windows = {}
    for short, name in (("5h", "five_hour"), ("7d", "seven_day")):
        prefix = "anthropic-ratelimit-unified-" + short + "-"
        try:
            fraction = float(headers.get(prefix + "utilization", ""))
            value = valid_percent(fraction * 100)
        except (ValueError, TypeError, OverflowError):
            value = None
        if value is None:
            windows[name] = None
            continue
        reset = None
        try:
            seconds = float(headers.get(prefix + "reset", ""))
            if math.isfinite(seconds):
                reset = datetime.fromtimestamp(seconds, timezone.utc).isoformat().replace("+00:00", "Z")
        except (ValueError, TypeError, OverflowError, OSError):
            pass
        status = headers.get(prefix + "status")
        if status not in ("allowed", "allowed_warning", "rejected"):
            status = None
        windows[name] = {"utilization": value, "resets_at": reset,
                         "status": "rejected" if rejected else status}
    if not any(windows.values()):
        raise ValueError("missing_usage_headers")
    windows["limits"] = None
    return windows


def probe_usage(token):
    if not token:
        raise SignedOut()
    body = json.dumps({
        "model": os.environ.get("CLAUDE_USAGE_PROBE_MODEL", "claude-haiku-4-5-20251001"),
        "max_tokens": 1,
        "system": "You are Claude Code, Anthropic's official CLI for Claude.",
        "messages": [{"role": "user", "content": "."}],
    }).encode()
    headers = api_headers(token)
    headers.update({"anthropic-version": "2023-06-01", "Content-Type": "application/json"})
    request = urllib.request.Request(MESSAGES_URL, data=body, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return parse_probe_headers(response.headers)
    except urllib.error.HTTPError as error:
        try:
            if error.code == 429:
                return parse_probe_headers(error.headers, rejected=True)
            if error.code in (401, 403):
                raise SignedOut() from None
            raise
        finally:
            error.close()


def official_usage(credential):
    def same_login():
        local = local_account()
        return local is not None and local.get("_fingerprint") == credential

    # Switching the Keychain while a request is in flight must never put the
    # new login's numbers under the previous account's label.
    if not same_login():
        raise ValueError("credential_changed")
    request = urllib.request.Request(USAGE_URL, headers=api_headers(get_access_token()))
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = json.load(response)
    except urllib.error.HTTPError as error:
        error.close()
        if error.code != 401:
            raise
        with _oauth_lock:
            token = refresh_token(keychain_read())
        request.headers["Authorization"] = "Bearer " + token
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = json.load(response)
    if not same_login():
        raise ValueError("credential_changed")
    data = {"five_hour": clean_window(raw.get("five_hour")),
            "seven_day": clean_window(raw.get("seven_day")), "limits": None}
    # Scope/model labels are explicitly selected, never raw upstream dictionaries.
    if isinstance(raw.get("limits"), list):
        limits = []
        for limit in raw["limits"]:
            if not isinstance(limit, dict):
                continue
            percent = valid_percent(limit.get("percent", limit.get("utilization")))
            if percent is None:
                continue
            item = {"percent": percent}
            for key in ("kind", "group", "resets_at"):
                item[key] = public_text(limit.get(key))
            scope = limit.get("scope") or {}
            model = (scope.get("model") or {}) if isinstance(scope, dict) else {}
            if isinstance(model, dict):
                name = public_text(model.get("display_name"))
                if name:
                    item["scope"] = {"model": {"display_name": name}}
            limits.append(item)
        data["limits"] = limits or None
    if not any(data.values()):
        raise ValueError("missing_usage")
    return data


def account_state(account):
    with _registry_lock:
        return _account_states.setdefault(account["id"], {
            "lock": threading.Lock(), "identity": None, "snapshot": None,
            "state": "error", "next_at": 0.0, "attempt_at": 0.0,
        })


def fetch_registered_account(account, force=False):
    state = account_state(account)
    with state["lock"]:
        # A replacement credential must not inherit another login's snapshot.
        is_codex = account.get("provider") == "codex"
        identity = (("codex", account["_home"]) if is_codex else
                    (account["source"], account.get("_credential"),
                     hashlib.sha256(account.get("_token", "").encode()).digest()))
        if state["identity"] != identity:
            state.update(identity=identity, snapshot=None, state="error", next_at=0.0, attempt_at=0.0,
                         email=None, plan=None, rollout_key=None, rollout_snapshot=None)
        now = time.time()
        # Explicit refresh can bypass the normal TTL only after 60s. Failures
        # retain their backoff, so clicking Refresh cannot hammer a rejected API.
        if force and state["state"] == "ok" and now - state["attempt_at"] >= 60:
            state["next_at"] = 0.0
        if is_codex:
            snapshot, status = fetch_codex_snapshot(account, state, now)
        elif now >= state["next_at"]:
            state["attempt_at"] = now
            used_probe = account["source"] == "token"
            try:
                if used_probe:
                    snapshot = probe_usage(account.get("_token"))
                else:
                    try:
                        snapshot = official_usage(account.get("_credential"))
                    except Exception:
                        if not account.get("_token"):
                            raise
                        used_probe = True
                        snapshot = probe_usage(account["_token"])
                snapshot["fetched_at"] = time.time()
                snapshot.update(as_of=snapshot["fetched_at"], quota_source="probe" if used_probe else "official")
                state.update(snapshot=snapshot, state="ok",
                             next_at=time.time() + (probe_seconds() if used_probe else 60))
            except SignedOut:
                state.update(snapshot=None, state="token_rejected", next_at=time.time() + 300)
            except Exception:
                state.update(state="stale" if state["snapshot"] else "error",
                             next_at=time.time() + 300)
        if not is_codex:
            snapshot, status = state["snapshot"] or {}, state["state"]
        result = {key: account.get(key) for key in
                  ("id", "label", "email", "plan", "source", "machine_login", "expires_at", "provider")}
        if is_codex:
            result.update(email=state.get("email"), plan=state.get("plan"))
        result.update({key: snapshot.get(key) for key in
                       ("five_hour", "seven_day", "limits", "fetched_at", "as_of", "quota_source")})
        result["state"] = status
        return result


def fetch_accounts():
    return {"accounts": [fetch_registered_account(a) for a in account_registry()],
            "fetched_at": time.time()}


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
        return (self._host_is_local()
                and self.headers.get("X-Widget") == "1"
                and "Origin" not in self.headers)

    def _host_is_local(self):
        # the socket is bound to 127.0.0.1, but a rebound DNS name still resolves
        # there: without this, a page could read the account email over GET
        host = (self.headers.get("Host") or "").split(":")[0].strip("[]")
        return host in ("127.0.0.1", "localhost", "::1", "")

    def do_GET(self):
        if not self._host_is_local():
            self._json(403, {"error": "forbidden"})
            return
        path = urlparse(self.path).path
        if path == "/api/ping":
            self._send(200, b'{"ok":true}', "application/json")
        elif path == "/api/accounts":
            try:
                self._json(200, fetch_accounts())
            except Exception:
                self._json(503, {"error": "accounts_unavailable"})
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
                # carry the upstream status: a bare "HTTPError" cannot tell an
                # expired token from a rate limit when diagnosing over ssh
                detail = {"error": type(e).__name__}
                code = getattr(e, "code", None)
                if code is not None:
                    detail["status"] = code
                reason = getattr(e, "reason", None)
                if reason is not None:
                    detail["reason"] = str(reason)[:120]
                self._send(502, json.dumps(detail).encode(), "application/json")
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
        # Any mention of dry means dry. Matching the exact list ["1"] failed
        # open: `?dry=1&dry=1` and `?dry=1&x=y` both parse to something else and
        # would have run the real logout from a URL that visibly says dry=1.
        dry = "dry" in parse_qs(parsed.query, keep_blank_values=True)
        if parsed.path == "/api/refresh":
            account_id = parse_qs(parsed.query).get("account", [None])[0]
            account = next((a for a in account_registry() if a["id"] == account_id), None)
            if account is None:
                self._json(404, {"error": "not_found"})
            else:
                self._json(200, fetch_registered_account(account, force=True))
        elif parsed.path == "/api/logout":
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
                # hold the oauth lock so a refresh cannot be mid-flight and
                # write the rotated credentials back after logout removed them
                with _oauth_lock:
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
