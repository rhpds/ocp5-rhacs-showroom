"""Execute module commands against the current oc context."""

from __future__ import annotations

import os
import re
import select
import shlex
import signal
import subprocess
import tempfile
import time
import uuid
from collections.abc import Callable
from pathlib import Path

from .compare import missing_lines
from .parse import Step, protected_namespace, substitute

DEFAULT_TIMEOUT = 45
MAX_TIMEOUT = 150
DECLARED_TIMEOUT_RE = re.compile(r"--timeout(?:=|\s+)(\d+)\s*([smh])?")


class BashSession:
    """One bash process so cd and source persist for a module."""

    def __init__(self, cwd: Path) -> None:
        self.cwd = cwd
        self.proc: subprocess.Popen[bytes] | None = None
        self.pending = b""
        self.start()

    def start(self) -> None:
        self.pending = b""
        self.proc = subprocess.Popen(
            ["bash", "--noprofile", "--norc"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            cwd=self.cwd,
            start_new_session=True,
        )

    def close(self) -> None:
        proc = self.proc
        self.proc = None
        if proc is None or proc.poll() is not None:
            return
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=5)

    def run(
        self,
        command: str,
        timeout: int,
        on_wait: Callable[[int], None] | None = None,
    ) -> tuple[str, int | None, str]:
        if self.proc is None or self.proc.poll() is not None:
            self.start()
        assert self.proc is not None and self.proc.stdin and self.proc.stdout
        sentinel = f"__SHOWROOM_{uuid.uuid4().hex}__"
        marker = f"{sentinel}:".encode()
        captured = bytearray(self.pending)
        self.pending = b""
        command_path = _command_file(command)
        script = (
            "set +e\n"
            f"source {shlex.quote(command_path)} </dev/null\n"
            "__rc=$?\n"
            f"printf '%s\\n' '{sentinel}:'$__rc\n"
        ).encode()
        stdin = self.proc.stdin
        stdout = self.proc.stdout
        os.set_blocking(stdin.fileno(), False)
        started = time.monotonic()
        deadline = started + timeout
        last_note = started
        try:
            while True:
                now = time.monotonic()
                if now >= deadline:
                    output = captured.decode(errors="replace")
                    self.close()
                    self.start()
                    return output, None, "timeout"
                if on_wait and now - last_note >= 15:
                    on_wait(int(now - started))
                    last_note = now
                remaining = deadline - now
                writeable = [stdin] if script else []
                try:
                    readable, ready, _ = select.select(
                        [stdout], writeable, [], min(remaining, 1.0)
                    )
                except InterruptedError:
                    continue
                except ValueError:
                    output = captured.decode(errors="replace")
                    self.close()
                    self.start()
                    return output, None, "shell exited"
                if ready and script:
                    try:
                        written = os.write(stdin.fileno(), script)
                    except BlockingIOError:
                        written = 0
                    except BrokenPipeError:
                        script = b""
                    else:
                        script = script[written:]
                if readable:
                    try:
                        chunk = os.read(stdout.fileno(), 65536)
                    except OSError:
                        chunk = b""
                    if chunk:
                        captured.extend(chunk)
                        if marker in captured:
                            return self._finish(bytes(captured), marker)
                        continue
                if self.proc.poll() is not None and not script:
                    output = captured.decode(errors="replace")
                    self.close()
                    self.start()
                    return output, None, "shell exited"
        finally:
            try:
                os.unlink(command_path)
            except OSError:
                pass

    def _finish(self, blob: bytes, marker: bytes) -> tuple[str, int | None, str]:
        head, tail = blob.rsplit(marker, 1)
        rc_line, sep, rest = tail.partition(b"\n")
        self.pending = rest if sep else b""
        rc_text = rc_line.decode(errors="replace").strip()
        try:
            rc = int(rc_text)
        except ValueError:
            rc = None
        return head.decode(errors="replace"), rc, ""


def _command_file(command: str) -> str:
    handle, path = tempfile.mkstemp(prefix="showroom-cmd-", suffix=".sh")
    with os.fdopen(handle, "w", encoding="utf-8") as command_file:
        command_file.write(command)
        if not command.endswith("\n"):
            command_file.write("\n")
    return path


def command_timeout(command: str, default: int = DEFAULT_TIMEOUT) -> int:
    """How long a command may run before the runner kills it and moves on.

    Plain API calls use the short default. A command that declares its own
    ``--timeout`` may use that, up to a few minutes, so a rollout can finish
    without a 10-minute wait holding the rest of the module.
    """
    limit = 900 if "lab-environment.sh" in command else default
    for amount, unit in DECLARED_TIMEOUT_RE.findall(command):
        seconds = int(amount)
        if unit == "m":
            seconds *= 60
        elif unit == "h":
            seconds *= 3600
        limit = max(limit, seconds + 15)
    if "lab-environment.sh" in command:
        return limit
    return min(limit, MAX_TIMEOUT)


