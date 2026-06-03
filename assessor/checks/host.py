"""호스트 상태 검사 — docker.sock 로 대상 컨테이너에 read-only argv exec.

모든 명령은 고정 템플릿 + 화이트리스트 파라미터로만 합성한다(base.py 참조).
부작용 0 — test/stat/grep/sha256sum/pgrep/ss/tail 만 사용.
"""
from __future__ import annotations

from typing import Any

from . import base
from .base import CheckError, Executor, ExecResult
from ..targets import resolve_container, resolve_ip


def _container_for(spec: dict[str, Any], default: str | None = None) -> str:
    """spec 의 target/container 별칭 → 컨테이너명. 둘 다 없으면 default."""
    name = spec.get("container") or spec.get("target") or default
    if not name:
        raise CheckError("target/container 누락")
    try:
        return resolve_container(name)
    except KeyError as e:
        raise CheckError(str(e))


# ─── file_exists {path, container} ───────────────────────────────────────────
def file_exists(spec, ex: Executor):
    p = spec["params"]
    path = base.validate_path(p.get("path"))
    cont = _container_for(spec)
    # stat: 존재하면 exit 0 + 메타. argv 직접 실행 → 주입 불가.
    r = ex.exec(cont, ["stat", "-c", "%n|size=%s|mtime=%y", "--", path])
    passed = r.exit_code == 0
    ev = r.stdout.strip() if passed else f"not found: {path}"
    return base.ok(spec["id"], passed, ev, {"exit_code": r.exit_code, "container": cont})


# ─── file_contains {path, pattern|regex, container} ──────────────────────────
def file_contains(spec, ex: Executor):
    p = spec["params"]
    path = base.validate_path(p.get("path"))
    cont = _container_for(spec)
    if p.get("regex") is not None:
        pat = base.validate_pattern(p.get("regex"), "regex")
        mode = "-E"           # 확장 정규식
    else:
        pat = base.validate_pattern(p.get("pattern"), "pattern")
        mode = "-F"           # 고정 문자열
    # grep -n -m1: 첫 매치 라인(번호 포함) = evidence. exit 0 = 매치.
    r = ex.exec(cont, ["grep", mode, "-n", "-m", "1", "-e", pat, "--", path])
    passed = r.exit_code == 0
    ev = r.stdout.strip() if passed else f"no match for {pat!r} in {path}"
    return base.ok(spec["id"], passed, ev, {"exit_code": r.exit_code, "container": cont})


# ─── file_hash {path, container, sha256?} ────────────────────────────────────
def file_hash(spec, ex: Executor):
    p = spec["params"]
    path = base.validate_path(p.get("path"))
    cont = _container_for(spec)
    r = ex.exec(cont, ["sha256sum", "--", path])
    if r.exit_code != 0:
        return base.ok(spec["id"], False, f"hash 실패(파일 없음?): {path}",
                       {"exit_code": r.exit_code, "container": cont})
    digest = r.stdout.strip().split()[0] if r.stdout.strip() else ""
    expected = p.get("sha256") or p.get("expected")
    if expected:
        expected = base.validate_pattern(str(expected), "sha256")
        passed = digest.lower() == expected.lower()
        ev = f"sha256={digest} expected={expected} match={passed}"
    else:
        passed = bool(digest)
        ev = f"sha256={digest}"
    return base.ok(spec["id"], passed, ev, {"sha256": digest, "container": cont})


# ─── process_running {name|pattern, container} ───────────────────────────────
def process_running(spec, ex: Executor):
    p = spec["params"]
    value = p.get("pattern") or p.get("name")
    pat = base.validate_pattern(value, "name|pattern")
    if pat.startswith("-"):
        raise CheckError("name|pattern 은 '-' 로 시작 불가")
    cont = _container_for(spec)
    # pgrep -a -f: cmdline 전체 매칭 + 매치된 pid/cmdline 출력. exit 0 = 실행 중.
    r = ex.exec(cont, ["pgrep", "-a", "-f", pat])
    passed = r.exit_code == 0
    ev = r.stdout.strip() if passed else f"no process matching {pat!r}"
    return base.ok(spec["id"], passed, ev, {"exit_code": r.exit_code, "container": cont})


# ─── port_listening {port, container} ────────────────────────────────────────
def port_listening(spec, ex: Executor):
    p = spec["params"]
    port = base.validate_port(p.get("port"))
    cont = _container_for(spec)
    # ss -ltn: 헤더 + LISTEN 소켓. python 에서 로컬주소 컬럼 끝이 :port 인 라인만 매칭(주입 면역).
    r = ex.exec(cont, ["ss", "-ltn"])
    matched = []
    for ln in r.stdout.splitlines():
        cols = ln.split()
        # ss 출력: State Recv-Q Send-Q Local Local:Port Peer ...
        for col in cols:
            if col.rsplit(":", 1)[-1] == str(port) and ":" in col:
                matched.append(ln.strip())
                break
    passed = bool(matched)
    ev = matched[0] if passed else f"port {port} not listening"
    return base.ok(spec["id"], passed, ev, {"container": cont, "matches": len(matched)})


# ─── log_contains {log, pattern, since_sec?, container?} ─────────────────────
# 로그 별칭 → (컨테이너 기본값, 경로). auth 는 container 파라미터 필요.
_LOG_MAP = {
    "suricata":     ("ips", "/var/log/suricata/eve.json"),
    "modsec":       ("web", "/var/log/apache2/modsec_audit.log"),
    "apache_error": ("web", "/var/log/apache2/error.log"),
    "auth":         (None,  "/var/log/auth.log"),
}


def log_contains(spec, ex: Executor):
    p = spec["params"]
    log = p.get("log")
    if log not in _LOG_MAP:
        raise CheckError(f"미지원 log 별칭: {log!r} (지원: {sorted(_LOG_MAP)})")
    pat = base.validate_pattern(p.get("pattern"), "pattern")
    default_cont, path = _LOG_MAP[log]
    cont = _container_for(spec, default=default_cont)
    # tail 로 최근 라인만 read-only 로 가져와 python 에서 매칭(주입 면역).
    r = ex.exec(cont, ["tail", "-n", "4000", path])
    import re as _re
    try:
        rx = _re.compile(pat)
    except _re.error:
        # 정규식 컴파일 실패 시 고정 문자열 매칭으로 fallback
        rx = None
    hits = []
    for ln in r.stdout.splitlines():
        if (rx.search(ln) if rx else (pat in ln)):
            hits.append(ln)
    passed = bool(hits)
    ev = hits[-1] if passed else f"no log line matching {pat!r} in {log}"
    return base.ok(spec["id"], passed, ev,
                   {"container": cont, "path": path, "matches": len(hits)})


HANDLERS = {
    "file_exists":     file_exists,
    "file_contains":   file_contains,
    "file_hash":       file_hash,
    "process_running": process_running,
    "port_listening":  port_listening,
    "log_contains":    log_contains,
}
