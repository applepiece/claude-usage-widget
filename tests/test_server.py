"""Offline API, registry and cache contracts; no sockets or real credentials."""
import io
import builtins
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from datetime import datetime, timezone
from email.message import Message
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse
from urllib.response import addinfourl

import server


HEADERS = {
    "anthropic-organization-id": "org-pho",
    "anthropic-ratelimit-unified-5h-utilization": "0.15",
    "anthropic-ratelimit-unified-5h-reset": "1792466400",
    "anthropic-ratelimit-unified-5h-status": "allowed",
    "anthropic-ratelimit-unified-7d-utilization": "0.82",
    "anthropic-ratelimit-unified-7d-reset": "1792810800",
    "anthropic-ratelimit-unified-7d-status": "allowed_warning",
}
PUBLIC_KEYS = {"id", "label", "email", "plan", "source", "machine_login",
               "five_hour", "seven_day", "limits", "state", "fetched_at", "expires_at",
               "provider", "as_of", "quota_source"}
GEMINI_USAGE = json.loads('''{"conversation_id":"","status":"SUCCESS","response":"Gemini Models\\tWeekly Limit Remaining\\t99%\\t2026-12-01T10:15:06Z\\n...","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},"command":{"name":"usage","data":{"description":"...","groups":[{"name":"Gemini Models","description":"Models within this group: Gemini 4 Neon, ...","buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","description":"...","window":"weekly","remaining_fraction":0.989983320236206,"reset_time":"2026-12-01T10:15:06Z"},{"id":"gemini-5h","name":"Five Hour Limit Remaining","description":"...","window":"5h","remaining_fraction":0.9899333119392395,"reset_time":"2026-11-24T15:15:06Z"}]},{"name":"Claude and GPT models","description":"Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B","buckets":[{"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-12-01T10:15:18Z"},{"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-11-24T15:15:18Z"}]}]}}}''')


