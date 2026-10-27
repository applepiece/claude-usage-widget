"""Offline API, registry and cache contracts; no sockets or real credentials."""
import io
import builtins
import json
import os
import subprocess
import tempfile
import threading
import time
import unittest
from datetime import datetime, timezone
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
               "five_hour", "seven_day", "limits", "state", "fetched_at", "expires_at",
               "provider", "as_of", "quota_source"}


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
        self.enter(patch.dict(os.environ, {
            "CLAUDE_USAGE_ACCOUNTS_DIR": str(self.directory),
            "CLAUDE_USAGE_BRIDGE_ENV": str(self.envfile),
            "CLAUDE_USAGE_PROBE_SECONDS": "600",
            "CLAUDE_USAGE_PROBE_MODEL": "claude-haiku-4-5-20251001",
            "CLAUDE_USAGE_CODEX_ENV": str(self.codex_env),
            "CLAUDE_USAGE_CODEX_BIN": str(self.home / "missing-codex"),
            "CLAUDE_USAGE_CODEX_SECONDS": "300",
        }))
        self.enter(patch.object(Path, "home", return_value=self.home))
        self.keychain = self.enter(patch.object(server, "keychain_read", side_effect=server.SignedOut()))
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
        path.write_text("#!/usr/bin/env python3\n" + body)
        path.chmod(0o700)
        return patch.dict(os.environ, {"CLAUDE_USAGE_CODEX_BIN": str(path)})

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
    "clientInfo": {"name": "claude-usage-widget", "version": "3.0.1"}}}
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
            account, limits = server.codex_app_server_read(home, timeout=2)
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
                server.codex_app_server_read(self.home, timeout=2)
            self.assertLess(time.monotonic() - start, 5)
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
                        server.codex_app_server_read(self.home, timeout=2)

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
        self.assertEqual(self.request("GET", "/api/ping"), (200, b'{"ok":true,"version":"3.0.1"}'))
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


if __name__ == "__main__":
    unittest.main()
