#!/usr/bin/env python3
"""Pull the showroom repo on each bastion, run lab setup, and report status."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from bastions import (
    Bastion,
    HostResult,
    add_connection_args,
    append_results,
    bastions_from_args,
    ensure_paramiko,
    header,
    redact,
    run_remote,
    write_host_log,
    execute_all,
)

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_RESULTS = SCRIPT_DIR / "results.log"
DEFAULT_LOG_DIR = SCRIPT_DIR / "logs"
DEFAULT_REPO_URL = "https://github.com/rhpds/ocp5-rhacs-showroom.git"
RESULT_MARK = "===== RESULT ====="

# Clone or fast-forward ~/ocp5-rhacs-showroom, then run setup/lab-environment.sh.
# Module labs (vault, splunk, ztwim, and the rest) are not invoked.
CONFIGURE_SCRIPT = r"""
set -u
REPO_URL="${1:-https://github.com/rhpds/ocp5-rhacs-showroom.git}"
REPO_DIR="${HOME}/ocp5-rhacs-showroom"

export PATH="${HOME}/.local/bin:${HOME}/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
export GIT_TERMINAL_PROMPT=0
if [[ -z "${KUBECONFIG:-}" && -f "${HOME}/.kube/config" ]]; then
  export KUBECONFIG="${HOME}/.kube/config"
fi

repo_rc=0
if [[ ! -d "${REPO_DIR}/.git" ]]; then
  if [[ -e "${REPO_DIR}" ]]; then
    echo "ERROR: ${REPO_DIR} exists but is not a git checkout"
    repo_rc=1
  else
    echo "Cloning ${REPO_URL} into ${REPO_DIR}"
    git clone -- "${REPO_URL}" "${REPO_DIR}" || repo_rc=$?
  fi
else
  if [[ -n "$(git -C "${REPO_DIR}" status --porcelain)" ]]; then
    echo "ERROR: dirty tree in ${REPO_DIR}; not resetting"
    git -C "${REPO_DIR}" status --porcelain
    repo_rc=1
  else
    echo "Updating ${REPO_DIR}"
    git -C "${REPO_DIR}" pull --ff-only || repo_rc=$?
  fi
fi

if [[ "$repo_rc" -ne 0 ]]; then
  echo "===== RESULT ====="
  echo "LAB_EXIT=skipped"
  echo "BASTION_LOG="
  echo "STATUS: failed"
  echo "ERROR: git update failed"
  exit 1
fi

echo "GIT_BRANCH=$(git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD)"
echo "GIT_HEAD=$(git -C "${REPO_DIR}" rev-parse --short HEAD)"

lab_rc=0
bash "${REPO_DIR}/setup/lab-environment.sh" || lab_rc=$?

latest=""
if compgen -G "${HOME}/.acs-roadshow/lab-environment-*.log" >/dev/null; then
  latest="$(ls -1t "${HOME}/.acs-roadshow"/lab-environment-*.log | head -1)"
fi

echo "===== RESULT ====="
echo "GIT_BRANCH=$(git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD)"
echo "GIT_HEAD=$(git -C "${REPO_DIR}" rev-parse --short HEAD)"
echo "LAB_EXIT=${lab_rc}"
echo "BASTION_LOG=${latest}"

if [[ "$lab_rc" -ne 0 ]]; then
  echo "STATUS: failed"
  exit "${lab_rc}"
fi

fail=0
if oc whoami >/dev/null 2>&1; then
  echo "CHECK oc whoami: ok ($(oc whoami))"
else
  echo "CHECK oc whoami: failed"
  fail=1
fi

envfile="${HOME}/.acs-roadshow/env"
for key in QUAY_TOKEN ROX_API_TOKEN; do
  if [[ -f "${envfile}" ]] && grep -Eq "^export ${key}=.+" "${envfile}"; then
    echo "CHECK ${key}: set"
  else
    echo "CHECK ${key}: missing"
    fail=1
  fi
done

for cmd in cosign oc-mirror ec mvn; do
  if command -v "${cmd}" >/dev/null 2>&1; then
    echo "CHECK ${cmd}: ok ($(command -v "${cmd}"))"
  else
    echo "CHECK ${cmd}: missing"
    fail=1
  fi
done

if [[ "$fail" -eq 0 ]]; then
  echo "STATUS: up to date and configured"
  exit 0
fi
echo "STATUS: setup finished with missing checks"
exit 1
"""


def _display_lines(output: str, ok: bool) -> list[str]:
    if ok and RESULT_MARK in output:
        footer = output.split(RESULT_MARK, 1)[1].strip()
        return footer.splitlines()
    rows = output.splitlines()
    if not rows:
        return ["ERROR: no output from bastion"]
    return rows[-40:]


def configure_one(bastion: Bastion, repo_url: str, timeout: int) -> HostResult:
    rc, output = run_remote(
        bastion,
        CONFIGURE_SCRIPT,
        [repo_url],
        timeout=timeout,
    )
    output = redact(output, bastion.password)
    log_path = write_host_log(DEFAULT_LOG_DIR, bastion, output)
    ok = rc == 0 and "STATUS: up to date and configured" in output
    lines = [header(bastion), *_display_lines(output, ok), f"Local log: {log_path}"]
    return HostResult(bastion, ok, lines, output)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Git-pull the showroom repo on each bastion and run setup/lab-environment.sh."
    )
    add_connection_args(parser)
    parser.add_argument("--repo-url", default=DEFAULT_REPO_URL, help="Git URL cloned when the checkout is missing")
    parser.add_argument(
        "--timeout",
        type=int,
        default=3600,
        help="Seconds to wait for each bastion (default 3600)",
    )
    parser.add_argument("--results", default=str(DEFAULT_RESULTS), help="Aggregate log path")
    args = parser.parse_args(argv)

    if args.workers < 1:
        parser.error("--workers must be at least 1")
    if args.timeout < 1:
        parser.error("--timeout must be at least 1")

    bastions = bastions_from_args(args)
    ensure_paramiko()

    def worker(bastion: Bastion) -> HostResult:
        return configure_one(bastion, args.repo_url, args.timeout)

    results = execute_all(bastions, worker, args.workers)
    ok_count = sum(1 for result in results if result.ok)
    failed = [result.bastion.guid or result.bastion.hostname for result in results if not result.ok]
    summary = f"Summary: {ok_count}/{len(results)} configured"
    if failed:
        summary += " (failed: " + ", ".join(failed) + ")"
    print(summary)
    append_results(Path(args.results), "configure-environments", results)
    with open(args.results, "a", encoding="utf-8") as handle:
        handle.write(summary + "\n")
    print(f"Wrote aggregate results to {args.results}")
    return 0 if ok_count == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
