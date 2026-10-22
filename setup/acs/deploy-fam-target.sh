#!/usr/bin/env bash
# Deploy the File Activity Monitoring target used by the ACS roadshow exercise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

oc apply -f "${ROOT}/fam-target.yaml"
oc rollout status deployment/fam-target -n acs-fam-demo --timeout=180s
oc get deploy,pods -n acs-fam-demo
