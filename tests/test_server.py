"""Offline API, registry and cache contracts; no sockets or real credentials."""
import io
import json
import os
import subprocess
import tempfile
import threading
import unittest
from email.message import Message
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError, URLError

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
               "five_hour", "seven_day", "limits", "state", "fetched_at", "expires_at"}


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
        self.enter(patch.dict(os.environ, {
            "CLAUDE_USAGE_ACCOUNTS_DIR": str(self.directory),
            "CLAUDE_USAGE_BRIDGE_ENV": str(self.envfile),
            "CLAUDE_USAGE_PROBE_SECONDS": "600",
            "CLAUDE_USAGE_PROBE_MODEL": "claude-haiku-4-5-20251001",
        }))
        self.enter(patch.object(Path, "home", return_value=self.home))
        self.keychain = self.enter(patch.object(server, "keychain_read", side_effect=server.SignedOut()))
        self.subprocess = self.enter(patch.object(server.subprocess, "run", side_effect=AssertionError("real subprocess forbidden")))
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
        self.assertEqual(json.loads(self.request("GET", "/api/ping")[1]), {"ok": True})
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


if __name__ == "__main__":
    unittest.main()
