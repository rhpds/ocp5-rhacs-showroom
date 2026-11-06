#!/usr/bin/env python3
"""Restart the Showroom pod on each bastion so it reclones the lab guide."""

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
ROLLOUT_TIMEOUT = "300s"

# The catalog deploys showroom-single-pod. git-cloner runs on every start,
# so a rollout restart pulls GIT_REPO_REF again. On these clusters the
# namespace is showroom-<guid>-1 (also accept showroom-<guid> and other suffixes).
REFRESH_SCRIPT = r"""
set -u
GUID="${1:-}"
NS_OVERRIDE="${2:-}"
DEPLOY_OVERRIDE="${3:-}"

export PATH="${HOME}/.local/bin:${HOME}/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
if [[ -z "${KUBECONFIG:-}" && -f "${HOME}/.kube/config" ]]; then
  export KUBECONFIG="${HOME}/.kube/config"
fi

if ! command -v oc >/dev/null 2>&1; then
  echo "ERROR: oc not found on PATH"
  exit 1
fi
if ! oc whoami >/dev/null 2>&1; then
  echo "ERROR: oc is not logged in: $(oc whoami 2>&1 || true)"
  exit 1
fi

declare -a TARGETS=()

add_target() {
  local ns="$1"
  local deploy="$2"
  local existing
  if [[ ${#TARGETS[@]} -gt 0 ]]; then
    for existing in "${TARGETS[@]}"; do
      [[ "$existing" == "${ns} ${deploy}" ]] && return 0
    done
  fi
  if oc -n "$ns" get "deploy/${deploy}" >/dev/null 2>&1; then
    TARGETS+=("${ns} ${deploy}")
    return 0
  fi
  return 1
}

# Deployment objects are unlabeled. The pods carry app.kubernetes.io/name=showroom.
collect_from_pods() {
  local only_ns="${1:-}"
  local ns_flag=(-A)
  if [[ -n "$only_ns" ]]; then
    ns_flag=(-n "$only_ns")
  fi
  local ns
  while read -r ns; do
    [[ -z "${ns:-}" ]] && continue
    add_target "$ns" "${DEPLOY_OVERRIDE:-showroom}" || true
  done < <(oc "${ns_flag[@]}" get pods -l app.kubernetes.io/name=showroom \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null || true)
}

collect_from_guid() {
  local guid="$1"
  local ns
  while read -r ns; do
    [[ -z "${ns:-}" ]] && continue
    case "$ns" in
      "showroom-${guid}"|"showroom-${guid}"-*)
        add_target "$ns" "${DEPLOY_OVERRIDE:-showroom}" || true
        ;;
    esac
  done < <(oc get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
}

if [[ -n "$NS_OVERRIDE" && -n "$DEPLOY_OVERRIDE" ]]; then
  add_target "$NS_OVERRIDE" "$DEPLOY_OVERRIDE" || {
    echo "ERROR: deployment ${DEPLOY_OVERRIDE} not found in namespace ${NS_OVERRIDE}"
    exit 1
  }
elif [[ -n "$NS_OVERRIDE" ]]; then
  add_target "$NS_OVERRIDE" "${DEPLOY_OVERRIDE:-showroom}" || true
  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    collect_from_pods "$NS_OVERRIDE"
  fi
  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "ERROR: no showroom deployment in namespace ${NS_OVERRIDE}"
    exit 1
  fi
else
  if [[ -n "$GUID" ]]; then
    collect_from_guid "$GUID"
  fi
  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "No showroom deployment in a showroom-${GUID:-*} namespace; searching pods labeled app.kubernetes.io/name=showroom"
    collect_from_pods
  fi
  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "ERROR: no showroom deployment found"
    exit 1
  fi
fi

fail=0
for target in "${TARGETS[@]}"; do
  ns="${target%% *}"
  deploy="${target##* }"
  echo "NAMESPACE=${ns}"
  echo "DEPLOYMENT=${deploy}"
  if ! oc -n "$ns" rollout restart "deploy/${deploy}"; then
    echo "ERROR: rollout restart failed for ${ns}/${deploy}"
    fail=1
    continue
  fi
  if ! oc -n "$ns" rollout status "deploy/${deploy}" --timeout=__ROLLOUT_TIMEOUT__; then
    echo "ERROR: rollout did not become ready for ${ns}/${deploy}"
    fail=1
    continue
  fi
  ready="$(oc -n "$ns" get "deploy/${deploy}" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || true)"
  echo "READY=${ready:-unknown}"
  sel="$(oc -n "$ns" get "deploy/${deploy}" -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null || true)"
  sel="${sel%,}"
  if [[ -n "$sel" ]]; then
    oc -n "$ns" get pods -l "$sel" \
      -o jsonpath='{range .items[*]}POD={.metadata.name} ready={.status.conditions[?(@.type=="Ready")].status} phase={.status.phase}{"\n"}{end}' \
      2>/dev/null || true
  fi
  ref="$(oc -n "$ns" get "deploy/${deploy}" -o jsonpath='{range .spec.template.spec.initContainers[?(@.name=="git-cloner")].env[?(@.name=="GIT_REPO_REF")]}{.value}{end}' 2>/dev/null || true)"
  echo "GIT_REPO_REF=${ref:-(not set)}"
done

if [[ "$fail" -ne 0 ]]; then
  echo "STATUS: failed"
  exit 1
fi
echo "STATUS: refreshed"
exit 0
""".replace("__ROLLOUT_TIMEOUT__", ROLLOUT_TIMEOUT)


def refresh_one(bastion: Bastion, namespace: str, deployment: str, timeout: int) -> HostResult:
    rc, output = run_remote(
        bastion,
        REFRESH_SCRIPT,
        [bastion.guid, namespace, deployment],
        timeout=timeout,
    )
    output = redact(output, bastion.password)
    log_path = write_host_log(DEFAULT_LOG_DIR, bastion, output)
    lines = [header(bastion), *output.splitlines(), f"Local log: {log_path}"]
    return HostResult(bastion, rc == 0, lines, output)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Restart Showroom on each bastion so the lab guide reclones its configured git ref."
    )
    add_connection_args(parser)
    parser.add_argument("--namespace", default="", help="Override the showroom namespace")
    parser.add_argument("--deployment", default="", help="Override the deployment name (requires --namespace)")
    parser.add_argument(
        "--timeout",
        type=int,
        default=420,
        help="Seconds to wait for each bastion, including the rollout (default 420)",
    )
    parser.add_argument("--results", default=str(DEFAULT_RESULTS), help="Aggregate log path")
    args = parser.parse_args(argv)

    if args.deployment and not args.namespace:
        parser.error("--deployment requires --namespace")
    if args.workers < 1:
        parser.error("--workers must be at least 1")
    if args.timeout < 1:
        parser.error("--timeout must be at least 1")

    bastions = bastions_from_args(args)
    ensure_paramiko()

    def worker(bastion: Bastion) -> HostResult:
        return refresh_one(bastion, args.namespace, args.deployment, args.timeout)

    results = execute_all(bastions, worker, args.workers)
    ok_count = sum(1 for result in results if result.ok)
    failed = [result.bastion.guid or result.bastion.hostname for result in results if not result.ok]
    summary = f"Summary: {ok_count}/{len(results)} refreshed"
    if failed:
        summary += " (failed: " + ", ".join(failed) + ")"
    print(summary)
    append_results(Path(args.results), "refresh-showroom", results)
    with open(args.results, "a", encoding="utf-8") as handle:
        handle.write(summary + "\n")
    print(f"Wrote aggregate results to {args.results}")
    return 0 if ok_count == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