class Response(io.BytesIO):
    def __init__(self, data=None, headers=None):
        super().__init__(json.dumps(data or {}).encode())
        self.headers = headers if headers is not None else HEADERS


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.directory = self.home / "accounts"
        self.directory.mkdir()
        self.envfile = self.home / "env"
        self.codex_env = self.home / "codex-env"
        self.gemini_env = self.home / "gemini-env"
        self.enter(patch.dict(os.environ, {
            "CLAUDE_USAGE_ACCOUNTS_DIR": str(self.directory),
            "CLAUDE_USAGE_BRIDGE_ENV": str(self.envfile),
            "CLAUDE_USAGE_PROBE_SECONDS": "600",
            "CLAUDE_USAGE_PROBE_MODEL": "claude-haiku-4-5-20251001",
            "CLAUDE_USAGE_CODEX_ENV": str(self.codex_env),
            "CLAUDE_USAGE_CODEX_BIN": str(self.home / "missing-codex"),
            "CLAUDE_USAGE_CODEX_SECONDS": "300",
            "CLAUDE_USAGE_GEMINI_ENV": str(self.gemini_env),
            "CLAUDE_USAGE_AGY": str(self.home / "missing-agy"),
            "CLAUDE_USAGE_GEMINI_SECONDS": "600",
        }))
        self.enter(patch.object(Path, "home", return_value=self.home))
        self.keychain = self.enter(patch.object(server, "keychain_read", side_effect=server.SignedOut()))
        self.real_run = subprocess.run
        self.subprocess = self.enter(patch.object(server.subprocess, "run", side_effect=AssertionError("real subprocess forbidden")))
        self.real_popen = subprocess.Popen
        self.popen = self.enter(patch.object(server.subprocess, "Popen", side_effect=AssertionError("real codex forbidden")))
        self.urlopen = self.enter(patch.object(server.urllib.request, "urlopen", side_effect=AssertionError("unmocked network forbidden")))
        self.clock = self.enter(patch.object(server.time, "time", return_value=10000.0))
        server._account_states.clear()
        server.clear_caches()

    def enter(self, mock):
        value = mock.start()
        self.addCleanup(mock.stop)
        return value

    def token(self, label="pho", org="org-pho", **extra):
        # Synthetic fixture only. Tests never read a real token or Keychain.
        (self.directory / (label + ".token")).write_text("sk-ant-oat01-fixture-" + label + "\n")
        metadata = {"label": label, "email": label + "@example.com", "org_uuid": org,
                    "expires_at": "2027-10-20T00:00:00Z"}
        metadata.update(extra)
        (self.directory / (label + ".json")).write_text(json.dumps(metadata))
        return next(a for a in server.account_registry() if a["id"] == label)

    def login(self, org="org-pho", local_org="old-org"):
        self.keychain.side_effect = None
        self.keychain.return_value = {"claudeAiOauth": {"accessToken": "fixture-access", "refreshToken": "fixture-refresh",
                                                      "expiresAt": 9999999999999, "subscriptionType": "max"}}
        (self.home / ".claude.json").write_text(json.dumps({"oauthAccount": {
            "organizationUuid": local_org, "emailAddress": "old@example.com"}}))
        self.urlopen.side_effect = None
        self.urlopen.return_value = Response({"account": {"email": "live@example.com", "full_name": "Live"},
                                               "organization": {"uuid": org, "name": "Remote"}})

    def request(self, method, path, headers=None):
        handler = object.__new__(server.Handler)
        handler.request_version = "HTTP/1.1"
        handler.command = method
        handler.path = path
        handler.requestline = method + " " + path + " HTTP/1.1"
        handler.headers = Message()
        for key, value in (headers or {"Host": "127.0.0.1:8737"}).items():
            handler.headers[key] = value
        handler.wfile = io.BytesIO()
        getattr(handler, "do_" + method)()
        head, body = handler.wfile.getvalue().split(b"\r\n\r\n", 1)
        return int(head.split()[1]), body

    def probe_response(self, headers=None):
        self.urlopen.side_effect = lambda *a, **k: Response(headers=headers)

    def codex(self, label="pro"):
        home = self.home / ("codex-" + label)
        home.mkdir(exist_ok=True)
        self.codex_env.write_text("CODEX_BRIDGE_ACCOUNTS=" + label + ":" + str(home) + "\n")
        return next(a for a in server.account_registry() if a["id"] == "codex-" + label)

    def codex_live(self, email="pro@example.com", plan="prolite", edu=False):
        primary = {"usedPercent": 1 if edu else 12, "windowDurationMins": 300 if edu else 10080,
                   "resetsAt": 1792479781 if edu else 1792883421}
        secondary = {"usedPercent": 0, "windowDurationMins": 10080, "resetsAt": 1793066581} if edu else None
        limits = {"limitId": "codex", "primary": primary, "secondary": secondary,
                  "credits": {"secret": "fixture-credits"}}
        return ({"account": {"type": "chatgpt", "email": email, "planType": plan},
                 "workspaceRouting": {"secret": "fixture-routing"}},
                {"rateLimits": limits, "rateLimitsByLimitId": {"codex": limits},
                 "accountId": "fixture-account-id", "rateLimitResetCredits": {"fixture-reset-id": 1},
                 "rateLimitUpsell": "fixture-upsell"})

    def rollout(self, account, as_of=9900, used=34, reset=20000, name="rollout-fixture.jsonl"):
        path = Path(account["_home"]) / "sessions/2026/10/20" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        event = {"timestamp": datetime.fromtimestamp(as_of, timezone.utc).isoformat().replace("+00:00", "Z"),
                 "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {
                     "limit_id": "codex", "primary": {"used_percent": used, "window_minutes": 300,
                                                       "resets_at": reset},
                     "secondary": {"used_percent": 8, "window_minutes": 10080, "resets_at": 20000}}}}
        path.write_text(json.dumps(event) + "\n")
        return path

    def fake_codex(self, body):
        path = self.home / "fake-app-server"
        path.write_text("#!" + sys.executable + "\n" + body)
        path.chmod(0o700)
        return patch.dict(os.environ, {"CLAUDE_USAGE_CODEX_BIN": str(path)})

    def gemini(self, label="pho", token=True):
        home = self.home / ("gemini-" + label)
        home.mkdir(exist_ok=True)
        self.gemini_env.write_text("GEMINI_BRIDGE_ACCOUNTS=" + label + ":" + str(home) + "\n")
        if token:
            path = home / ".gemini/antigravity-cli/antigravity-oauth-token"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("synthetic-gemini-token")
        return server.gemini_registry()[0]

    def fake_agy(self, result=None, exit_code=0):
        path = self.home / "fake-agy"
        marker = self.home / "agy-executed"
        path.write_text("#!" + sys.executable + "\n" +
                        "import os, sys\nfrom pathlib import Path\n" +
                        "Path(" + repr(str(marker)) + ").write_text('executed')\n" +
                        "assert sys.argv[1:] == ['-p', '/usage', '--output-format', 'json']\n" +
                        "assert Path.cwd() == Path(os.environ['HOME']).resolve()\n" +
                        "assert os.environ['AGY_CLI_FORCE_FILE_TOKEN_STORAGE'] == '1'\n" +
                        "assert sys.stdin.read() == ''\n" +
                        "print('https://fixture.invalid/oauth?secret=fixture-private')\n" +
                        "print('fixture-private-stderr', file=sys.stderr)\n" +
                        "print('[]')\n" +
                        "print(" + repr(json.dumps(GEMINI_USAGE if result is None else result)) + ")\n" +
                        "print('trailing non-json')\n" +
                        "sys.exit(" + str(exit_code) + ")\n")
        path.chmod(0o700)
        self.enter(patch.dict(os.environ, {"CLAUDE_USAGE_AGY": str(path)}))
        self.subprocess.side_effect = self.real_run
        self.popen.side_effect = self.real_popen
        return path

    def test_registry_order_from_bridge_env_then_alphabetical(self):
        for label in ("zebra", "mahidol", "kkpk", "pho", "apple"):
            self.token(label, "org-" + label)
        self.envfile.write_text("# order\nexport CLAUDE_BRIDGE_ACCOUNTS='pho:/x,kkpk:/y,missing:/z,mahidol:/q'\n")
        self.assertEqual([a["id"] for a in server.account_registry()], ["pho", "kkpk", "mahidol", "apple", "zebra"])

    def test_registry_without_env_is_alphabetical(self):
        self.token("pho"); self.token("kkpk")
        self.assertEqual([a["id"] for a in server.account_registry()], ["kkpk", "pho"])

    def test_profile_uuid_merges_keychain_and_overrides_stale_local_uuid(self):
        self.token("pho"); self.token("kkpk", "org-kkpk")
        self.login(local_org="org-kkpk")
        accounts = server.account_registry()
        self.assertEqual(len(accounts), 2)
        machine = next(a for a in accounts if a["machine_login"])
        self.assertEqual((machine["id"], machine["source"], machine["email"]), ("pho", "keychain", "live@example.com"))
        self.assertEqual(self.urlopen.call_args.args[0].full_url, server.PROFILE_URL)

    def test_failed_profile_uses_local_org_and_sidecar_email(self):
        self.token()
        self.login(local_org="org-pho")
        self.urlopen.side_effect = URLError("offline")
        account = server.account_registry()[0]
        self.assertEqual(account["id"], "pho")
        self.assertTrue(account["machine_login"])
        self.assertEqual(account["email"], "pho@example.com")

    def test_unmatched_keychain_is_machine(self):
        self.token(); self.login(org="other-org")
        accounts = server.account_registry()
        self.assertEqual([a["id"] for a in accounts], ["pho", "machine"])
        self.assertTrue(accounts[-1]["machine_login"])

    def test_signed_out_keychain_contributes_nothing(self):
        self.assertEqual(server.account_registry(), [])
        self.keychain.side_effect = None
        self.keychain.return_value = {"claudeAiOauth": {}}
        self.assertEqual(server.account_registry(), [])
        self.urlopen.assert_not_called()

    def test_bad_or_missing_sidecar_does_not_hide_token(self):
        self.token()
        (self.directory / "pho.json").write_text("broken")
        account = server.account_registry()[0]
        self.assertIsNone(account["email"])
        self.assertEqual(account["id"], "pho")

    def test_probe_header_fractions_and_unix_resets(self):
        parsed = server.parse_probe_headers({k.upper(): v for k, v in HEADERS.items()})
        self.assertEqual(parsed["five_hour"], {"utilization": 15.0, "resets_at": "2026-10-20T03:20:00Z", "status": "allowed"})
        self.assertEqual(parsed["seven_day"]["utilization"], 82.0)
        self.assertNotIn("anthropic-organization-id", parsed)

    def test_team_has_no_weekly_window(self):
        parsed = server.parse_probe_headers({k: v for k, v in HEADERS.items() if "7d" not in k})
        self.assertIsNone(parsed["seven_day"])
        self.assertEqual(parsed["five_hour"]["utilization"], 15)

    def test_zero_is_real_data_but_invalid_numbers_are_missing(self):
        for value in ("nan", "inf", "-0.1", "1.01", "invalid"):
            with self.subTest(value=value):
                headers = dict(HEADERS)
                headers["anthropic-ratelimit-unified-7d-utilization"] = value
                self.assertIsNone(server.parse_probe_headers(headers)["seven_day"])
        headers = dict(HEADERS)
        headers["anthropic-ratelimit-unified-5h-utilization"] = "0"
        headers["anthropic-ratelimit-unified-5h-reset"] = "not-a-time"
        parsed = server.parse_probe_headers(headers)
        self.assertEqual(parsed["five_hour"]["utilization"], 0)
        self.assertIsNone(parsed["five_hour"]["resets_at"])
        with self.assertRaises(ValueError):
            server.parse_probe_headers({})

    def test_probe_request_body_headers_and_configurable_model(self):
        account = self.token()
        self.probe_response()
        with patch.dict(os.environ, {"CLAUDE_USAGE_PROBE_MODEL": "fixture-model"}):
            result = server.fetch_registered_account(account)
        request = self.urlopen.call_args.args[0]
        body = json.loads(request.data)
        self.assertEqual(request.full_url, server.MESSAGES_URL)
        self.assertEqual(body, {"model": "fixture-model", "max_tokens": 1,
                                "system": "You are Claude Code, Anthropic's official CLI for Claude.",
                                "messages": [{"role": "user", "content": "."}]})
        self.assertEqual(request.get_header("Anthropic-version"), "2023-06-01")
        self.assertEqual(request.get_header("Anthropic-beta"), "oauth-2025-04-20")
        self.assertEqual(result["state"], "ok")

    def test_429_with_headers_is_rejected_data(self):
        account = self.token()
        self.urlopen.side_effect = HTTPError(server.MESSAGES_URL, 429, "limited", HEADERS, io.BytesIO())
        result = server.fetch_registered_account(account)
        self.assertEqual(result["state"], "ok")
        self.assertEqual(result["five_hour"]["status"], "rejected")
        self.assertEqual(result["seven_day"]["utilization"], 82)

    def test_429_without_headers_is_error_and_backs_off(self):
        account = self.token()
        self.urlopen.side_effect = HTTPError(server.MESSAGES_URL, 429, "limited", {}, io.BytesIO())
        self.assertEqual(server.fetch_registered_account(account)["state"], "error")
        self.clock.return_value += 299
        server.fetch_registered_account(account, force=True)
        self.assertEqual(self.urlopen.call_count, 1)

    def test_401_and_403_are_token_rejected_without_snapshot(self):
        account = self.token()
        for code in (401, 403):
            with self.subTest(code=code):
                server._account_states.clear()
                self.urlopen.side_effect = HTTPError(server.MESSAGES_URL, code, "denied", {}, io.BytesIO())
                result = server.fetch_registered_account(account)
                self.assertEqual(result["state"], "token_rejected")
                self.assertIsNone(result["five_hour"])
                self.assertIsNone(result["fetched_at"])

    def test_rejected_token_clears_previous_snapshot(self):
        account = self.token(); self.probe_response()
        server.fetch_registered_account(account)
        self.clock.return_value += 600
        self.urlopen.side_effect = HTTPError(server.MESSAGES_URL, 401, "denied", {}, io.BytesIO())
        result = server.fetch_registered_account(account)
        self.assertEqual(result["state"], "token_rejected")
        self.assertIsNone(result["five_hour"])

    def test_stale_snapshot_has_five_minute_backoff_and_original_timestamp(self):
        account = self.token(); self.probe_response()
        good = server.fetch_registered_account(account)
        self.clock.return_value += 600
        self.urlopen.side_effect = URLError("offline")
        stale = server.fetch_registered_account(account)
        self.assertEqual(stale["state"], "stale")
        self.assertEqual(stale["five_hour"], good["five_hour"])
        self.assertEqual(stale["fetched_at"], good["fetched_at"])
        self.clock.return_value += 299
        server.fetch_registered_account(account, force=True)
        self.assertEqual(self.urlopen.call_count, 2)
        self.clock.return_value += 1
        self.probe_response()
        self.assertEqual(server.fetch_registered_account(account)["state"], "ok")
        self.assertEqual(self.urlopen.call_count, 3)

    def test_probe_cache_default_is_ten_minutes(self):
        account = self.token(); self.probe_response()
        first = server.fetch_registered_account(account)
        self.clock.return_value += 599
        self.assertEqual(server.fetch_registered_account(account), first)
        self.assertEqual(self.urlopen.call_count, 1)
        self.clock.return_value += 1
        server.fetch_registered_account(account)
        self.assertEqual(self.urlopen.call_count, 2)

    def test_probe_interval_minimum_and_invalid_configuration(self):
        with patch.dict(os.environ, {"CLAUDE_USAGE_PROBE_SECONDS": "1"}):
            self.assertEqual(server.probe_seconds(), 120)
            account = self.token(); self.probe_response()
            server.fetch_registered_account(account)
            self.clock.return_value += 119
            server.fetch_registered_account(account)
            self.assertEqual(self.urlopen.call_count, 1)
            self.clock.return_value += 1
            server.fetch_registered_account(account)
            self.assertEqual(self.urlopen.call_count, 2)
        with patch.dict(os.environ, {"CLAUDE_USAGE_PROBE_SECONDS": "bad"}):
            self.assertEqual(server.probe_seconds(), 600)

    def test_refresh_does_not_probe_twice_within_sixty_seconds(self):
        account = self.token(); self.probe_response()
        server.fetch_registered_account(account)
        self.clock.return_value += 59
        server.fetch_registered_account(account, force=True)
        self.assertEqual(self.urlopen.call_count, 1)
        self.clock.return_value += 2
        server.fetch_registered_account(account, force=True)
        self.assertEqual(self.urlopen.call_count, 2)

    def test_credential_replacement_never_reuses_old_snapshot(self):
        account = self.token(); self.probe_response()
        server.fetch_registered_account(account)
        account["_token"] = "sk-ant-oat01-fixture-replacement"
        self.urlopen.side_effect = URLError("offline")
        result = server.fetch_registered_account(account)
        self.assertEqual(result["state"], "error")
        self.assertIsNone(result["five_hour"])

    def test_one_lock_per_account_serializes_simultaneous_probes(self):
        account = self.token()
        entered = threading.Event(); release = threading.Event()
        def slow_probe(*args, **kwargs):
            entered.set()
            if not release.wait(3):
                raise AssertionError("probe was not released")
            return Response()
        self.urlopen.side_effect = slow_probe
        results = []
        threads = [threading.Thread(target=lambda: results.append(server.fetch_registered_account(account))) for _ in range(2)]
        threads[0].start()
        self.assertTrue(entered.wait(3))
        threads[1].start(); release.set()
        for thread in threads:
            thread.join(3)
            self.assertFalse(thread.is_alive())
        self.assertEqual(self.urlopen.call_count, 1)
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0], results[1])

    def test_merged_account_prefers_official_usage(self):
        self.token(); self.login()
        account = server.account_registry()[0]
        self.urlopen.side_effect = lambda *a, **k: Response({"five_hour": {"utilization": 15, "resets_at": None},
                                                            "seven_day": {"utilization": 82}})
        self.urlopen.reset_mock()
        result = server.fetch_registered_account(account)
        self.assertEqual(result["source"], "keychain")
        self.assertEqual(result["five_hour"]["utilization"], 15)
        self.assertEqual(self.urlopen.call_args.args[0].full_url, server.USAGE_URL)

    def test_merged_account_falls_back_to_probe_and_caches_it(self):
        self.token(); self.login()
        account = server.account_registry()[0]
        self.urlopen.side_effect = [HTTPError(server.USAGE_URL, 429, "limited", {}, io.BytesIO()), Response()]
        self.urlopen.reset_mock()
        result = server.fetch_registered_account(account)
        self.assertEqual(result["state"], "ok")
        self.assertEqual(self.urlopen.call_args.args[0].full_url, server.MESSAGES_URL)
        self.clock.return_value += 599
        server.fetch_registered_account(account)
        self.assertEqual(self.urlopen.call_count, 2)

    def test_official_401_refreshes_once_before_probe(self):
        self.token(); self.login()
        account = server.account_registry()[0]
        self.urlopen.side_effect = [HTTPError(server.USAGE_URL, 401, "expired", {}, io.BytesIO()),
                                   Response({"five_hour": {"utilization": 20}})]
        with patch.object(server, "refresh_token", return_value="fixture-rotated") as refresh:
            result = server.fetch_registered_account(account)
        refresh.assert_called_once()
        self.assertEqual(result["five_hour"]["utilization"], 20)

    def test_keychain_switch_in_flight_never_mislabels_usage(self):
        self.token(); self.login()
        account = server.account_registry()[0]
        before = server.local_account()
        after = dict(before, _fingerprint="replacement-login")
        self.urlopen.side_effect = [Response({"five_hour": {"utilization": 99}}), Response()]
        with patch.object(server, "local_account", side_effect=[before, after]):
            result = server.fetch_registered_account(account)
        # The 99 belongs to a changed Keychain login. Only the labelled bridge
        # account's own 15% probe may be shown for pho.
        self.assertEqual(result["five_hour"]["utilization"], 15)
        self.assertEqual(result["state"], "ok")

    def test_accounts_response_has_only_public_fields_and_never_tokens(self):
        self.token(); self.probe_response()
        code, body = self.request("GET", "/api/accounts")
        self.assertEqual(code, 200)
        data = json.loads(body)
        self.assertNotIn(b"sk-ant-", body)
        self.assertNotIn(b"fingerprint", body)
        self.assertNotIn(b"org-pho", body)
        self.assertEqual(set(data["accounts"][0]), PUBLIC_KEYS)
        self.assertEqual(set(data), {"accounts", "fetched_at"})

    def test_metadata_and_unknown_header_fields_cannot_leak_credentials(self):
        account = self.token(email="sk-ant-oat01-fixture-sensitive", plan="sk-ant-oat01-fixture-sensitive")
        headers = dict(HEADERS)
        headers["anthropic-ratelimit-unified-5h-status"] = "sk-ant-oat01-fixture-sensitive"
        self.probe_response(headers)
        result = server.fetch_registered_account(account)
        self.assertNotIn("sk-ant-", json.dumps(result))
        self.assertIsNone(result["five_hour"]["status"])

    def test_new_get_uses_existing_host_guard(self):
        self.token()
        code, _ = self.request("GET", "/api/accounts", {"Host": "attacker.example:8737"})
        self.assertEqual(code, 403)
        self.urlopen.assert_not_called()

    def test_refresh_post_guard_and_unknown_id(self):
        for headers in ({"Host": "127.0.0.1:8737"},
                        {"Host": "attacker.example", "X-Widget": "1"},
                        {"Host": "localhost:8737", "X-Widget": "1", "Origin": "http://localhost"}):
            with self.subTest(headers=headers):
                self.assertEqual(self.request("POST", "/api/refresh?account=pho", headers)[0], 403)
        headers = {"Host": "127.0.0.1:8737", "X-Widget": "1"}
        self.assertEqual(self.request("POST", "/api/refresh?account=unknown", headers)[0], 404)
        self.assertEqual(self.request("POST", "/api/refresh", headers)[0], 404)
        self.urlopen.assert_not_called()

    def test_refresh_post_returns_fresh_item(self):
        self.token(); self.probe_response()
        headers = {"Host": "localhost:8737", "X-Widget": "1"}
        code, body = self.request("POST", "/api/refresh?account=pho", headers)
        self.assertEqual(code, 200)
        self.assertEqual(set(json.loads(body)), PUBLIC_KEYS)
        self.clock.return_value += 61
        self.request("POST", "/api/refresh?account=pho", headers)
        self.assertEqual(self.urlopen.call_count, 2)

    def test_gemini_registry_order_quotes_homes_plan_ends_and_public_fields(self):
        self.token("pho")
        self.codex()
        self.gemini_env.write_text(
            '# logins\nexport GEMINI_BRIDGE_ACCOUNTS="pho:~/pho,apple:~,pho:/ignored,sk-ant-bad:/bad,:/empty,bad,empty:"\n'
            "export GEMINI_BRIDGE_PLAN_ENDS='pho:2026-12-19,apple:2026-12-05'\n"
            'GEMINI_BRIDGE_MANUAL_ACCOUNTS=apple\n')
        accounts = server.account_registry()
        self.assertEqual([a["id"] for a in accounts], ["pho", "codex-pro", "gemini-pho", "gemini-apple"])
        self.assertEqual(accounts[2], {"id": "gemini-pho", "label": "pho", "provider": "gemini",
                                      "source": "gemini", "machine_login": False, "expires_at": "2026-12-19",
                                      "email": None, "plan": None, "_home": str(self.home / "pho")})
        self.assertEqual(accounts[3]["_home"], str(self.home))
        self.assertEqual(accounts[3]["expires_at"], "2026-12-05")
        with patch.object(server, "fetch_registered_account", side_effect=lambda a: {"id": a["id"]}):
            code, body = self.request("GET", "/api/accounts")
        self.assertEqual(code, 200)
        self.assertEqual([a["id"] for a in json.loads(body)["accounts"]], [a["id"] for a in accounts])

    def test_gemini_registry_ignores_invalid_plan_dates_and_has_no_fallback(self):
        self.assertEqual(server.gemini_registry(), [])
        (self.home / ".gemini").mkdir()
        self.gemini_env.write_text("GEMINI_BRIDGE_MANUAL_ACCOUNTS=pho\nGEMINI_BRIDGE_PLAN_ENDS=pho:2026-12-19\n")
        self.assertEqual(server.gemini_registry(), [])
        for date in ("2026-02-30", "2026-13-01", "2026-2-01", "20261219", "2026-12-19T00:00:00Z", "bad"):
            with self.subTest(date=date):
                self.gemini_env.write_text("GEMINI_BRIDGE_ACCOUNTS=pho:~/pho\nGEMINI_BRIDGE_PLAN_ENDS=pho:" + date + "\n")
                self.assertIsNone(server.gemini_registry()[0]["expires_at"])
        self.gemini_env.write_text("GEMINI_BRIDGE_ACCOUNTS=\n")
        self.assertEqual(server.gemini_registry(), [])

    def test_gemini_default_registry_and_binary_use_real_home(self):
        default = self.home / ".config/gemini-bridge/env"
        default.parent.mkdir(parents=True)
        default.write_text("GEMINI_BRIDGE_ACCOUNTS=pho:~/pho\n")
        with patch.dict(os.environ):
            os.environ.pop("CLAUDE_USAGE_GEMINI_ENV", None)
            self.assertEqual(server.gemini_registry()[0]["_home"], str(self.home / "pho"))
        account = self.gemini()
        binary = self.fake_agy()
        default_binary = self.home / ".local/bin/agy"
        default_binary.parent.mkdir(parents=True)
        binary.rename(default_binary)
        with patch.dict(os.environ):
            os.environ.pop("CLAUDE_USAGE_AGY", None)
            self.assertEqual(server.fetch_registered_account(account)["state"], "ok")
        self.assertEqual(self.subprocess.call_args.args[0][0], str(default_binary))

    def test_gemini_fake_agy_maps_live_snapshot_and_never_reads_token(self):
        account = self.gemini()
        self.fake_agy(exit_code=17)  # agy's exit status is not its auth/quota status.
        with patch.object(Path, "read_text", side_effect=AssertionError("token contents forbidden")), \
                patch.object(Path, "read_bytes", side_effect=AssertionError("token contents forbidden")):
            result = server.fetch_registered_account(account)
        self.assertEqual(set(result), PUBLIC_KEYS)
        self.assertEqual(result["five_hour"], {"utilization": 1.0, "resets_at": "2026-11-24T15:15:06Z", "status": "allowed"})
        self.assertEqual(result["seven_day"], {"utilization": 1.0, "resets_at": "2026-12-01T10:15:06Z", "status": "allowed"})
        self.assertEqual(result["limits"], [
            {"kind": "session", "percent": 1.0, "resets_at": "2026-11-24T15:15:06Z", "status": "allowed"},
            {"kind": "weekly_all", "percent": 1.0, "resets_at": "2026-12-01T10:15:06Z", "status": "allowed"},
            {"percent": 0, "resets_at": "2026-12-01T10:15:18Z", "status": "allowed",
             "kind": "weekly_scoped", "group": "Claude and GPT models",
             "scope": {"model": {"display_name": "Claude and GPT models"}}},
        ])
        self.assertEqual((result["provider"], result["fetched_at"], result["as_of"], result["quota_source"], result["state"]),
                         ("gemini", 10000, 10000, "live", "ok"))
        self.assertEqual(server.account_state(account)["identity"], ("gemini", account["_home"]))
        self.assertEqual(self.subprocess.call_args.kwargs["timeout"], 45)
        self.assertEqual(self.subprocess.call_args.kwargs["stdin"], subprocess.DEVNULL)
        self.assertEqual(self.subprocess.call_args.kwargs["env"]["HOME"], account["_home"])
        self.assertEqual(self.subprocess.call_args.kwargs["cwd"], account["_home"])
        self.assertNotIn("fixture-private", json.dumps(result))
        self.assertNotIn("https://", json.dumps(result))
        self.clock.return_value += 599
        self.assertEqual(server.fetch_registered_account(account), result)
        self.assertEqual(self.subprocess.call_count, 1)
        self.clock.return_value += 1
        self.assertEqual(server.fetch_registered_account(account)["state"], "ok")
        self.assertEqual(self.subprocess.call_count, 2)

    def test_gemini_accounts_keep_independent_snapshots(self):
        pho = self.gemini()
        self.fake_agy()
        server.fetch_registered_account(pho)
        apple = self.gemini("apple")
        data = json.loads(json.dumps(GEMINI_USAGE))
        data["command"]["data"]["groups"][0]["buckets"][0]["remaining_fraction"] = 0.75
        self.fake_agy(data)
        server.fetch_registered_account(apple)
        self.gemini_env.write_text("GEMINI_BRIDGE_ACCOUNTS=pho:" + pho["_home"] + ",apple:" + apple["_home"] + "\n")
        code, body = self.request("GET", "/api/accounts")
        self.assertEqual(code, 200)
        accounts = json.loads(body)["accounts"]
        self.assertEqual([a["id"] for a in accounts], ["gemini-pho", "gemini-apple"])
        self.assertEqual([a["seven_day"]["utilization"] for a in accounts], [1, 25])
        for account in accounts:
            self.assertEqual([limit["kind"] for limit in account["limits"]], ["session", "weekly_all", "weekly_scoped"])
        self.assertEqual(self.subprocess.call_count, 2)

    def test_gemini_limits_order_is_independent_of_group_order_and_missing_windows(self):
        data = json.loads(json.dumps(GEMINI_USAGE))
        groups = data["command"]["data"]["groups"]
        groups.reverse()
        result = server.gemini_live_snapshot(data)
        self.assertEqual([limit["kind"] for limit in result["limits"]], ["session", "weekly_all", "weekly_scoped"])
        groups[1]["buckets"] = [groups[1]["buckets"][0]]  # Only the Gemini weekly window is reported.
        result = server.gemini_live_snapshot(data)
        self.assertIsNone(result["five_hour"])
        self.assertEqual([limit["kind"] for limit in result["limits"]], ["weekly_all", "weekly_scoped"])
        self.assertEqual(result["limits"][0]["percent"], result["seven_day"]["utilization"])

    def test_gemini_missing_or_empty_token_never_executes_agy(self):
        account = self.gemini(token=False)
        self.fake_agy()
        self.assertEqual(server.fetch_registered_account(account)["state"], "token_rejected")
        token = Path(account["_home"]) / ".gemini/antigravity-cli/antigravity-oauth-token"
        token.parent.mkdir(parents=True)
        token.touch()
        self.clock.return_value += 301
        self.assertEqual(server.fetch_registered_account(account)["state"], "token_rejected")
        self.assertFalse((self.home / "agy-executed").exists())
        self.subprocess.assert_not_called()
        self.popen.assert_not_called()

    def test_gemini_auth_failure_clears_snapshot_and_backs_off(self):
        account = self.gemini()
        self.fake_agy()
        self.assertEqual(server.fetch_registered_account(account)["state"], "ok")
        self.clock.return_value += 600
        self.fake_agy({"status": "ERROR", "error": "Authentication failed or timed out https://fixture.invalid/oauth"})
        code, body = self.request("GET", "/api/accounts")
        self.assertEqual(code, 200)
        result = json.loads(body)["accounts"][0]
        self.assertEqual(result["state"], "token_rejected")
        self.assertIsNone(result["five_hour"])
        self.assertIsNone(result["as_of"])
        self.assertNotIn(b"https://", body)
        self.assertNotIn(b"fixture-private", body)
        self.assertEqual(server.account_state(account)["next_at"], self.clock.return_value + 300)
        calls = self.subprocess.call_count
        self.clock.return_value += 299
        server.fetch_registered_account(account, force=True)
        self.assertEqual(self.subprocess.call_count, calls)
        self.clock.return_value += 1
        server.fetch_registered_account(account)
        self.assertEqual(self.subprocess.call_count, calls + 1)

    def test_gemini_past_resets_expire_live_and_cached_windows_and_scoped_limits(self):
        account = self.gemini()
        data = json.loads(json.dumps(GEMINI_USAGE))
        for group in data["command"]["data"]["groups"]:
            for bucket in group["buckets"]:
                bucket.update(remaining_fraction=0, reset_time="1970-01-01T02:46:41Z")
        self.fake_agy(data)
        result = server.fetch_registered_account(account)
        self.assertEqual(result["five_hour"]["status"], "rejected")
        self.assertEqual([limit["kind"] for limit in result["limits"]], ["session", "weekly_all", "weekly_scoped"])
        for limit in result["limits"]:
            self.assertEqual((limit["percent"], limit["status"]), (100, "rejected"))
        self.clock.return_value += 2
        expired = server.fetch_registered_account(account)
        for window in [expired["five_hour"], expired["seven_day"]] + expired["limits"]:
            self.assertEqual((window.get("utilization", window.get("percent")), window["resets_at"], window["status"]),
                             (0, None, "allowed"))
        self.assertEqual(self.subprocess.call_count, 1)
        self.clock.return_value += 600
        refreshed = server.fetch_registered_account(account)
        self.assertEqual(refreshed["five_hour"]["utilization"], 0)
        for limit in refreshed["limits"]:
            self.assertEqual((limit["percent"], limit["resets_at"], limit["status"]), (0, None, "allowed"))

    def test_gemini_interval_minimum_default_and_invalid_configuration(self):
        account = self.gemini()
        self.fake_agy()
        with patch.dict(os.environ, {"CLAUDE_USAGE_GEMINI_SECONDS": "1"}):
            self.assertEqual(server.gemini_seconds(), 120)
            server.fetch_registered_account(account)
            self.clock.return_value += 119
            server.fetch_registered_account(account)
            self.assertEqual(self.subprocess.call_count, 1)
            self.clock.return_value += 1
            server.fetch_registered_account(account)
            self.assertEqual(self.subprocess.call_count, 2)
        with patch.dict(os.environ, {"CLAUDE_USAGE_GEMINI_SECONDS": "bad"}):
            self.assertEqual(server.gemini_seconds(), 600)
        with patch.dict(os.environ):
            os.environ.pop("CLAUDE_USAGE_GEMINI_SECONDS", None)
            self.assertEqual(server.gemini_seconds(), 600)

    def test_gemini_failures_are_generic_and_preserve_only_old_snapshot(self):
        account = self.gemini()
        for failure in (FileNotFoundError("private-binary"), subprocess.TimeoutExpired("private-output", 45),
                        subprocess.CompletedProcess([], 0, "not-json https://fixture.invalid", "private-stderr"),
                        subprocess.CompletedProcess([], 0, '{"status":"ERROR","error":"private-failure"}', ""),
                        subprocess.CompletedProcess([], 0, '{"status":"SUCCESS"}', "")):
            for cached in (False, True):
                with self.subTest(failure=type(failure).__name__, cached=cached):
                    server._account_states.clear()
                    if cached:
                        self.fake_agy()
                        good = server.fetch_registered_account(account)
                        self.clock.return_value += 600
                    if isinstance(failure, Exception):
                        self.subprocess.side_effect = failure
                    else:
                        self.subprocess.side_effect = None
                        self.subprocess.return_value = failure
                    result = server.fetch_registered_account(account)
                    self.assertEqual(result["state"], "stale" if cached else "error")
                    self.assertNotIn("private", json.dumps(result))
                    self.assertNotIn("https://", json.dumps(result))
                    self.assertEqual(server.account_state(account)["next_at"], self.clock.return_value + 300)
                    if cached:
                        self.assertEqual(result["five_hour"], good["five_hour"])
                    calls = self.subprocess.call_count
                    self.clock.return_value += 299
                    server.fetch_registered_account(account, force=True)
                    self.assertEqual(self.subprocess.call_count, calls)

    def test_gemini_group_selection_validation_clamping_and_home_identity(self):
        data = json.loads(json.dumps(GEMINI_USAGE))
        group = data["command"]["data"]["groups"][0]
        group["name"] = "Renamed group"
        group["buckets"][0]["remaining_fraction"] = -0.1
        group["buckets"][1]["remaining_fraction"] = 1.1
        result = server.gemini_live_snapshot(data)
        self.assertEqual(result["seven_day"]["utilization"], 100)
        self.assertEqual(result["seven_day"]["status"], "rejected")
        self.assertEqual(result["five_hour"]["utilization"], 0)
        group.pop("name")
        self.assertIsNotNone(server.gemini_live_snapshot(data)["five_hour"])
        group["name"] = "Gemini Models"
        for bucket in group["buckets"]:
            bucket["id"] = "future-bucket"
        self.assertIsNotNone(server.gemini_live_snapshot(data)["five_hour"])
        for value in (True, None, "nan", "inf", "bad"):
            group["buckets"][1]["remaining_fraction"] = value
            self.assertIsNone(server.gemini_live_snapshot(data)["five_hour"])
        account = self.gemini()
        self.fake_agy()
        server.fetch_registered_account(account)
        other = self.home / "other-gemini-home"
        other.mkdir()
        account["_home"] = str(other)
        result = server.fetch_registered_account(account)
        self.assertEqual(result["state"], "token_rejected")
        self.assertIsNone(result["five_hour"])
        self.assertEqual(server.account_state(account)["identity"], ("gemini", str(other)))

    def test_codex_registry_order_quotes_homes_and_public_fields(self):
        self.token("pho")
        self.codex_env.write_text(
            '# logins\nexport CODEX_BRIDGE_ACCOUNTS="pro:~/.codex,edu:~/edu,pro:/ignored,sk-ant-bad:/bad"\n'
            'CODEX_BRIDGE_MANUAL_ACCOUNTS=edu\n')
        accounts = server.account_registry()
        self.assertEqual([a["id"] for a in accounts], ["pho", "codex-pro", "codex-edu"])
        self.assertEqual(accounts[0]["provider"], "claude")
        self.assertEqual(accounts[1], {"id": "codex-pro", "label": "pro", "provider": "codex",
                                      "source": "codex", "machine_login": False, "expires_at": None,
                                      "email": None, "plan": None, "_home": str(self.home / ".codex")})
        self.assertEqual(accounts[2]["_home"], str(self.home / "edu"))
        self.codex_env.write_text("CODEX_BRIDGE_ACCOUNTS='edu:~,pro:/fixture/pro'\n")
        self.assertEqual([a["_home"] for a in server.codex_registry()], [str(self.home), "/fixture/pro"])

    def test_codex_registry_fallback_only_for_existing_default_home(self):
        self.assertEqual(server.codex_registry(), [])
        (self.home / ".codex").mkdir()
        self.assertEqual(server.codex_registry()[0]["id"], "codex-codex")
        self.codex_env.write_text("CODEX_BRIDGE_MANUAL_ACCOUNTS=edu\n")
        self.assertEqual(server.codex_registry()[0]["_home"], str(self.home / ".codex"))
        self.codex_env.write_text("CODEX_BRIDGE_ACCOUNTS=\n")
        self.assertEqual(server.codex_registry(), [])

    def test_codex_env_default_uses_patched_home_and_override_is_literal(self):
        default = self.home / ".config/codex-bridge/env"
        default.parent.mkdir(parents=True)
        default.write_text("CODEX_BRIDGE_ACCOUNTS=edu:~/edu\n")
        with patch.dict(os.environ):
            os.environ.pop("CLAUDE_USAGE_CODEX_ENV", None)
            self.assertEqual(server.codex_registry()[0]["id"], "codex-edu")
        with patch.dict(os.environ, {"CLAUDE_USAGE_CODEX_ENV": "~/codex-env"}):
            with patch.object(Path, "read_text", side_effect=FileNotFoundError) as read:
                self.assertEqual(server.codex_registry(), [])
                self.assertEqual(read.call_count, 1)

    def test_codex_weekly_only_live_maps_public_schema(self):
        account = self.codex()
        with patch.object(server, "codex_app_server_read", return_value=self.codex_live()) as read:
            result = server.fetch_registered_account(account)
        read.assert_called_once_with(account["_home"])
        self.assertEqual(set(result), PUBLIC_KEYS)
        self.assertIsNone(result["five_hour"])
        self.assertIsNone(result["limits"])
        self.assertEqual(result["seven_day"], {"utilization": 12.0, "resets_at": "2026-10-24T23:10:21Z",
                                                "status": "allowed"})
        self.assertEqual((result["email"], result["plan"], result["provider"], result["as_of"],
                          result["quota_source"], result["state"]),
                         ("pro@example.com", "pro lite", "codex", 10000, "live", "ok"))

    def test_codex_edu_maps_windows_by_duration_and_identity_is_cached(self):
        account = self.codex("edu")
        with patch.object(server, "codex_app_server_read", return_value=self.codex_live("edu@example.com", "edu", True)) as read:
            result = server.fetch_registered_account(account)
            self.clock.return_value += 299
            cached = server.fetch_registered_account(server.account_registry()[0])
        self.assertEqual(read.call_count, 1)
        self.assertEqual(cached, result)
        self.assertEqual(result["five_hour"]["utilization"], 1)
        self.assertEqual(result["seven_day"]["utilization"], 0)
        self.assertEqual(result["plan"], "edu")
        self.assertEqual(server.account_state(account)["identity"], ("codex", account["_home"]))

    def test_codex_plan_map(self):
        for raw, expected in (("prolite", "pro lite"), ("promax", "pro max"), ("edu_plus", "edu plus"),
                              ("edu_pro", "edu pro"), ("edu", "edu"), ("future_plan", "future plan"),
                              ("unknown", None), (None, None), ("sk-ant-fixture", None)):
            with self.subTest(plan=raw):
                self.assertEqual(server.codex_plan(raw), expected)

    def test_claude_public_freshness_and_quota_sources(self):
        account = self.token()
        self.probe_response()
        result = server.fetch_registered_account(account)
        self.assertEqual((result["provider"], result["quota_source"], result["as_of"]),
                         ("claude", "probe", result["fetched_at"]))
        account.update(source="keychain", _credential="fixture-login")
        with patch.object(server, "official_usage", return_value={"five_hour": {"utilization": 20}, "seven_day": None}):
            result = server.fetch_registered_account(account)
        self.assertEqual((result["provider"], result["quota_source"], result["as_of"]),
                         ("claude", "official", result["fetched_at"]))

    def test_codex_limit_selection_validation_and_missing_windows(self):
        _, result = self.codex_live()
        result["rateLimits"] = {"limitId": "premium", "primary": {"usedPercent": 88, "windowDurationMins": 300}}
        self.assertEqual(server.codex_live_snapshot(result)["seven_day"]["utilization"], 12)
        result.pop("rateLimitsByLimitId")
        self.assertIsNone(server.codex_live_snapshot(result)["five_hour"])
        result["rateLimits"]["limitId"] = None
        self.assertEqual(server.codex_live_snapshot(result)["five_hour"]["utilization"], 88)
        for value in (True, -1, 101, "nan", "inf", "bad"):
            with self.subTest(value=value):
                self.assertIsNone(server.codex_windows({"primary": {"usedPercent": value, "windowDurationMins": 300}})["five_hour"])
        data = server.codex_windows({"primary": {"usedPercent": 100, "windowDurationMins": 10080, "resetsAt": "bad"},
                                     "secondary": {"usedPercent": 10, "windowDurationMins": 60}})
        self.assertIsNone(data["five_hour"])
        self.assertEqual(data["seven_day"], {"utilization": 100, "resets_at": None, "status": "rejected"})

    def test_codex_ttl_and_guarded_refresh_route(self):
        account = self.codex()
        headers = {"Host": "localhost:8737", "X-Widget": "1"}
        with patch.object(server, "codex_app_server_read", return_value=self.codex_live()) as read:
            server.fetch_registered_account(account)
            self.clock.return_value += 59
            server.fetch_registered_account(account)
            self.request("POST", "/api/refresh?account=codex-pro", headers)
            self.assertEqual(read.call_count, 1)
            self.clock.return_value += 1
            code, body = self.request("POST", "/api/refresh?account=codex-pro", headers)
            self.assertEqual(code, 200)
            self.assertEqual(json.loads(body)["quota_source"], "live")
            self.assertEqual(read.call_count, 2)
            self.clock.return_value += 299
            server.fetch_registered_account(account)
            self.assertEqual(read.call_count, 2)
            self.clock.return_value += 1
            server.fetch_registered_account(account)
            self.assertEqual(read.call_count, 3)

    def test_codex_interval_minimum_and_invalid_configuration(self):
        account = self.codex()
        with patch.dict(os.environ, {"CLAUDE_USAGE_CODEX_SECONDS": "1"}):
            self.assertEqual(server.codex_seconds(), 60)
            with patch.object(server, "codex_app_server_read", return_value=self.codex_live()) as read:
                server.fetch_registered_account(account)
                self.clock.return_value += 59
                server.fetch_registered_account(account)
                self.assertEqual(read.call_count, 1)
                self.clock.return_value += 1
                server.fetch_registered_account(account)
                self.assertEqual(read.call_count, 2)
        with patch.dict(os.environ, {"CLAUDE_USAGE_CODEX_SECONDS": "bad"}):
            self.assertEqual(server.codex_seconds(), 300)

    def test_codex_signed_out_clears_live_and_never_serves_rollout(self):
        account = self.codex()
        with patch.object(server, "codex_app_server_read", return_value=self.codex_live()) as read:
            server.fetch_registered_account(account)
            self.rollout(account, as_of=10301)
            self.clock.return_value += 300
            read.side_effect = server.SignedOut()
            result = server.fetch_registered_account(account)
            self.assertEqual(result["state"], "token_rejected")
            self.assertIsNone(result["five_hour"])
            self.assertIsNone(result["seven_day"])
            self.assertIsNone(result["as_of"])
            self.clock.return_value += 299
            self.assertEqual(server.fetch_registered_account(account, force=True)["state"], "token_rejected")
            self.assertEqual(read.call_count, 2)

    def test_codex_live_failure_uses_rollout_timestamp_and_expires_windows(self):
        account = self.codex()
        self.rollout(account, as_of=9900.25, reset=9999)
        with patch.object(server, "codex_app_server_read", side_effect=OSError("offline")) as read:
            result = server.fetch_registered_account(account)
            self.assertEqual(result["state"], "stale")
            self.assertEqual(result["quota_source"], "rollout")
            self.assertEqual(result["as_of"], 9900.25)
            self.assertEqual(result["five_hour"], {"utilization": 0, "resets_at": None, "status": "allowed"})
            self.assertEqual(result["seven_day"]["utilization"], 8)
            self.clock.return_value += 299
            server.fetch_registered_account(account, force=True)
            self.assertEqual(read.call_count, 1)
            self.clock.return_value += 1
            server.fetch_registered_account(account)
            self.assertEqual(read.call_count, 2)

    def test_codex_newer_rollout_overlays_live_on_every_fetch(self):
        account = self.codex()
        with patch.object(server, "codex_app_server_read", return_value=self.codex_live()) as read:
            self.assertEqual(server.fetch_registered_account(account)["quota_source"], "live")
            self.clock.return_value += 20
            self.rollout(account, as_of=10010)
            result = server.fetch_registered_account(account)
            self.assertEqual(result["state"], "ok")
            self.assertEqual(result["quota_source"], "rollout")
            self.assertEqual(result["as_of"], 10010)
            self.assertEqual(result["five_hour"]["utilization"], 34)
            self.assertEqual(result["email"], "pro@example.com")
            self.assertEqual(read.call_count, 1)

    def test_codex_older_rollout_does_not_replace_live_but_covers_failure(self):
        account = self.codex()
        self.rollout(account)
        with patch.object(server, "codex_app_server_read", return_value=self.codex_live()) as read:
            self.assertEqual(server.fetch_registered_account(account)["quota_source"], "live")
            self.clock.return_value += 300
            read.side_effect = OSError("offline")
            result = server.fetch_registered_account(account)
            self.assertEqual((result["quota_source"], result["state"]), ("rollout", "stale"))

    def test_codex_no_rollout_retains_old_snapshot_or_reports_error(self):
        account = self.codex()
        with patch.object(server, "codex_app_server_read", side_effect=OSError("offline")) as read:
            self.assertEqual(server.fetch_registered_account(account)["state"], "error")
            self.clock.return_value += 299
            server.fetch_registered_account(account, force=True)
            self.assertEqual(read.call_count, 1)
            self.clock.return_value += 1
            read.side_effect = None
            read.return_value = self.codex_live()
            good = server.fetch_registered_account(account)
            self.clock.return_value += 300
            read.side_effect = OSError("offline")
            stale = server.fetch_registered_account(account)
            self.assertEqual(stale["state"], "stale")
            self.assertEqual(stale["as_of"], good["as_of"])
            self.assertEqual(stale["seven_day"], good["seven_day"])

    def test_codex_rollout_cache_uses_path_mtime_size_and_whole_tree(self):
        account = self.codex()
        first = self.rollout(account)
        second = self.rollout(account, as_of=9950, used=56, name="rollout-other.jsonl")
        os.utime(first, (200, 200)); os.utime(second, (100, 100))
        original_open = Path.open
        reads = []
        def tracked(path, *args, **kwargs):
            if path.name.startswith("rollout-"):
                reads.append(path)
            return original_open(path, *args, **kwargs)
        with patch.object(Path, "open", tracked), patch.object(server, "codex_app_server_read", side_effect=OSError):
            self.assertEqual(server.fetch_registered_account(account)["five_hour"]["utilization"], 34)
            server.fetch_registered_account(account)
            self.assertEqual(reads, [first])
            os.utime(second, (300, 300))
            self.assertEqual(server.fetch_registered_account(account)["five_hour"]["utilization"], 56)
            self.assertEqual(reads, [first, second])
            with original_open(second, "a") as file:
                file.write("broken\n")
            server.fetch_registered_account(account)
            self.assertEqual(reads, [first, second, second])

    def test_codex_rollout_tail_ignores_partial_invalid_and_other_limits(self):
        account = self.codex()
        path = self.rollout(account)
        event = path.read_text()
        other = json.loads(event)
        other["payload"]["rate_limits"]["limit_id"] = "premium"
        path.write_text("x" * (256 * 1024) + "\n" + event + "{broken\n" + json.dumps(other) + "\n")
        with patch.object(server, "codex_app_server_read", side_effect=OSError):
            self.assertEqual(server.fetch_registered_account(account)["five_hour"]["utilization"], 34)

    def test_codex_rollout_expiry_is_recomputed_without_rereading_file(self):
        account = self.codex()
        self.rollout(account, reset=10010)
        with patch.object(server, "codex_app_server_read", side_effect=OSError):
            self.assertEqual(server.fetch_registered_account(account)["five_hour"]["utilization"], 34)
            self.clock.return_value += 11
            result = server.fetch_registered_account(account)
            self.assertEqual(result["five_hour"]["utilization"], 0)
            self.assertIsNone(result["five_hour"]["resets_at"])

    def test_codex_email_change_drops_snapshot_before_mapping_new_usage(self):
        account = self.codex()
        with patch.object(server, "codex_app_server_read", return_value=self.codex_live()) as read:
            server.fetch_registered_account(account)
            self.clock.return_value += 300
            read.return_value = self.codex_live("changed@example.com", "edu")
            with patch.object(server, "codex_live_snapshot", side_effect=ValueError("bad usage")):
                result = server.fetch_registered_account(account)
            self.assertEqual(result["state"], "error")
            self.assertIsNone(result["seven_day"])
            self.assertEqual(result["email"], "changed@example.com")
            self.assertIsNone(server.account_state(account)["snapshot"])

    def test_codex_home_change_drops_identity_snapshot(self):
        account = self.codex()
        with patch.object(server, "codex_app_server_read", return_value=self.codex_live()) as read:
            server.fetch_registered_account(account)
            account["_home"] = str(self.home / "replacement-home")
            read.side_effect = OSError("offline")
            result = server.fetch_registered_account(account)
            self.assertEqual(result["state"], "error")
            self.assertIsNone(result["email"])
            self.assertIsNone(result["seven_day"])

    def test_codex_auth_file_is_never_opened_and_private_fields_never_escape(self):
        account = self.codex()
        (Path(account["_home"]) / "auth.json").write_text("fixture-secret-token")
        original_open, original_path_open = builtins.open, Path.open
        original_text, original_bytes = Path.read_text, Path.read_bytes
        blocked = []
        def guard(path):
            if not isinstance(path, int) and Path(path).name == "auth.json":
                blocked.append(str(path))
                raise AssertionError("credential file opened")
        def guarded_open(path, *args, **kwargs):
            guard(path)
            return original_open(path, *args, **kwargs)
        def guarded_path_open(path, *args, **kwargs):
            guard(path)
            return original_path_open(path, *args, **kwargs)
        def guarded_text(path, *args, **kwargs):
            guard(path)
            return original_text(path, *args, **kwargs)
        def guarded_bytes(path, *args, **kwargs):
            guard(path)
            return original_bytes(path, *args, **kwargs)
        with patch("builtins.open", guarded_open), patch.object(Path, "open", guarded_path_open), \
                patch.object(Path, "read_text", guarded_text), patch.object(Path, "read_bytes", guarded_bytes), \
                patch.object(server, "codex_app_server_read", return_value=self.codex_live()):
            self.assertEqual(server.account_registry()[0]["id"], "codex-pro")
            code, body = self.request("GET", "/api/accounts")
        self.assertEqual(code, 200)
        self.assertEqual(blocked, [])
        self.assertEqual(set(json.loads(body)["accounts"][0]), PUBLIC_KEYS)
        for secret in (b"fixture-secret-token", b"fixture-account-id", b"fixture-reset-id", b"fixture-credits",
                       b"fixture-routing", b"fixture-upsell", b"_home", b"auth.json"):
            self.assertNotIn(secret, body)

    def test_codex_real_subprocess_fake_protocol_and_environment(self):
        body = '''import json, os, sys
assert sys.argv[1:] == ["app-server"]
assert "OPENAI_API_KEY" not in os.environ and "CODEX_API_KEY" not in os.environ
def receive():
    return json.loads(sys.stdin.readline())
def send(value):
    print(json.dumps(value), flush=True)
initialize = receive()
assert initialize == {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "clientInfo": {"name": "claude-usage-widget", "version": "3.3.0"}}}
send({"method": "configWarning", "params": {}})
send({"id": 1, "result": {}})
assert receive() == {"jsonrpc": "2.0", "method": "initialized"}
assert receive() == {"jsonrpc": "2.0", "id": 2, "method": "account/read", "params": {}}
assert receive() == {"jsonrpc": "2.0", "id": 3, "method": "account/rateLimits/read"}
# Multiple lines in one write catch buffered-read/select deadlocks.
sys.stdout.write(json.dumps({"id": 3, "result": {"home": os.environ["CODEX_HOME"], "path": os.environ["PATH"]}}) + "\\n" +
                 json.dumps({"method": "account/updated", "params": {}}) + "\\n" +
                 json.dumps({"id": 2, "result": {"account": {"email": "fake@example.com"}}}) + "\\n")
sys.stdout.flush()
sys.stdin.read()
'''
        home = self.home / "fixture-home"
        with self.fake_codex(body), patch.dict(os.environ, {"OPENAI_API_KEY": "fixture-key", "CODEX_API_KEY": "fixture-key"}), \
                patch.object(server.subprocess, "Popen", side_effect=self.real_popen) as launch:
            account, limits = server.codex_app_server_read(home, timeout=10)
            self.assertEqual(os.environ["OPENAI_API_KEY"], "fixture-key")
            self.assertEqual(os.environ["CODEX_API_KEY"], "fixture-key")
        self.assertEqual(account["account"]["email"], "fake@example.com")
        self.assertEqual(limits["home"], str(home))
        self.assertTrue(limits["path"].startswith(os.pathsep.join([
            str(self.home), str(self.home / ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin"])))
        self.assertTrue(launch.call_args.kwargs["start_new_session"])
        self.assertEqual(launch.call_args.kwargs["stderr"], subprocess.DEVNULL)

    def test_codex_real_subprocess_timeout_reaps_child_with_frozen_wall_clock(self):
        children = []
        def launch(*args, **kwargs):
            process = self.real_popen(*args, **kwargs)
            children.append(process)
            return process
        with self.fake_codex('import time\ntime.sleep(30)\n'), patch.object(server.subprocess, "Popen", side_effect=launch):
            start = time.monotonic()
            with self.assertRaises(TimeoutError):
                server.codex_app_server_read(self.home, timeout=10)
            elapsed = time.monotonic() - start
            self.assertGreaterEqual(elapsed, 9)
            self.assertLess(elapsed, 15)
        self.assertEqual(len(children), 1)
        self.assertIsNotNone(children[0].poll())
        self.assertTrue(children[0].stdin.closed)
        self.assertTrue(children[0].stdout.closed)
        with self.assertRaises(ProcessLookupError):
            os.kill(children[0].pid, 0)

    def test_codex_real_subprocess_signed_out_rpc_error_and_malformed_json(self):
        responses = (({"id": 2, "result": {"account": None}}, server.SignedOut),
                     ({"id": 2, "error": {"code": -1}}, server.SignedOut),
                     ({"id": 3, "error": {"code": -1}}, RuntimeError),
                     ("malformed", ValueError))
        for response, exception in responses:
            with self.subTest(response=response):
                body = ('import sys\nsys.stdin.readline()\nprint(\'{"id":1,"result":{}}\', flush=True)\n'
                        'for _ in range(3): sys.stdin.readline()\n'
                        'print(' + repr(response if isinstance(response, str) else json.dumps(response)) + ', flush=True)\n')
                with self.fake_codex(body), patch.object(server.subprocess, "Popen", side_effect=self.real_popen):
                    with self.assertRaises(exception):
                        server.codex_app_server_read(self.home, timeout=10)

    def test_codex_binary_search_precedence_and_missing_binary(self):
        local = self.home / ".local/bin/codex"
        local.parent.mkdir(parents=True)
        local.write_text("#!/bin/sh\nexit 1\n")
        local.chmod(0o700)
        with patch.dict(os.environ):
            os.environ.pop("CLAUDE_USAGE_CODEX_BIN", None)
            with self.assertRaisesRegex(AssertionError, "real codex forbidden"):
                server.codex_app_server_read(self.home)
            self.assertEqual(self.popen.call_args.args[0], [str(local), "app-server"])
            with patch.object(os, "access", return_value=False), patch.object(server.shutil, "which", return_value=None) as which:
                with self.assertRaises(FileNotFoundError):
                    server.codex_app_server_read(self.home)
                self.assertIn("/opt/homebrew/bin", which.call_args.kwargs["path"])

    def test_legacy_usage_fetch_shape_cache_and_signed_out_unchanged(self):
        self.assertEqual(server.fetch_usage()["logged_in"], False)
        self.login()
        raw = {"five_hour": {"utilization": 15, "resets_at": None}, "seven_day": None, "limits": None}
        self.urlopen.side_effect = lambda *a, **k: Response(raw)
        result = server.fetch_usage()
        self.assertEqual(result["five_hour"], raw["five_hour"])
        self.assertEqual(set(result), {"five_hour", "seven_day", "limits", "fetched_at", "logged_in", "account_key"})
        calls = self.urlopen.call_count
        self.assertEqual(server.fetch_usage(), result)
        self.assertEqual(self.urlopen.call_count, calls)

    def test_legacy_get_routes_and_html_unchanged(self):
        usage = {"five_hour": None, "seven_day": None, "limits": None, "logged_in": False}
        with patch.object(server, "fetch_usage", return_value=usage), patch.object(server, "fetch_account", return_value={"logged_in": False}):
            self.assertEqual(json.loads(self.request("GET", "/api/usage")[1]), usage)
            self.assertEqual(json.loads(self.request("GET", "/api/account")[1]), {"logged_in": False})
        self.assertEqual(self.request("GET", "/api/ping"), (200, b'{"ok":true,"version":"3.3.0"}'))
        for path in ("/", "/index.html"):
            code, body = self.request("GET", path)
            self.assertEqual(code, 200)
            self.assertEqual(body, (server.DIR / "widget.html").read_bytes())
        self.assertEqual(self.request("GET", "/missing")[0], 404)

    def test_legacy_auth_guards_dry_runs_and_no_subprocess(self):
        with patch.object(server, "claude_command", return_value="/fixture/claude"):
            for path in ("/api/login", "/api/logout"):
                self.assertEqual(self.request("POST", path)[0], 403)
                for query in ("?dry=1", "?dry=1&dry=1", "?dry=&x=y"):
                    code, body = self.request("POST", path + query, {"Host": "localhost:8737", "X-Widget": "1"})
                    self.assertEqual(code, 200)
                    self.assertTrue(json.loads(body)["dry"])
            self.subprocess.assert_not_called()

    def test_legacy_login_logout_call_only_mocked_subprocess(self):
        self.subprocess.side_effect = None
        self.subprocess.return_value = subprocess.CompletedProcess([], 0)
        headers = {"Host": "127.0.0.1:8737", "X-Widget": "1"}
        with patch.object(server, "claude_command", return_value="/fixture/claude"):
            for path in ("/api/login", "/api/logout"):
                code, body = self.request("POST", path, headers)
                self.assertEqual(code, 200)
                self.assertTrue(json.loads(body)["ok"])
        self.assertEqual(self.subprocess.call_count, 2)

    def test_quit_rejects_missing_widget_origin_and_bad_host(self):
        headers = (
            {"Host": "localhost:8737"},
            {"Host": "localhost:8737", "X-Widget": "1", "Origin": "http://localhost"},
            {"Host": "example.com:8737", "X-Widget": "1"},
        )
        with patch.object(server.threading, "Thread") as thread:
            for header in headers:
                with self.subTest(header=header):
                    code, body = self.request("POST", "/api/quit", header)
                    self.assertEqual(code, 403)
                    self.assertEqual(json.loads(body), {"ok": False, "error": "forbidden"})
            thread.assert_not_called()

    def test_quit_replies_ok_and_shuts_down_on_background_thread(self):
        from unittest.mock import Mock
        httpd = Mock()
        called = threading.Event()
        shutdown_threads = []
        def shutdown():
            shutdown_threads.append(threading.current_thread())
            called.set()
        httpd.shutdown.side_effect = shutdown
        with patch.object(server.Handler, "server", httpd, create=True):
            code, body = self.request("POST", "/api/quit", {"Host": "127.0.0.1:8737", "X-Widget": "1"})
            self.assertEqual((code, body), (200, b'{"ok":true}'))
            self.assertTrue(called.wait(timeout=2))
        httpd.shutdown.assert_called_once_with()
        self.assertIsNot(shutdown_threads[0], threading.current_thread())


class CreditsTests(unittest.TestCase):
    request = ServerTests.request

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.config = self.home / "credits.json"
        self.dirs = [self.home / "fleet-ledger", self.home / "local-ledger"]
        for directory in self.dirs:
            directory.mkdir()
        self.key = self.home / "admin.key"
        self.anchor = "2026-11-20T00:00:00Z"
        self.now = datetime(2026, 11, 24, 12, tzinfo=timezone.utc).timestamp()
        self.data = {"providers": {
            "anthropic": {"label": "Claude API", "console": "https://example.com/claude",
                          "anchor": {"at": self.anchor, "promo_remaining": 199.95, "purchased_remaining": 9.07},
                          "grants": [{"name": "promo", "amount": 200, "expires": "2026-12-09T00:00:00Z"}]},
            "openai": {"label": "OpenAI API", "console": "https://example.com/openai", "note": "Fixture note.",
                       "anchor": {"at": self.anchor, "remaining": 90.08},
                       "grants": [{"amount": 51, "expires": "2026-12-06T00:00:00Z"},
                                  {"amount": 50, "remaining": 28.67, "expires": "2026-11-28T00:00:00Z"},
                                  {"amount": 10, "remaining": 10, "expires": "2027-06-01T00:00:00Z"},
                                  {"amount": 5, "remaining": 0.41, "expires": "2027-06-01T00:00:00Z"}]}}}
        self.save_config()
        self.enter(patch.object(Path, "home", return_value=self.home))
        self.enter(patch.dict(os.environ, {"CREDITS_CONFIG": str(self.config),
                                          "API_CREDITS_LEDGER_DIRS": os.pathsep.join(map(str, self.dirs)),
                                          "OPENAI_ADMIN_KEY_FILE": str(self.key)}))
        self.clock = self.enter(patch.object(server.time, "time", return_value=self.now))
        self.urlopen = self.enter(patch.object(server._credits_opener, "open",
                                               side_effect=AssertionError("network forbidden")))
        server._costs_cache.update(at=0, key=None, spent=None, ttl=0)
        duplicate = self.entry("anthropic", 2.5)
        (self.dirs[0] / "one.jsonl").write_text("\n".join([
            duplicate, "not json", "[]", self.entry("anthropic", 900, "2026-11-19T00:00:00Z"),
            self.entry("anthropic", 100, self.anchor), self.entry("openai", 1.25),
            self.entry("openai", None), self.entry("other", 100)]) + "\n")
        (self.dirs[1] / "two.jsonl").write_text(duplicate + "\n" + self.entry("anthropic", 0.05) + "\n")

    def enter(self, mock):
        value = mock.start()
        self.addCleanup(mock.stop)
        return value

    def save_config(self):
        self.config.write_text(json.dumps(self.data))

    def entry(self, provider, usd, ts="2026-11-21T01:00:00+00:00"):
        return json.dumps({"ts": ts, "host": "fixture", "provider": provider, "tool": "claude_api" if provider == "anthropic" else "fixture",
                           "model": "fixture", "input_tokens": 5, "output_tokens": 2,
                           "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
                           "usd": usd, "ok": True})

    def providers(self):
        return {row["id"]: row for row in server.fetch_credits()["providers"]}

    def cost_page(self, *values, has_more=False, next_page=None, end_time=None, currency="usd"):
        return {"data": [{"end_time": end_time if end_time is not None else self.now,
                          "results": [{"amount": {"value": value, "currency": currency}} for value in values]}],
                "has_more": has_more, "next_page": next_page}

    def clean_ledgers(self):
        for directory in self.dirs:
            for path in directory.glob("*.jsonl"):
                path.unlink()

    def write_ledger(self, entries):
        (self.dirs[0] / "fixture.jsonl").write_text("\n".join(entries) + "\n")

    def test_credits_route_ledgers_deduplicate_skip_bad_and_pre_anchor(self):
        code, body = self.request("GET", "/api/credits")
        self.assertEqual(code, 200)
        result = json.loads(body)
        self.assertEqual(result["updated_at"], self.now)
        claude, openai = result["providers"]
        self.assertAlmostEqual(claude["spent_since_anchor"], 2.55)
        self.assertAlmostEqual(claude["remaining"], 197.4)
        self.assertEqual(claude["granted"], 200)
        self.assertEqual(claude["extra"], 9.07)
        self.assertEqual(claude["spend_source"], "ledger_partial")
        self.assertEqual(claude["type"], "anthropic")
        self.assertEqual(openai["type"], "openai")
        self.assertEqual(claude["anchor_at"], self.anchor)
        self.assertEqual(claude["stale_days"], 4)
        self.assertEqual(claude["console"], "https://example.com/claude")
        self.assertEqual(openai["next_expiry"], {"date": "2026-11-28T00:00:00Z", "amount": 27.42})
        self.assertEqual(openai["granted"], 116)
        self.urlopen.assert_not_called()

    def test_null_cost_is_explicitly_partial_upper_bound(self):
        row = self.providers()["openai"]
        self.assertEqual(row["spend_source"], "ledger_partial")
        self.assertEqual(row["spent_since_anchor"], 1.25)
        self.assertAlmostEqual(row["remaining"], 88.83)
        self.assertIn("unknown cost", row["note"])
        self.assertTrue(row["note"].startswith("Fixture note."))

    def test_costs_two_pages_and_thirty_minute_cache(self):
        self.key.write_text("fixture-admin-key\n")
        pages = [self.cost_page(2.25, 0.5, has_more=True, next_page="page two/+"), self.cost_page(1)]
        self.urlopen.side_effect = lambda *args, **kwargs: Response(pages.pop(0))
        row = self.providers()["openai"]
        self.assertEqual(row["spend_source"], "costs_api")
        self.assertEqual(row["spent_since_anchor"], 3.75)
        self.assertAlmostEqual(row["remaining"], 86.33)
        self.assertNotIn("unknown cost", row["note"])
        calls = self.urlopen.call_args_list
        self.assertEqual(len(calls), 2)
        first, second = [call.args[0] for call in calls]
        self.assertEqual(first.get_header("Authorization"), "Bearer fixture-admin-key")
        self.assertEqual(parse_qs(urlparse(first.full_url).query), {
            "start_time": [str(int(server.credit_timestamp(self.anchor)))], "bucket_width": ["1d"], "limit": ["180"]})
        self.assertEqual(parse_qs(urlparse(second.full_url).query)["page"], ["page two/+"])
        self.clock.return_value += 1799
        self.assertEqual(self.providers()["openai"]["spent_since_anchor"], 3.75)
        self.assertEqual(self.urlopen.call_count, 2)
        self.clock.return_value += 1
        self.urlopen.side_effect = lambda *args, **kwargs: Response({"data": [], "has_more": False})
        self.assertEqual(self.providers()["openai"]["spent_since_anchor"], 0)
        self.assertEqual(self.urlopen.call_count, 3)

    def test_costs_failure_or_invalid_pages_fall_back_without_key_in_response(self):
        self.key.write_text("fixture-admin-key")
        for failure in [URLError("fixture-admin-key"),
                        [self.cost_page(50, has_more=True, next_page="p"),
                         URLError("fixture-admin-key")],
                        [{"data": [], "has_more": True, "next_page": None}],
                        [self.cost_page(None)]]:
            with self.subTest(failure=type(failure).__name__):
                server._costs_cache.update(at=0, key=None, spent=None, ttl=0)
                if isinstance(failure, list):
                    def respond(*args, **kwargs):
                        value = failure.pop(0)
                        if isinstance(value, Exception):
                            raise value
                        return Response(value)
                    self.urlopen.side_effect = respond
                else:
                    self.urlopen.side_effect = failure
                code, body = self.request("GET", "/api/credits")
                self.assertEqual(code, 200)
                row = json.loads(body)["providers"][1]
                self.assertEqual(row["spend_source"], "ledger_partial")
                self.assertEqual(row["spent_since_anchor"], 1.25)
                self.assertNotIn(b"fixture-admin-key", body)

    def test_anchor_or_key_change_invalidates_costs_cache(self):
        self.key.write_text("fixture-admin-key")
        self.urlopen.side_effect = lambda *args, **kwargs: Response({"data": [], "has_more": False})
        self.providers()
        self.data["providers"]["openai"]["anchor"]["at"] = "2026-11-21T00:00:00Z"
        self.save_config()
        self.providers()
        self.key.write_text("rotated-fixture-key")
        self.providers()
        self.assertEqual(self.urlopen.call_count, 3)

    def test_zero_floor_no_future_expiry_and_missing_config(self):
        self.data["providers"]["anthropic"]["anchor"]["promo_remaining"] = 1
        self.data["providers"]["anthropic"]["grants"] = []
        self.save_config()
        row = self.providers()["anthropic"]
        self.assertEqual(row["remaining"], 0)
        self.assertIsNone(row["next_expiry"])
        self.config.unlink()
        self.assertEqual(json.loads(self.request("GET", "/api/credits")[1]), {"providers": []})

    def test_credits_host_guard_and_bad_config(self):
        self.assertEqual(self.request("GET", "/api/credits", {"Host": "attacker.example"})[0], 403)
        self.config.write_text("malformed")
        self.assertEqual(self.request("GET", "/api/credits"), (200, b'{"providers":[],"error":"config unreadable"}'))

    def test_default_config_and_ledger_directories(self):
        fleet = self.home / "Dropbox/Macbook Pro/Happlen/agents/infra/fleet/api-credits"
        local = self.home / ".local/state/api-credits/ledger"
        (fleet / "ledger").mkdir(parents=True)
        local.mkdir(parents=True)
        (fleet / "credits.json").write_text(self.config.read_text())
        (fleet / "ledger/a.jsonl").write_text(self.entry("anthropic", 3) + "\n")
        (local / "b.jsonl").write_text(self.entry("anthropic", 4) + "\n")
        with patch.dict(os.environ):
            os.environ.pop("CREDITS_CONFIG", None)
            os.environ.pop("API_CREDITS_LEDGER_DIRS", None)
            self.assertEqual(self.providers()["anthropic"]["spent_since_anchor"], 7)

    def test_real_grant_shape_after_november_expiry_and_spend_order(self):
        self.clean_ledgers()
        self.data["providers"]["openai"]["anchor"] = {"at": "2026-11-21T11:45:00+07:00", "remaining": 90.08}
        self.data["providers"]["openai"]["grants"] = [
            {"name": "ChatGPT Pro API credit", "amount": 51, "remaining": 51,
             "expires": "2026-12-06T00:00:00+07:00"},
            {"name": "grant Jun 2026", "amount": 50, "remaining": 28.67,
             "expires": "2026-11-28T00:00:00+07:00"},
            {"name": "grant May 2026", "amount": 10, "remaining": 10,
             "expires": "2027-06-01T00:00:00+07:00"},
            {"name": "grant May 2026", "amount": 5, "remaining": 0.41,
             "expires": "2027-06-01T00:00:00+07:00"}]
        self.save_config()
        self.write_ledger([self.entry("openai", 10, "2026-11-22T00:00:00Z")])
        self.clock.return_value = server.credit_timestamp("2026-11-29")
        row = self.providers()["openai"]
        self.assertAlmostEqual(row["remaining"], 61.41)
        self.assertEqual(row["granted"], 66)
        self.assertEqual(row["next_expiry"], {"date": "2026-12-06T00:00:00+07:00", "amount": 51})
        self.write_ledger([self.entry("openai", 40, "2026-11-22T00:00:00Z")])
        row = self.providers()["openai"]
        self.assertAlmostEqual(row["remaining"], 50.08)
        self.assertAlmostEqual(row["next_expiry"]["amount"], 39.67)
        self.clock.return_value = server.credit_timestamp("2026-12-07")
        row = self.providers()["openai"]
        self.assertAlmostEqual(row["remaining"], 10.41)
        self.assertEqual(row["granted"], 15)
        self.assertEqual(row["next_expiry"], {"date": "2027-06-01T00:00:00+07:00", "amount": 10})
        self.clock.return_value = server.credit_timestamp("2027-06-02")
        row = self.providers()["openai"]
        self.assertEqual((row["remaining"], row["granted"], row["next_expiry"]), (0, 0, None))

    def test_anthropic_only_claude_api_spends_latest_expiry_promo_bucket(self):
        self.clean_ledgers()
        self.data["providers"]["anthropic"]["grants"].insert(0, {
            "amount": 50, "expires": "2026-11-28T00:00:00Z"})
        self.save_config()
        lines = [json.loads(self.entry("anthropic", amount)) for amount in (1, 3, 4)]
        lines[1]["tool"], lines[2]["tool"] = "claude_cli", "agent_sdk"
        self.write_ledger([json.dumps(line) for line in lines])
        row = self.providers()["anthropic"]
        self.assertEqual(row["spent_since_anchor"], 1)
        self.assertEqual(row["spend_source"], "ledger")
        self.assertAlmostEqual(row["remaining"], 198.95)
        self.assertEqual(row["next_expiry"], {"date": "2026-12-09T00:00:00Z", "amount": 198.95})
        self.assertEqual(row["granted"], 250)
        self.clock.return_value = server.credit_timestamp("2026-11-29")
        self.assertEqual(self.providers()["anthropic"]["granted"], 200)
        self.clock.return_value = server.credit_timestamp("2026-12-10")
        row = self.providers()["anthropic"]
        self.assertEqual((row["remaining"], row["granted"], row["next_expiry"]), (0, 0, None))
        self.assertEqual(row["extra"], 9.07)

    def test_empty_or_malformed_ledger_marks_both_providers_partial(self):
        for content in ("", "not json\n", "[]\n", "\n"):
            with self.subTest(content=content):
                self.clean_ledgers()
                (self.dirs[0] / "bad.jsonl").write_text(content)
                for row in self.providers().values():
                    self.assertEqual(row["spend_source"], "ledger_partial")
                    self.assertEqual(row["spent_since_anchor"], 0)

    def test_invalid_cost_or_timestamp_is_ignored_and_marks_affected_provider_partial(self):
        valid = json.loads(self.entry("openai", 7))
        cases = [{**valid, "usd": value} for value in (None, "1.5", -3, True, float("nan"))]
        cases += [{key: value for key, value in valid.items() if key != "usd"},
                  {**valid, "ts": "invalid"}, {**valid, "ts": None},
                  {key: value for key, value in valid.items() if key != "ts"}]
        for entry in cases:
            with self.subTest(entry=entry):
                self.clean_ledgers()
                self.write_ledger([json.dumps(entry)])
                rows = self.providers()
                self.assertEqual(rows["openai"]["spend_source"], "ledger_partial")
                self.assertEqual(rows["openai"]["spent_since_anchor"], 0)
                self.assertEqual(rows["anthropic"]["spend_source"], "ledger")

    def test_timestamps_normalize_on_python_39_and_date_only_is_bangkok(self):
        expected = datetime(2026, 11, 21, 0, 0, tzinfo=timezone.utc).timestamp()
        for value in ("2026-11-21T00:00:00Z", "2026-11-21T07:00:00+07:00",
                      "2026-11-21T07:00:00+0700", "2026-11-21T00:00:00"):
            self.assertEqual(server.credit_timestamp(value), expected)
        for digits in ("1", "12", "123", "1234", "12345", "123456", "123456789012"):
            value = "2026-11-21T07:00:00." + digits + "+0700"
            self.assertAlmostEqual(server.credit_timestamp(value), expected + float("0." + digits[:6]), places=5)
        self.assertEqual(server.credit_timestamp("2026-11-21"), expected - 7 * 3600)
        self.clean_ledgers()
        self.write_ledger([self.entry("openai", 1, value) for value in (
            "2026-11-21T07:00:00.1+0700", "2026-11-21T00:00:00.123456789Z", "2026-11-21")])
        row = self.providers()["openai"]
        self.assertEqual((row["spent_since_anchor"], row["spend_source"]), (3, "ledger"))

    def test_ledger_deduplicates_uuid_across_serializations_and_raw_lines_without_id(self):
        self.clean_ledgers()
        first = {**json.loads(self.entry("openai", 3)), "id": "fixture-uuid"}
        second = {**first, "id": "another-uuid", "usd": 4}
        raw = self.entry("openai", 2)
        self.write_ledger([json.dumps(first), json.dumps(second), raw])
        (self.dirs[1] / "replica.jsonl").write_text(
            json.dumps(first, sort_keys=True, indent=None, separators=(",", ":")) + "\n" + raw + "\n")
        row = self.providers()["openai"]
        self.assertEqual((row["spent_since_anchor"], row["spend_source"]), (9, "ledger"))

    def test_invalid_duplicate_id_record_still_marks_ledger_partial(self):
        self.clean_ledgers()
        entry = {**json.loads(self.entry("openai", 3)), "id": "fixture-uuid"}
        self.write_ledger([json.dumps(entry), json.dumps({**entry, "ts": "invalid"}),
                           json.dumps({**entry, "usd": -2})])
        row = self.providers()["openai"]
        self.assertEqual((row["spent_since_anchor"], row["spend_source"]), (3, "ledger_partial"))

    def test_costs_failure_is_cached_five_minutes_and_network_does_not_hold_lock(self):
        self.key.write_text("fixture-admin-key")
        lock_available = []
        def fail(*args, **kwargs):
            acquired = server._credits_lock.acquire(blocking=False)
            lock_available.append(acquired)
            if acquired:
                server._credits_lock.release()
            raise URLError("fixture failure")
        self.urlopen.side_effect = fail
        self.assertEqual(self.providers()["openai"]["spend_source"], "ledger_partial")
        self.assertEqual(lock_available, [True])
        self.clock.return_value += 299
        self.providers()
        self.assertEqual(self.urlopen.call_count, 1)
        self.clock.return_value += 1
        self.urlopen.side_effect = lambda *args, **kwargs: Response(self.cost_page(0))
        self.assertEqual(self.providers()["openai"]["spend_source"], "costs_api")
        self.assertEqual(self.urlopen.call_count, 2)

    def test_costs_excludes_old_buckets_and_non_usd_amounts(self):
        self.key.write_text("fixture-admin-key")
        anchor = server.credit_timestamp(self.anchor)
        body = self.cost_page(2.5)
        body["data"] += self.cost_page(100, end_time=anchor)["data"]
        body["data"] += self.cost_page(200, end_time=anchor - 1)["data"]
        body["data"] += self.cost_page(None, currency="eur")["data"]
        body["data"] += self.cost_page(300, currency="")["data"]
        body["data"] += self.cost_page(None, currency=None)["data"]
        self.urlopen.side_effect = lambda *args, **kwargs: Response(body)
        self.assertEqual(self.providers()["openai"]["spent_since_anchor"], 2.5)

    def test_costs_redirect_is_refused_without_sending_authorization_to_new_host(self):
        self.key.write_text("fixture-admin-key")
        requests = []
        class RedirectTransport(server.urllib.request.HTTPSHandler):
            def https_open(self, request):
                requests.append(request)
                headers = Message()
                headers["Location"] = "https://attacker.example/collect"
                response = addinfourl(io.BytesIO(b""), headers, request.full_url, code=302)
                response.msg = "Found"
                return response
        opener = server.urllib.request.build_opener(server.NoCreditRedirects(), RedirectTransport())
        with patch.object(server, "_credits_opener", opener):
            row = self.providers()["openai"]
        self.assertEqual(row["spend_source"], "ledger_partial")
        self.assertEqual(len(requests), 1)
        self.assertEqual(urlparse(requests[0].full_url).hostname, "api.openai.com")

    def test_bad_provider_or_grant_returns_only_error_without_breaking_other_provider(self):
        original = json.loads(json.dumps(self.data["providers"]["anthropic"]))
        for broken in (None, {**original, "anchor": {}}, {**original, "grants": [None]},
                       {**original, "grants": [{"amount": -1, "expires": "2026-12-09"}]},
                       {**original, "grants": [{"amount": 1, "expires": "invalid"}]}):
            with self.subTest(broken=broken):
                self.data["providers"]["anthropic"] = broken
                self.save_config()
                code, body = self.request("GET", "/api/credits")
                self.assertEqual(code, 200)
                bad, good = json.loads(body)["providers"]
                self.assertLess(len(bad["error"]), 40)
                self.assertFalse(set(bad) & {"remaining", "granted", "spent_since_anchor", "extra", "stale_days"})
                self.assertAlmostEqual(good["remaining"], 88.83)
        self.data["providers"]["anthropic"] = original
        self.data["providers"]["openai"]["grants"] = "broken"
        self.save_config()
        rows = self.providers()
        self.assertAlmostEqual(rows["anthropic"]["remaining"], 197.4)
        self.assertIn("error", rows["openai"])

    def test_empty_or_invalid_config_is_http_200_with_config_error(self):
        for content in ("", "malformed", "[]", "null", '{"providers": []}', '{}'):
            with self.subTest(content=content):
                self.config.write_text(content)
                code, body = self.request("GET", "/api/credits")
                self.assertEqual(code, 200)
                self.assertEqual(json.loads(body), {"providers": [], "error": "config unreadable"})

    def add_claude_organization(self):
        original = self.data["providers"]["anthropic"]
        original["label"] = "Claude API · kkpk"
        second = json.loads(json.dumps(original))
        second.update(type="anthropic", ledger_account="anthropic-pho", label="Claude API · pho")
        second["anchor"].update(promo_remaining=200, purchased_remaining=1.5)
        self.data["providers"] = {"anthropic": original, "anthropic_pho": second,
                                  "openai": self.data["providers"]["openai"]}
        self.save_config()

    def account_entry(self, account, usd, ts="2026-11-21T01:00:00Z", tool="claude_api"):
        entry = json.loads(self.entry("anthropic", usd, ts))
        entry.update(account=account, tool=tool)
        return json.dumps(entry)

    def test_multiple_claude_orgs_route_explicit_and_legacy_accounts_independently(self):
        self.clean_ledgers()
        self.add_claude_organization()
        pho = self.account_entry("anthropic-pho", 3)
        self.write_ledger([self.entry("anthropic", 2), self.account_entry("anthropic", 1.25), pho,
                           self.account_entry("anthropic-pho", 50, ts="2026-11-19T00:00:00Z"),
                           self.account_entry("anthropic-pho", 90, tool="agent_sdk"),
                           self.account_entry("unconfigured-org", 7), self.entry("openai", 1.5)])
        (self.dirs[1] / "replica.jsonl").write_text(pho + "\n")
        code, body = self.request("GET", "/api/credits")
        self.assertEqual(code, 200)
        rows = json.loads(body)["providers"]
        self.assertEqual([row["id"] for row in rows], ["anthropic", "anthropic_pho", "openai"])
        self.assertEqual([row["type"] for row in rows], ["anthropic", "anthropic", "openai"])
        self.assertEqual([row["label"] for row in rows], ["Claude API · kkpk", "Claude API · pho", "OpenAI API"])
        self.assertEqual([row["spent_since_anchor"] for row in rows], [3.25, 3, 1.5])
        for row, expected in zip(rows, (196.7, 197, 88.58)):
            self.assertAlmostEqual(row["remaining"], expected)
            self.assertEqual(row["spend_source"], "ledger")
            self.assertAlmostEqual(row["next_expiry"]["amount"], expected if row["type"] == "anthropic" else 27.17)
        self.assertEqual(rows[0]["extra"], 9.07)
        self.assertEqual(rows[1]["extra"], 1.5)
        self.urlopen.assert_not_called()

    def test_provider_config_order_is_preserved_including_error_rows(self):
        self.add_claude_organization()
        providers = self.data["providers"]
        self.data["providers"] = {key: providers[key] for key in ("openai", "anthropic_pho", "anthropic")}
        self.data["providers"]["anthropic_pho"]["grants"] = "invalid"
        self.save_config()
        rows = server.fetch_credits()["providers"]
        self.assertEqual([row["id"] for row in rows], ["openai", "anthropic_pho", "anthropic"])
        self.assertEqual(rows[1]["type"], "anthropic")
        self.assertEqual(rows[1]["label"], "Claude API · pho")
        self.assertEqual(rows[1]["error"], "invalid grant")
        self.assertNotIn("remaining", rows[1])
        self.assertIn("remaining", rows[0])
        self.assertIn("remaining", rows[2])

    def test_any_provider_id_uses_explicit_type_for_grants_and_ledger_matching(self):
        self.clean_ledgers()
        anthropic, openai = self.data["providers"].values()
        self.data["providers"] = {"org A / promo": {**anthropic, "type": "anthropic"},
                                  "api-budget": {**openai, "type": "openai"}}
        self.save_config()
        self.write_ledger([self.entry("anthropic", 2), self.entry("openai", 3)])
        rows = self.providers()
        self.assertEqual(list(rows), ["org A / promo", "api-budget"])
        self.assertEqual(rows["org A / promo"]["type"], "anthropic")
        self.assertAlmostEqual(rows["org A / promo"]["remaining"], 197.95)
        self.assertEqual(rows["api-budget"]["type"], "openai")
        self.assertAlmostEqual(rows["api-budget"]["remaining"], 87.08)
        self.assertEqual(rows["api-budget"]["spend_source"], "ledger")

    def test_custom_openai_id_still_prefers_costs_api_and_falls_back_to_ledger(self):
        openai = self.data["providers"].pop("openai")
        self.data["providers"]["api-budget"] = {**openai, "type": "openai"}
        self.save_config()
        self.key.write_text("fixture-admin-key")
        self.urlopen.side_effect = lambda *args, **kwargs: Response(self.cost_page(2))
        row = self.providers()["api-budget"]
        self.assertEqual(row["spend_source"], "costs_api")
        self.assertEqual(row["spent_since_anchor"], 2)
        self.assertAlmostEqual(row["remaining"], 88.08)
        self.clock.return_value += server.COSTS_CACHE_SECONDS
        self.urlopen.side_effect = URLError("fixture failure")
        row = self.providers()["api-budget"]
        self.assertEqual(row["spend_source"], "ledger_partial")
        self.assertEqual(row["spent_since_anchor"], 1.25)
        self.assertAlmostEqual(row["remaining"], 88.83)

    def test_default_ledger_account_and_each_provider_anchor_apply_with_shared_account(self):
        self.clean_ledgers()
        self.add_claude_organization()
        second = self.data["providers"]["anthropic_pho"]
        second.pop("ledger_account")
        second["anchor"]["at"] = "2026-11-21T00:00:00Z"
        self.save_config()
        self.write_ledger([self.entry("anthropic", 5, "2026-11-20T12:00:00Z"),
                           self.account_entry("anthropic", 2), self.account_entry("anthropic-pho", 9)])
        rows = self.providers()
        self.assertEqual(rows["anthropic"]["spent_since_anchor"], 7)
        self.assertEqual(rows["anthropic_pho"]["spent_since_anchor"], 2)
        self.assertEqual(rows["anthropic_pho"]["remaining"], 198)

    def test_partial_ledger_cost_marks_only_matching_claude_account(self):
        self.clean_ledgers()
        self.add_claude_organization()
        self.write_ledger([self.account_entry("anthropic-pho", None), self.entry("anthropic", 2)])
        rows = self.providers()
        self.assertEqual(rows["anthropic_pho"]["spend_source"], "ledger_partial")
        self.assertEqual(rows["anthropic"]["spend_source"], "ledger")
        self.assertEqual(rows["openai"]["spend_source"], "ledger")
        self.write_ledger([self.account_entry(None, 1)])
        rows = self.providers()
        self.assertEqual(rows["anthropic"]["spend_source"], "ledger_partial")
        self.assertEqual(rows["anthropic_pho"]["spend_source"], "ledger_partial")
        self.assertEqual(rows["openai"]["spend_source"], "ledger")

    def test_custom_claude_provider_expiry_keeps_purchased_extra(self):
        self.add_claude_organization()
        self.clock.return_value = server.credit_timestamp("2026-12-10")
        row = self.providers()["anthropic_pho"]
        self.assertEqual((row["remaining"], row["granted"], row["next_expiry"]), (0, 0, None))
        self.assertEqual(row["extra"], 1.5)

    def test_invalid_type_or_account_is_isolated_to_its_provider(self):
        self.add_claude_organization()
        original = json.loads(json.dumps(self.data["providers"]["anthropic_pho"]))
        for fields, reason, expected_type in (({"type": "unsupported"}, "invalid type", None),
                                              ({"type": []}, "invalid type", None),
                                              ({"type": None}, "invalid type", None),
                                              ({"type": 17}, "invalid type", None),
                                              ({"type": True}, "invalid type", None),
                                              ({"type": "unsupported", "label": ""}, "invalid type", None),
                                              ({"ledger_account": None}, "invalid ledger account", "anthropic"),
                                              ({"ledger_account": ""}, "invalid ledger account", "anthropic"),
                                              ({"label": 17}, "invalid provider", "anthropic"),
                                              ({"label": None}, "invalid provider", "anthropic")):
            with self.subTest(fields=fields):
                second = {**original, **fields}
                self.data["providers"]["anthropic_pho"] = second
                self.save_config()
                rows = self.providers()
                expected = {"id": "anthropic_pho", "console": original["console"], "error": reason,
                            "label": second["label"] if isinstance(second["label"], str) else "anthropic_pho"}
                if expected_type is not None:
                    expected["type"] = expected_type
                self.assertEqual(rows["anthropic_pho"], expected)
                self.assertAlmostEqual(rows["anthropic"]["remaining"], 197.4)
                self.assertAlmostEqual(rows["openai"]["remaining"], 88.83)

    def test_unknown_id_without_type_omits_type_and_keeps_configured_label(self):
        self.add_claude_organization()
        second = self.data["providers"]["anthropic_pho"]
        second.pop("type")
        self.save_config()
        self.assertEqual(self.providers()["anthropic_pho"], {
            "id": "anthropic_pho", "label": "Claude API · pho", "console": second["console"],
            "error": "invalid type"})

    def test_invalid_explicit_type_never_falls_back_to_a_known_provider_id(self):
        for provider in ("anthropic", "openai"):
            data = self.data["providers"][provider]
            data["type"] = None
            self.save_config()
            with self.subTest(provider=provider):
                self.assertEqual(self.providers()[provider], {
                    "id": provider, "label": data["label"], "console": data["console"],
                    "error": "invalid type"})
            data.pop("type")

    def test_error_label_without_configured_string_uses_id(self):
        self.data["providers"]["anthropic"] = None
        self.save_config()
        self.assertEqual(self.providers()["anthropic"], {
            "id": "anthropic", "type": "anthropic", "label": "anthropic", "error": "invalid provider"})

    def test_ledger_ids_are_scoped_by_provider_and_account_and_deduplicated_across_dirs(self):
        self.clean_ledgers()
        self.add_claude_organization()
        entries = [json.loads(self.account_entry("anthropic", 2)),
                   json.loads(self.account_entry("anthropic-pho", 3)),
                   {**json.loads(self.entry("openai", 1.5)), "account": "anthropic"}]
        for entry in entries:
            entry["id"] = "shared-fixture-id"
        self.write_ledger([json.dumps(entry) for entry in entries])
        (self.dirs[1] / "replica.jsonl").write_text("\n".join(
            json.dumps(entry, sort_keys=True, separators=(",", ":")) for entry in entries) + "\n")
        rows = self.providers()
        self.assertEqual([row["spent_since_anchor"] for row in rows.values()], [2, 3, 1.5])
        self.assertAlmostEqual(rows["anthropic"]["remaining"], 197.95)
        self.assertEqual(rows["anthropic_pho"]["remaining"], 197)
        self.assertAlmostEqual(rows["openai"]["remaining"], 88.58)
        self.assertEqual([row["spend_source"] for row in rows.values()], ["ledger"] * 3)


if __name__ == "__main__":
    unittest.main()