def reset_namespaces(names: list[str]) -> list[dict]:
    results = []
    for name in names:
        if protected_namespace(name) or name.startswith(("{", "$")):
            results.append(
                {
                    "namespace": name,
                    "deleted": False,
                    "detail": "left in place",
                }
            )
            continue
        print(f"  delete namespace {name}", flush=True)
        try:
            completed = subprocess.run(
                [
                    "oc",
                    "delete",
                    "namespace",
                    name,
                    "--ignore-not-found",
                    "--wait=true",
                    "--timeout=30s",
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=40,
            )
        except subprocess.TimeoutExpired:
            results.append(
                {
                    "namespace": name,
                    "deleted": False,
                    "detail": "timed out",
                }
            )
            continue
        detail = (completed.stderr or completed.stdout).strip()
        results.append(
            {
                "namespace": name,
                "deleted": completed.returncode == 0,
                "detail": detail,
            }
        )
    return results


def load_attributes() -> dict[str, str]:
    domain = _oc(
        "get",
        "ingresses.config.openshift.io",
        "cluster",
        "-o",
        "jsonpath={.spec.domain}",
    )
    who = _oc("whoami")
    attrs = {
        "openshift_cluster_ingress_domain": domain,
        "openshift_cluster_console_url": f"https://console-openshift-console.apps.{domain}",
        "openshift_cluster_admin_username": who,
        "openshift_admin_user": who,
        "acs_namespace": "rhacs-operator",
        "acs_host": f"central-reencrypt-stackrox.{domain}",
        "acs_route": f"https://central-reencrypt-stackrox.{domain}",
        "acs_portal_username": "admin",
        "quay_url": f"registry-quay-quay.{domain}",
        "quay_console_url": f"https://registry-quay-quay.{domain}",
        "vm_user": "cloud-user",
        "gitea_username": "student",
        "gitea_url": f"https://gitea.{domain}",
        "keycloak_url": f"https://sso-tpa.{domain}",
        "keycloak_admin_username": "admin",
        "keycloak_username": "tpa-user",
        "rhtpa_url": f"https://server-trusted-profile-analyzer.{domain}",
        "rhtpa_username": "tpa-user",
        "rhdh_url": f"https://backstage-developer-hub-rhdh.{domain}",
        "openshift_gitops_url": f"https://openshift-gitops-server-openshift-gitops.{domain}",
    }
    password = os.environ.get("SHOWROOM_COMMON_PASSWORD", "")
    if password:
        attrs["common_password"] = password
        attrs["openshift_cluster_admin_password"] = password
        attrs["openshift_admin_password"] = password
        attrs["acs_portal_password"] = password
        attrs["quay_admin_password"] = password
        attrs["vm_password"] = password
        attrs["gitea_password"] = password
        attrs["keycloak_admin_password"] = password
        attrs["keycloak_password"] = password
        attrs["rhtpa_password"] = password
    return attrs


def _oc(*args: str) -> str:
    completed = subprocess.run(
        ["oc", *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise RuntimeError(f"oc {' '.join(args)} failed: {detail}")
    return completed.stdout.strip()


def run_step(
    session: BashSession,
    step: Step,
    attrs: dict[str, str],
    timeout: int,
    on_wait: Callable[[int], None] | None = None,
) -> dict:
    command = substitute(step.command, attrs)
    record = {
        "index": step.index,
        "line": step.line,
        "command": command,
        "expected_kind": step.expected_kind,
        "status": "passed",
        "exit_code": None,
        "detail": "",
        "missing_lines": [],
        "output": "",
    }
    if step.skipped:
        record["status"] = "skipped"
        record["detail"] = step.skip_reason
        return record
    limit = command_timeout(command, timeout)
    output, rc, error = session.run(command, limit, on_wait=on_wait)
    record["output"] = output
    record["exit_code"] = rc
    if error == "timeout":
        record["status"] = "failed"
        record["detail"] = f"timed out after {limit}s"
        return record
    if error:
        record["status"] = "failed"
        record["detail"] = error
        return record
    if rc != 0:
        record["status"] = "failed"
        record["detail"] = f"exit code {rc}"
        return record
    if step.expected:
        expected = substitute(step.expected, attrs)
        missing = missing_lines(expected, output, attrs.get("openshift_cluster_ingress_domain", ""))
        if missing:
            record["status"] = "failed"
            record["missing_lines"] = missing
            record["detail"] = f"{len(missing)} expected line(s) missing"
    else:
        record["detail"] = "no expected output"
    return record
