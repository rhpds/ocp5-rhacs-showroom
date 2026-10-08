#!/usr/bin/env bash
# Provision the ACS roadshow lab environment on the bastion host.
# Quay, MinIO, workshop images, and the Central Quay integration are applied
# by OpenShift GitOps. This script stores the shared Lightspeed token, reads
# Quay and RHACS credentials into the shell, and installs TSSC CLIs.
# Cluster-wide RHACS/Compliance/demo-app deploy is owned by OpenShift GitOps
# (roadshow-prereqs + roadshow-demo-apps).
#
# Quiet by default (progress bar + current step). Use --verbose for full logs.
#
# Usage:
#   bash setup/lab-environment.sh
#
# Quay admin credentials are read from the quay-admin-password secret.
# Optional --quay-user / --quay-password are ignored; GitOps owns that account.
#
# After making the frontend repository public in Quay UI:
#   bash setup/lab-environment.sh --deploy-skupper-only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/rhacs/lib/progress.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/rhacs/lib/common.sh"

QUAY_USER=""
QUAY_PASSWORD=""
DEPLOY_SKUPPER_ONLY=false
SKIP_DEMO_APPS=false
SKIP_DEMO_APPLY=true
SKIP_IMAGES=false
SKIP_RHACS_CONFIGURE=true
VERBOSE=false
WORK_DIR="${HOME}"

DEMO_APPS_REPO="${DEMO_APPS_REPO:-https://github.com/mfosterrox/demo-apps.git}"
SKUPPER_REPO="${SKUPPER_REPO:-https://github.com/mfosterrox/skupper-security-demo.git}"
ROADSHOW_ENV_FILE="${HOME}/.acs-roadshow/env"
# Pin Alpine minor so Clair can match apk CVEs. Floating python:3.12-alpine tracks
# current Alpine (3.24.1 today); catalog Clair indexes it but leaves version_id
# empty, so Quay's Security Scan column shows Passed / namespace "".
PYTHON_ALPINE_BASE="${PYTHON_ALPINE_BASE:-docker.io/library/python:3.12-alpine3.20}"
# quay.io/minio/minio rejects anonymous pulls. quay.io/thanos/minio keeps the
# original RELEASE.2025-09-07T16-13-09Z image (there is no "latest" tag).
# Same entrypoint and /usr/bin/minio as the image Quay was already running.
# Override with MINIO_REPLACEMENT_IMAGE.
MINIO_REPLACEMENT_IMAGE="${MINIO_REPLACEMENT_IMAGE:-quay.io/thanos/minio:RELEASE.2025-09-07T16-13-09Z}"
# TSSC CLIs: same registry.redhat.io pins as Lightwell Showroom (no github.com).
COSIGN_IMAGE="${COSIGN_IMAGE:-registry.redhat.io/rhtas/cosign-rhel9:1.3.0}"
OC_MIRROR_IMAGE="${OC_MIRROR_IMAGE:-registry.redhat.io/openshift4/oc-mirror-plugin-rhel9:v4.20}"
EC_IMAGE="${EC_IMAGE:-registry.redhat.io/rhtas/ec-rhel9:0.7}"
INSTALL_TSSC_CLIS_ONLY=false

# Persist lab vars to a dedicated env file (safe to source from scripts) and ~/.bashrc
# (for interactive shells). Never source ~/.bashrc from this script — bastion images
# often call `exit` for non-interactive shells, which aborts setup mid-run.
persist_var() {
  local name=$1
  local value=$2
  mkdir -p "$(dirname "${ROADSHOW_ENV_FILE}")"
  touch "${ROADSHOW_ENV_FILE}" "${HOME}/.bashrc"
  if grep -q "^export ${name}=" "${ROADSHOW_ENV_FILE}" 2>/dev/null; then
    sed -i "/^export ${name}=/d" "${ROADSHOW_ENV_FILE}"
  fi
  if grep -q "^export ${name}=" "${HOME}/.bashrc" 2>/dev/null; then
    sed -i "/^export ${name}=/d" "${HOME}/.bashrc"
  fi
  printf 'export %s=%q\n' "${name}" "${value}" >> "${ROADSHOW_ENV_FILE}"
  printf 'export %s=%q\n' "${name}" "${value}" >> "${HOME}/.bashrc"
  # shellcheck disable=SC2163
  export "${name}=${value}"
}

load_roadshow_env() {
  if [[ -f "${ROADSHOW_ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ROADSHOW_ENV_FILE}"
    return 0
  fi
  # Fallback: pull only known exports from ~/.bashrc without executing the full file
  if [[ -f "${HOME}/.bashrc" ]]; then
    local line
    while IFS= read -r line || [[ -n "${line}" ]]; do
      case "${line}" in
        export\ ROX_*|export\ QUAY_*|export\ TUTORIAL_HOME=*|export\ APP_HOME=*|export\ RHACS_NAMESPACE=*|export\ GRPC_ENFORCE_ALPN_ENABLED=*)
          # shellcheck disable=SC2163
          eval "${line}"
          ;;
      esac
    done < "${HOME}/.bashrc"
  fi
}

usage() {
  cat <<'EOF'
Usage: lab-environment.sh [options]

Options:
  --quay-user USER          Ignored. Quay admin comes from the GitOps secret
  --quay-password PASS      Ignored. Quay admin comes from the GitOps secret
  --deploy-skupper-only     Deploy patient-portal after frontend repo is public in Quay
  --install-tssc-clis-only  Install cosign, oc-mirror, and ec into ~/.local/bin, then exit
  --skip-demo-apps          Skip cloning the demo-apps repository
  --apply-demo-apps         oc apply demo-apps manifests (GitOps deploys these by default)
  --skip-images             Skip golden image and frontend build/push
  --rhacs-configure         Run setup/rhacs-configure.sh (GitOps owns this by default)
  --skip-rhacs-configure    Deprecated; configure is skipped unless --rhacs-configure
  --verbose                 Stream detailed command output
  --work-dir DIR            Base directory for clones (default: $HOME)
  -h, --help                Show this help

Environment:
  MINIO_REPLACEMENT_IMAGE   Public image used when Quay's MinIO pod cannot pull
                            quay.io/minio/minio. Default:
                            quay.io/thanos/minio:RELEASE.2025-09-07T16-13-09Z
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quay-user) QUAY_USER=$2; shift 2 ;;
    --quay-password) QUAY_PASSWORD=$2; shift 2 ;;
    --deploy-skupper-only) DEPLOY_SKUPPER_ONLY=true; shift ;;
    --install-tssc-clis-only) INSTALL_TSSC_CLIS_ONLY=true; shift ;;
    --skip-demo-apps) SKIP_DEMO_APPS=true; shift ;;
    --apply-demo-apps) SKIP_DEMO_APPLY=false; shift ;;
    --skip-images) SKIP_IMAGES=true; shift ;;
    --rhacs-configure) SKIP_RHACS_CONFIGURE=false; shift ;;
    --skip-rhacs-configure) SKIP_RHACS_CONFIGURE=true; shift ;;
    --verbose|-v) VERBOSE=true; shift ;;
    --work-dir) WORK_DIR=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

PROGRESS_VERBOSE="${VERBOSE}"

deploy_skupper() {
  echo "Deploying patient-portal application (Skupper demo)..."
  cd "${WORK_DIR}"
  if [[ ! -d skupper-app ]]; then
    git clone "${SKUPPER_REPO}" skupper-app
  fi
  persist_var APP_HOME "${WORK_DIR}/skupper-app"

  if [[ -z "${QUAY_URL:-}" || -z "${QUAY_USER:-}" ]]; then
    load_roadshow_env
  fi

  sed -i "s|quay.io/mfoster/patient-portal-frontend:1.0|${QUAY_URL}/${QUAY_USER}/frontend:0.1|g" \
    "${APP_HOME}/skupper-demo/frontend.yml"

  oc apply -f "${APP_HOME}/skupper-demo/"
  oc get pods -n patient-portal
  echo ""
  echo "Patient portal deployed. Frontend image: ${QUAY_URL}/${QUAY_USER}/frontend:0.1"
}

ensure_lab_local_bin() {
  local dest="${HOME}/.local/bin"
  mkdir -p "${dest}"
  export PATH="${dest}:${PATH}"
  if ! grep -qE '(^|:)\$HOME/\.local/bin|^export PATH="\$HOME/\.local/bin' "${HOME}/.bashrc" 2>/dev/null; then
    printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "${HOME}/.bashrc"
  fi
}

# Copy a named binary out of a registry.redhat.io image (same method as Lightwell Showroom).
install_cli_from_rh_image() {
  local name="$1"
  local image="$2"
  local dest="${HOME}/.local/bin/${name}"
  local work pull src found="" outdir
  ensure_lab_local_bin
  if command -v "${name}" >/dev/null 2>&1; then
    local existing
    existing="$(command -v "${name}")"
    if [[ -f "${existing}" && "$(head -c 4 "${existing}")" == $'\x7fELF' ]]; then
      echo "${name} already on PATH (${existing})"
      return 0
    fi
  fi
  echo "Installing ${name} from ${image}"
  work="$(mktemp -d)"
  pull="${work}/.dockerconfigjson"
  if ! oc -n openshift-config extract secret/pull-secret --keys=.dockerconfigjson --to="${work}" --confirm >/dev/null; then
    echo "Error: could not read openshift-config/pull-secret (needed to pull ${image})." >&2
    rm -rf "${work}"
    return 1
  fi
  for src in "/usr/bin/${name}" "/usr/local/bin/${name}"; do
    outdir="${work}/out"
    rm -rf "${outdir}"
    mkdir -p "${outdir}"
    if oc image extract "${image}" \
      --registry-config="${pull}" \
      --filter-by-os linux/amd64 \
      --path "${src}:${outdir}" \
      --confirm \
      || oc image extract "${image}" \
        --registry-config="${pull}" \
        --path "${src}:${outdir}" \
        --confirm; then
      found="$(find "${outdir}" -type f -name "${name}" -print -quit 2>/dev/null || true)"
      if [[ -n "${found}" && "$(head -c 4 "${found}")" == $'\x7fELF' ]]; then
        chmod 0755 "${found}"
        mv "${found}" "${dest}"
        rm -rf "${work}"
        hash -r 2>/dev/null || true
        echo "Installed ${name} -> ${dest}"
        return 0
      fi
    fi
  done
  echo "Falling back to a cluster pod to copy ${name} from ${image}"
  local ns="${TSSC_CLI_EXTRACT_NS:-default}"
  local pod="roadshow-extract-${name}"
  oc -n "${ns}" delete pod "${pod}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  if ! oc -n "${ns}" run "${pod}" \
    --image="${image}" \
    --restart=Never \
    --image-pull-policy=IfNotPresent \
    --command -- /bin/sh -c 'sleep 300'; then
    echo "Error: could not start extract pod for ${name}." >&2
    rm -rf "${work}"
    return 1
  fi
  if ! oc -n "${ns}" wait --for=condition=Ready "pod/${pod}" --timeout=180s; then
    oc -n "${ns}" describe "pod/${pod}" >&2 || true
    oc -n "${ns}" delete pod "${pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    rm -rf "${work}"
    return 1
  fi
  src="$(oc -n "${ns}" exec "${pod}" -- /bin/sh -c \
    "for c in /usr/bin/${name} /usr/local/bin/${name}; do if [ -x \"\$c\" ]; then echo \$c; exit 0; fi; done; command -v ${name}")" || true
  if [[ -z "${src}" ]]; then
    oc -n "${ns}" delete pod "${pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    echo "Error: ${name} not found inside ${image}." >&2
    rm -rf "${work}"
    return 1
  fi
  oc -n "${ns}" cp "${pod}:${src}" "${dest}"
  oc -n "${ns}" delete pod "${pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  chmod 0755 "${dest}"
  rm -rf "${work}"
  if [[ "$(head -c 4 "${dest}")" != $'\x7fELF' ]]; then
    echo "Error: extracted ${dest} is not an ELF binary." >&2
    return 1
  fi
  hash -r 2>/dev/null || true
  echo "Installed ${name} -> ${dest}"
}

ensure_tssc_clis() {
  ensure_lab_local_bin
  install_cli_from_rh_image cosign "${COSIGN_IMAGE}" || return 1
  install_cli_from_rh_image oc-mirror "${OC_MIRROR_IMAGE}" || return 1
  install_cli_from_rh_image ec "${EC_IMAGE}" || return 1
  echo "TSSC CLIs on PATH:"
  command -v cosign
  command -v oc-mirror
  command -v ec
  cosign version || true
  oc-mirror version || true
  ec version || ec --version || true
  echo "If command -v still prints nothing in this SSH session, run: source ~/.bashrc"
}

do_tssc_clis() {
  ensure_tssc_clis
}

if [[ "${DEPLOY_SKUPPER_ONLY}" == true ]]; then
  deploy_skupper
  exit 0
fi

if [[ "${INSTALL_TSSC_CLIS_ONLY}" == true ]]; then
  ensure_tssc_clis
  exit 0
fi

# Quay, workshop images, and the Central registry integration come from GitOps.
# This script only writes the shared Lightspeed token, local CLI env, and TSSC binaries.
load_roadshow_env

# Count top-level lab steps.
TOTAL=0
TOTAL=$((TOTAL + 6)) # admin + lightspeed token + quay env + tssc clis + CLI vars + verify API
[[ "${SKIP_RHACS_CONFIGURE}" != true ]] && TOTAL=$((TOTAL + 1))
[[ "${SKIP_DEMO_APPS}" != true ]] && TOTAL=$((TOTAL + 1)) # clone
[[ "${SKIP_DEMO_APPS}" != true && "${SKIP_DEMO_APPLY}" != true ]] && TOTAL=$((TOTAL + 1)) # apply

LOG_DIR="${HOME}/.acs-roadshow"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/lab-environment-$(date +%Y%m%d-%H%M%S).log"
progress_init "${TOTAL}" "${LOG_FILE}" "Lab environment setup"

# Ask for the shared Lightspeed token and store it in the secrets Argo already ignores.
# progress_run sends this function's stdout and stderr to the log, so the prompt
# has to use the terminal directly. An empty answer skips Lightspeed and continues.
configure_lightspeed_token() {
  local ns="openshift-lightspeed"
  local token="${LIGHTSPEED_API_TOKEN:-}"
  local url="${LIGHTSPEED_API_URL:-}"
  local provider="${LIGHTSPEED_PROVIDER:-openai}"
  local model="${LIGHTSPEED_MODEL:-}"
  LIGHTSPEED_TOKEN_SAVED=false
  if [[ -z "${token}" && -r /dev/tty && -w /dev/tty ]]; then
    printf '\n%s' "Paste the shared Lightspeed API token (press Enter to skip): " >/dev/tty
    IFS= read -r -s token </dev/tty || token=""
    printf '\n' >/dev/tty
  fi
  if [[ -z "${token}" ]]; then
    echo "No Lightspeed API token provided. Continuing." >/dev/tty
    echo "No Lightspeed API token provided. Continuing."
    return 0
  fi
  if ! oc get namespace "${ns}" >/dev/null 2>&1; then
    echo "Error: namespace ${ns} is missing. Wait for the OpenShift Lightspeed GitOps application." >&2
    return 1
  fi
  if [[ -z "${url}" ]]; then
    url="$(oc -n "${ns}" get olsconfig cluster -o jsonpath='{.spec.llm.providers[0].url}' 2>/dev/null || true)"
  fi
  if [[ -z "${url}" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Lightspeed API URL (Azure or other OpenAI-compatible endpoint): " url
    fi
  fi
  if [[ -z "${url}" ]]; then
    echo "Error: Lightspeed API URL is unset. Set llm.apiUrl in GitOps or LIGHTSPEED_API_URL." >&2
    return 1
  fi
  oc -n "${ns}" create secret generic llm-credentials \
    --from-literal=apitoken="${token}" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc -n "${ns}" create secret generic llm-creds-openai \
    --from-literal=OPENAI_API_KEY="${token}" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  LIGHTSPEED_TOKEN_SAVED=true
  echo "Lightspeed token stored in ${ns}"
  if oc -n "${ns}" get olsconfig cluster >/dev/null 2>&1; then
    oc -n "${ns}" patch olsconfig cluster --type=json \
      -p "[{\"op\":\"add\",\"path\":\"/spec/llm/providers/0/url\",\"value\":\"${url}\"}]" >/dev/null
  else
    if [[ -z "${model}" && -t 0 ]]; then
      read -r -p "Lightspeed model name: " model
    fi
    if [[ -z "${model}" ]]; then
      echo "Error: OLSConfig is missing and LIGHTSPEED_MODEL is unset." >&2
      return 1
    fi
    local azure=""
    if [[ "${provider}" == "azure_openai" ]]; then
      local deployment="${LIGHTSPEED_AZURE_DEPLOYMENT:-}"
      local api_version="${LIGHTSPEED_AZURE_API_VERSION:-}"
      if [[ -z "${deployment}" && -t 0 ]]; then
        read -r -p "Azure OpenAI deployment name: " deployment
      fi
      if [[ -z "${api_version}" && -t 0 ]]; then
        read -r -p "Azure OpenAI API version: " api_version
      fi
      if [[ -z "${deployment}" || -z "${api_version}" ]]; then
        echo "Error: azure_openai needs LIGHTSPEED_AZURE_DEPLOYMENT and LIGHTSPEED_AZURE_API_VERSION." >&2
        return 1
      fi
      azure="$(printf '        deploymentName: %s\n        apiVersion: %s\n' "${deployment}" "${api_version}")"
    fi
    oc apply -f - >/dev/null <<EOF
apiVersion: ols.openshift.io/v1alpha1
kind: OLSConfig
metadata:
  name: cluster
  namespace: ${ns}
spec:
  featureGates:
    - MCPServer
  llm:
    providers:
      - credentialsSecretRef:
          name: llm-credentials
        models:
          - name: ${model}
        name: ${provider}
        type: ${provider}
        url: ${url}
${azure}  ols:
    defaultModel: ${model}
    defaultProvider: ${provider}
EOF
  fi
  if oc -n "${ns}" get llmprovider openai >/dev/null 2>&1; then
    oc -n "${ns}" patch llmprovider openai --type=merge \
      -p "{\"spec\":{\"openAI\":{\"url\":\"${url}\"}}}" >/dev/null || true
  fi
}

# Read the Quay admin account GitOps already created. Do not generate another password.
load_quay_env() {
  local ns="quay"
  if ! oc -n "${ns}" get secret quay-admin-password >/dev/null 2>&1; then
    echo "Error: secret ${ns}/quay-admin-password is missing. Wait for the Quay GitOps application." >&2
    return 1
  fi
  QUAY_USER="$(oc -n "${ns}" get secret quay-admin-password -o jsonpath='{.data.username}' | base64 -d)"
  QUAY_PASSWORD="$(oc -n "${ns}" get secret quay-admin-password -o jsonpath='{.data.password}' | base64 -d)"
  QUAY_URL="$(detect_quay_url)" || {
    echo "Error: could not find a Quay route in ${ns}." >&2
    return 1
  }
  persist_var QUAY_USER "${QUAY_USER}"
  persist_var QUAY_PASSWORD "${QUAY_PASSWORD}"
  persist_var QUAY_URL "${QUAY_URL}"
  echo "Using Quay at ${QUAY_URL}"
}

do_verify_admin() {
  oc config use-context admin 2>/dev/null || oc config use-context "$(oc config get-contexts -o name | head -1)"
  oc whoami
  oc get nodes --no-headers | head -5
}

do_wait_central() {
  local ns
  for ns in rhacs-operator stackrox; do
    if oc -n "${ns}" get route central >/dev/null 2>&1 || oc -n "${ns}" get route central-reencrypt >/dev/null 2>&1; then
      oc -n "${ns}" wait --for=condition=available --timeout=300s deployment/central 2>/dev/null \
        || echo "NOTE: Central deployment not yet Available in ${ns}; continuing with route lookup."
      return 0
    fi
  done
  echo "Error: RHACS Central route not found (tried namespaces rhacs-operator, stackrox)." >&2
  echo "Ensure the GitOps rhacs-operator Application has synced." >&2
  return 1
}

# Pods cannot open the apps load-balancer address. After Quay is up, point its
# route hostname at the in-cluster router so Central and Scanner can pull from it.
map_quay_route_for_central() {
  local quay_host router_ip ns central_cr patch deploy
  quay_host="$(detect_quay_url)" || {
    echo "Error: Quay route not found; cannot map it for Central." >&2
    return 1
  }
  router_ip="$(oc -n openshift-ingress get svc router-internal-default -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  if [[ -z "${router_ip}" ]]; then
    echo "Error: Service openshift-ingress/router-internal-default has no cluster IP." >&2
    return 1
  fi
  ns="$(detect_rhacs_namespace)" || {
    echo "Error: Central deployment not found (tried rhacs-operator, stackrox)." >&2
    return 1
  }
  central_cr="$(oc -n "${ns}" get central -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${central_cr}" ]]; then
    echo "Error: Central custom resource not found in ${ns}." >&2
    return 1
  fi
  if QUAY_HOST="${quay_host}" ROUTER_IP="${router_ip}" \
    oc -n "${ns}" get central "${central_cr}" -o json | python3 -c '
import json, os, sys
host = os.environ["QUAY_HOST"]
ip = os.environ["ROUTER_IP"]
spec = json.load(sys.stdin).get("spec") or {}
checks = [
    ((spec.get("central") or {}).get("hostAliases") or []),
    (((spec.get("scanner") or {}).get("analyzer") or {}).get("hostAliases") or []),
    (((spec.get("scannerV4") or {}).get("indexer") or {}).get("hostAliases") or []),
]
def has_alias(aliases):
    return any(a.get("ip") == ip and host in (a.get("hostnames") or []) for a in aliases)
sys.exit(0 if all(has_alias(group) for group in checks) else 1)
'; then
    echo "Quay route ${quay_host} already maps to router ${router_ip}"
    return 0
  fi
  patch="$(QUAY_HOST="${quay_host}" ROUTER_IP="${router_ip}" python3 -c '
import json, os
alias = {"ip": os.environ["ROUTER_IP"], "hostnames": [os.environ["QUAY_HOST"]]}
print(json.dumps({"spec": {
    "central": {"hostAliases": [alias]},
    "scanner": {"analyzer": {"hostAliases": [alias]}},
    "scannerV4": {"indexer": {"hostAliases": [alias]}},
}}))
')"
  echo "Mapping ${quay_host} to router ${router_ip}"
  oc -n "${ns}" patch central "${central_cr}" --type=merge -p "${patch}"
  for deploy in central scanner scanner-v4-indexer; do
    if oc -n "${ns}" get "deploy/${deploy}" >/dev/null 2>&1; then
      oc -n "${ns}" rollout status "deploy/${deploy}" --timeout=300s
    fi
  done
}

do_cli_vars() {
  load_roadshow_env
  # Reencrypt Central routes do not offer ALPN; roxctl from grpc-go >= 1.67 fails without this.
  persist_var GRPC_ENFORCE_ALPN_ENABLED false
  resolve_rox_central_address || return 1
  persist_var ROX_CENTRAL_ADDRESS "${ROX_CENTRAL_ADDRESS}"
  persist_var RHACS_NAMESPACE "${RHACS_NAMESPACE}"

  if [[ -z "${ROX_PASSWORD:-}" ]]; then
    ROX_PASSWORD="$(rox_admin_password "${RHACS_NAMESPACE}" || true)"
  fi
  if [[ -n "${ROX_PASSWORD:-}" ]]; then
    persist_var ROX_PASSWORD "${ROX_PASSWORD}"
  fi

  ensure_rox_api_token || return 1
  persist_var ROX_API_TOKEN "${ROX_API_TOKEN}"
}

ensure_roxctl() {
  if command -v roxctl >/dev/null 2>&1; then
    return 0
  fi
  local host dest tmp url
  host="$(rox_central_host "${ROX_CENTRAL_ADDRESS:-}")"
  if [[ -z "${host}" ]]; then
    echo "Error: ROX_CENTRAL_ADDRESS is unset; cannot download roxctl." >&2
    return 1
  fi
  ensure_lab_local_bin
  dest="${HOME}/.local/bin"
  tmp="$(mktemp)"
  echo "roxctl not found; downloading CLI from Central..."
  # Central's download API requires auth (anonymous → 401).
  for url in \
    "https://${host}/api/cli/download/roxctl-linux-amd64" \
    "https://${host}/api/cli/download/roxctl-linux"; do
    if [[ -n "${ROX_API_TOKEN:-}" ]] \
      && curl -fsSk -L -H "Authorization: Bearer ${ROX_API_TOKEN}" -o "${tmp}" "${url}"; then
      break
    fi
    if [[ -n "${ROX_PASSWORD:-}" ]] \
      && curl -fsSk -L -u "admin:${ROX_PASSWORD}" -o "${tmp}" "${url}"; then
      break
    fi
    : > "${tmp}"
  done
  if [[ ! -s "${tmp}" ]] || [[ "$(head -c 4 "${tmp}")" != $'\x7fELF' ]]; then
    rm -f "${tmp}"
    echo "Error: could not download roxctl from https://${host}/api/cli/download/ (need API token or admin password)." >&2
    return 1
  fi
  chmod +x "${tmp}"
  mv "${tmp}" "${dest}/roxctl"
  hash -r 2>/dev/null || true
  command -v roxctl >/dev/null 2>&1
}

do_verify_api() {
  ensure_roxctl || return 1
  roxctl --insecure-skip-tls-verify -e "${ROX_CENTRAL_ADDRESS}:443" central whoami
  curl -ksS -H "Authorization: Bearer ${ROX_API_TOKEN}" \
    "https://${ROX_CENTRAL_ADDRESS}/v1/auth/status" | jq -r '.userId // .user // "ok"' >/dev/null
}

do_clone_demo_apps() {
  cd "${WORK_DIR}"
  if [[ ! -d demo-apps ]]; then
    git clone "${DEMO_APPS_REPO}" demo-apps
  else
    git -C demo-apps pull --ff-only 2>/dev/null || true
  fi
  persist_var TUTORIAL_HOME "${WORK_DIR}/demo-apps"
  if [[ ! -d "${TUTORIAL_HOME}/kubernetes-manifests" ]]; then
    echo "Error: ${TUTORIAL_HOME}/kubernetes-manifests not found." >&2
    return 1
  fi
}

do_apply_demo_apps() {
  load_roadshow_env
  if [[ -z "${TUTORIAL_HOME:-}" ]]; then
    echo "Error: TUTORIAL_HOME is unset; clone demo-apps first." >&2
    return 1
  fi
  oc apply -f "${TUTORIAL_HOME}/kubernetes-manifests/" --recursive
  oc get deployments -l demo=roadshow -A
  total=$(oc get deployments -l demo=roadshow -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${total:-0}" -lt 1 ]]; then
    echo "Error: no deployments with label demo=roadshow were found after apply." >&2
    return 1
  fi
}

# Resolve Quay registry hostname. Showroom clusters commonly use namespace "quay"
# (route quay-quay); some older labs used "quay-enterprise".
detect_quay_url() {
  local ns route host
  for ns in quay quay-enterprise; do
    for route in registry-quay quay-quay quay; do
      host="$(oc -n "${ns}" get route "${route}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
      if [[ -n "${host}" ]]; then
        echo "${host}"
        return 0
      fi
    done
  done
  # Last resort: any route whose name/host contains "quay"
  host="$(oc get routes -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.host}{"\n"}{end}' 2>/dev/null \
    | awk -F'\t' 'tolower($2) ~ /quay/ || tolower($3) ~ /quay/ { print $3; exit }')"
  if [[ -n "${host}" ]]; then
    echo "${host}"
    return 0
  fi
  return 1
}

# Labs expect podman; install it when missing (common on minimal bastions).
ensure_podman() {
  if command -v podman >/dev/null 2>&1; then
    return 0
  fi
  echo "podman not found; attempting install..."
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y podman
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y podman
  else
    echo "Error: podman is required but could not be installed (no dnf/yum)." >&2
    return 1
  fi
  command -v podman >/dev/null 2>&1
}

wait_for_quay() {
  local url="$1"
  local code="" i
  echo "Waiting for Quay registry at ${url}..."
  for i in $(seq 1 90); do
    code="$(curl -sk -o /dev/null -w '%{http_code}' "https://${url}/v2/" || true)"
    if [[ "${code}" == "401" || "${code}" == "200" ]]; then
      echo "Quay is ready (HTTP ${code})"
      return 0
    fi
    echo "Attempt ${i}/90: HTTP ${code:-000}"
    sleep 10
  done
  echo "Error: Quay at ${url} never became ready (last HTTP ${code:-000})." >&2
  echo "The registry pods are not serving yet. On the bastion run:" >&2
  echo "  oc -n quay get quayregistry registry -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{\"\\n\"}{end}'" >&2
  echo "  oc -n quay get deploy,pods" >&2
  return 1
}

# FEATURE_USER_INITIALIZE creates the first account via this API. The GitOps
# Job often finishes (or fails) before registry-quay-app is Ready, so the
# bastion does it after /v2/ returns 401.
initialize_quay_admin() {
  local url="$1" user="$2" password="$3"
  local email="${user}@example.com" body code
  body="$(
    QUAY_USERNAME="${user}" QUAY_PASSWORD="${password}" QUAY_EMAIL="${email}" \
      python3 -c 'import json,os; print(json.dumps({"username":os.environ["QUAY_USERNAME"],"password":os.environ["QUAY_PASSWORD"],"email":os.environ["QUAY_EMAIL"],"access_token": True}))'
  )"
  echo "Initializing Quay admin user '${user}'..."
  code="$(curl -sk -o /tmp/quay-init.json -w '%{http_code}' \
    -X POST "https://${url}/api/v1/user/initialize" \
    -H "Content-Type: application/json" \
    -d "${body}" || true)"
  echo "Quay initialize HTTP ${code}"
  case "${code}" in
    200|201) echo "Quay admin user created" ;;
    400|409) echo "Quay admin user already exists" ;;
    *) echo "Warning: Quay initialize returned HTTP ${code:-000}" ;;
  esac
}

podman_login_quay() {
  local url="$1" user="$2" password="$3"
  podman login --tls-verify=false "${url}" -u "${user}" -p "${password}"
}

# Hash with the bcrypt library inside the Quay image so the prefix is $2b$,
# which is what Quay stores in public.user.password_hash.
quay_bcrypt_hash() {
  local ns=$1 password=$2 py hash
  py="$(oc -n "${ns}" exec deploy/registry-quay-app -c quay-app -- \
    sh -c 'command -v /quay-registry/venv/bin/python || command -v python3 || command -v python' \
    2>/dev/null | tr -d '\r' || true)"
  if [[ -n "${py}" ]]; then
    hash="$(oc -n "${ns}" exec deploy/registry-quay-app -c quay-app -- \
      env QUAY_PASSWORD="${password}" "${py}" -c \
      'import bcrypt,os; print(bcrypt.hashpw(os.environ["QUAY_PASSWORD"].encode(), bcrypt.gensalt(12)).decode())' \
      2>/dev/null | tr -d '\r' | grep '^\$2' | tail -1 || true)"
  fi
  if [[ -z "${hash}" ]] && command -v htpasswd >/dev/null 2>&1; then
    hash="$(htpasswd -bnBC 12 x "${password}" | cut -d: -f2 | sed 's/^\$2y\$/\$2b\$/')"
  fi
  [[ -n "${hash}" ]] || return 1
  printf '%s' "${hash}"
}

# /api/v1/user/initialize only succeeds once. Later runs must overwrite that
# password so the account matches QUAY_PASSWORD in ~/.bashrc.
reset_quay_admin_password() {
  local user="$1" password="$2"
  local hash out
  hash="$(quay_bcrypt_hash quay "${password}")" || {
    echo "Error: could not generate a bcrypt hash for the Quay admin password." >&2
    return 1
  }
  echo "Setting Quay user '${user}' to the password passed to this script..."
  out="$(oc -n quay exec deploy/registry-quay-database -- env HASH="${hash}" QUAY_USER_NAME="${user}" \
    sh -c 'u=${POSTGRESQL_USER:-${POSTGRES_USER:-quay}}; d=${POSTGRESQL_DATABASE:-${POSTGRES_DB:-quay}}; export PGPASSWORD=${POSTGRESQL_PASSWORD:-$POSTGRES_PASSWORD}; psql -U "$u" -d "$d" -c "UPDATE public.\"user\" SET password_hash = '\''${HASH}'\'' WHERE username = '\''${QUAY_USER_NAME}'\'';"')" \
    || return 1
  if [[ "${out}" != *"UPDATE 1"* ]]; then
    echo "Error: Quay did not update a password row for user '${user}'." >&2
    printf '%s\n' "${out}" | grep -v '\$2' >&2 || true
    return 1
  fi
  echo "Quay admin password updated."
}

do_quay_login() {
  ensure_podman || return 1
  QUAY_URL="$(detect_quay_url)" || {
    echo "Error: could not find a Quay route (tried namespaces quay, quay-enterprise)." >&2
    return 1
  }
  persist_var QUAY_USER "${QUAY_USER}"
  persist_var QUAY_URL "${QUAY_URL}"
  echo "Using Quay at ${QUAY_URL}"
  wait_for_quay "${QUAY_URL}" || return 1
  initialize_quay_admin "${QUAY_URL}" "${QUAY_USER}" "${QUAY_PASSWORD}"
  if podman_login_quay "${QUAY_URL}" "${QUAY_USER}" "${QUAY_PASSWORD}"; then
    persist_var QUAY_PASSWORD "${QUAY_PASSWORD}"
    return 0
  fi
  echo "Login with the supplied password failed. The admin account already exists with a different password."
  reset_quay_admin_password "${QUAY_USER}" "${QUAY_PASSWORD}" || return 1
  if podman_login_quay "${QUAY_URL}" "${QUAY_USER}" "${QUAY_PASSWORD}"; then
    persist_var QUAY_PASSWORD "${QUAY_PASSWORD}"
    return 0
  fi
  echo "Error: podman login to ${QUAY_URL} failed for user '${QUAY_USER}' after resetting the password." >&2
  return 1
}

# Blob upload sometimes returns HTTP 500 while MinIO or Quay is still settling.
# Retry that status only. Auth and other errors stop immediately.
podman_push_retry() {
  local image="$1"
  shift
  local attempt=1 max=3 rc=0 log ns
  while (( attempt <= max )); do
    log="$(mktemp)"
    if podman push "$@" "${image}" >"${log}" 2>&1; then
      cat "${log}"
      rm -f "${log}"
      return 0
    fi
    rc=$?
    cat "${log}"
    if (( attempt == max )) || ! grep -q 'HTTP status: 500' "${log}"; then
      if grep -q 'HTTP status: 500' "${log}"; then
        echo "Quay storage errors from the last 2 minutes:"
        oc -n quay logs deploy/registry-quay-app -c quay-app --since=2m 2>/dev/null \
          | grep -Ei 'storage|s3|bucket|boto|ClientError|NoSuch|exception' \
          | grep -viE 'secret_key|access_key|password' \
          | tail -20 || true
      fi
      rm -f "${log}"
      return "${rc}"
    fi
    rm -f "${log}"
    echo "Push of ${image} returned HTTP 500 (attempt ${attempt}/${max}). Retrying in 15s..."
    ns="$(quay_namespace 2>/dev/null || true)"
    if [[ -n "${ns}" ]]; then
      repair_quay_storage "${ns}" || true
    fi
    sleep 15
    attempt=$((attempt + 1))
  done
  return "${rc}"
}

do_golden_image() {
  ensure_podman || return 1
  podman pull "${PYTHON_ALPINE_BASE}"
  podman tag "${PYTHON_ALPINE_BASE}" "${QUAY_URL}/${QUAY_USER}/python-alpine-golden:0.1"
  podman_push_retry "${QUAY_URL}/${QUAY_USER}/python-alpine-golden:0.1"
}

do_frontend_image() {
  ensure_podman || return 1
  load_roadshow_env
  if [[ -z "${TUTORIAL_HOME:-}" || -z "${QUAY_URL:-}" || -z "${QUAY_USER:-}" ]]; then
    echo "Error: TUTORIAL_HOME / QUAY_URL / QUAY_USER must be set before building the frontend image." >&2
    return 1
  fi
  sed -i "s|^FROM python:3\.12-alpine[^ ]* AS \(\w\+\)|FROM ${QUAY_URL}/${QUAY_USER}/python-alpine-golden:0.1 AS \1|" \
    "${TUTORIAL_HOME}/app-images/frontend/Dockerfile"
  cd "${TUTORIAL_HOME}/app-images/frontend/"
  podman build -t "${QUAY_URL}/${QUAY_USER}/frontend:0.1" .
  podman_push_retry "${QUAY_URL}/${QUAY_USER}/frontend:0.1" --remove-signatures
}

# True when a MinIO workload is still on an image other than the public mirror.
# Covers ImagePullBackOff of quay.io/minio/minio and a running-but-unready
# replacement such as pgsty/minio.
minio_needs_public_image() {
  local ns=$1
  local count
  count="$(oc -n "${ns}" get deploy,sts -o json | jq --arg replacement "${MINIO_REPLACEMENT_IMAGE}" '
    [ .items[]?
      | ((.spec.template.spec.containers // []) + (.spec.template.spec.initContainers // []))[]
      | select(.name == "minio" or ((.image // "") | test("minio/minio|pgsty/minio|/minio:")))
      | select(.image != $replacement)
    ] | length
  ')"
  [[ "${count}" -gt 0 ]]
}

# Namespace that holds the roadshow Quay install.
quay_namespace() {
  local ns
  for ns in quay quay-enterprise; do
    if oc get namespace "${ns}" >/dev/null 2>&1; then
      printf '%s\n' "${ns}"
      return 0
    fi
  done
  return 1
}

# Point MinIO workloads that are not already on the public mirror at that image.
# Returns 0 when at least one workload was updated and became ready.
repoint_minio_image() {
  local ns=$1
  local kind name container image kind_lc workload
  local -a workloads=()
  local seen=" "

  while IFS=$'\t' read -r kind name container image; do
    [[ -z "${kind}" ]] && continue
    echo "Quay MinIO is not using a pullable image (${image})"
    echo "Using public image ${MINIO_REPLACEMENT_IMAGE} for ${kind}/${name} container ${container}"
    kind_lc="$(printf '%s' "${kind}" | tr '[:upper:]' '[:lower:]')"
    oc -n "${ns}" set image "${kind_lc}/${name}" "${container}=${MINIO_REPLACEMENT_IMAGE}" || return 1
    workloads+=("${kind_lc}/${name}")
  done < <(oc -n "${ns}" get deploy,sts -o json | jq -r --arg replacement "${MINIO_REPLACEMENT_IMAGE}" '
    .items[]?
    | .kind as $kind
    | .metadata.name as $name
    | ((.spec.template.spec.containers // []) + (.spec.template.spec.initContainers // []))[]
    | select(.name == "minio" or ((.image // "") | test("minio/minio|pgsty/minio|/minio:")))
    | select(.image != $replacement)
    | [$kind, $name, .name, .image] | @tsv
  ')

  if [[ "${#workloads[@]}" -eq 0 ]]; then
    echo "Error: Quay MinIO is down but no Deployment or StatefulSet container could be retargeted." >&2
    oc -n "${ns}" get pods -o wide >&2 || true
    oc -n "${ns}" logs deploy/minio --tail=40 >&2 || true
    oc -n "${ns}" get events --sort-by='.lastTimestamp' >&2 | tail -n 20 || true
    return 1
  fi

  for workload in "${workloads[@]}"; do
    [[ "${seen}" == *" ${workload} "* ]] && continue
    seen+="${workload} "
    oc -n "${ns}" rollout restart "${workload}" >/dev/null || return 1
    if ! oc -n "${ns}" rollout status "${workload}" --timeout=300s; then
      echo "Error: ${workload} did not become ready with ${MINIO_REPLACEMENT_IMAGE}" >&2
      oc -n "${ns}" get pods -o wide >&2 || true
      oc -n "${ns}" logs "${workload}" --tail=40 >&2 || true
      oc -n "${ns}" get events --sort-by='.lastTimestamp' >&2 | tail -n 20 || true
      return 1
    fi
  done
}

# Same ready signal as wait_for_quay: registry /v2/ returns 200 or 401.
quay_v2_ready() {
  local host code
  host="$(detect_quay_url 2>/dev/null || true)"
  [[ -n "${host}" ]] || return 1
  code="$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 "https://${host}/v2/" || true)"
  [[ "${code}" == "401" || "${code}" == "200" ]]
}

# Read a MinIO credential from the deployment env, including secretKeyRef and envFrom.
minio_credential() {
  local ns=$1 key=$2
  oc -n "${ns}" get deploy minio -o json | python3 -c '
import json, subprocess, sys
ns, key = sys.argv[1], sys.argv[2]
deploy = json.load(sys.stdin)
containers = deploy["spec"]["template"]["spec"].get("containers") or []
container = next((c for c in containers if c.get("name") == "minio"), containers[0] if containers else {})
for env in container.get("env") or []:
    if env.get("name") != key:
        continue
    if env.get("value"):
        print(env["value"].strip())
        sys.exit(0)
    ref = (env.get("valueFrom") or {}).get("secretKeyRef") or {}
    if ref.get("name") and ref.get("key"):
        raw = subprocess.check_output([
            "oc", "-n", ns, "get", "secret", ref["name"],
            "-o", "jsonpath={.data." + ref["key"] + "}",
        ])
        print(subprocess.check_output(["base64", "-d"], input=raw).decode().strip())
        sys.exit(0)
for src in container.get("envFrom") or []:
    name = (src.get("secretRef") or {}).get("name")
    if not name:
        continue
    data = json.loads(subprocess.check_output([
        "oc", "-n", ns, "get", "secret", name, "-o", "json",
    ])).get("data") or {}
    if key in data:
        print(subprocess.check_output(["base64", "-d"], input=data[key].encode()).decode().strip())
        sys.exit(0)
sys.exit(1)
' "${ns}" "${key}"
}

# The thanos MinIO image has no mc client. Create bucket quay with the boto3
# library already in the Quay image, using path-style SigV4.
ensure_minio_bucket() {
  local ns=$1 user=$2 pass=$3 host=$4 port=$5
  local py endpoint
  echo "Ensuring MinIO bucket quay"
  if oc -n "${ns}" exec deploy/minio -- sh -c 'command -v mc >/dev/null 2>&1'; then
    oc -n "${ns}" exec deploy/minio -- env \
      MINIO_USER="${user}" MINIO_PASS="${pass}" MINIO_PORT="${port}" \
      sh -c 'mc alias set local "http://127.0.0.1:${MINIO_PORT}" "$MINIO_USER" "$MINIO_PASS" >/dev/null && mc mb --ignore-existing local/quay'
    return
  fi
  if ! oc -n "${ns}" get deploy registry-quay-app >/dev/null 2>&1; then
    echo "Warning: Quay is not up yet, so bucket quay will be created after the registry starts."
    return 0
  fi
  py="$(oc -n "${ns}" exec deploy/registry-quay-app -c quay-app -- \
    sh -c 'command -v /quay-registry/venv/bin/python || command -v python3 || command -v python' \
    2>/dev/null | tr -d '\r' || true)"
  if [[ -z "${py}" ]]; then
    echo "Error: cannot create MinIO bucket quay (no mc client, and Quay has no Python)." >&2
    return 1
  fi
  endpoint="http://${host}:${port}"
  oc -n "${ns}" exec deploy/registry-quay-app -c quay-app -- \
    env MINIO_USER="${user}" MINIO_PASS="${pass}" MINIO_ENDPOINT="${endpoint}" "${py}" -c '
import os
import boto3
from botocore.client import Config
from botocore.exceptions import ClientError
s3 = boto3.client(
    "s3",
    endpoint_url=os.environ["MINIO_ENDPOINT"],
    aws_access_key_id=os.environ["MINIO_USER"],
    aws_secret_access_key=os.environ["MINIO_PASS"],
    region_name="us-east-1",
    config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
)
try:
    s3.head_bucket(Bucket="quay")
    print("MinIO bucket quay exists")
except ClientError as exc:
    code = str(exc.response.get("Error", {}).get("Code", ""))
    if code not in ("404", "NoSuchBucket", "NotFound"):
        raise
    s3.create_bucket(Bucket="quay")
    print("Created MinIO bucket quay")
'
}

# Quay's config tool defaults signature_version to s3v2, which botocore rejects,
# and a missing region makes the signed MinIO call fail. Either one becomes
# HTTP 500 on blob upload. Omitting DISTRIBUTED_STORAGE_PREFERENCE leaves
# Quay's built-in default of local_us, which is KeyError on blob upload when
# the only configured location is named default. The registry process only
# reads config.yaml at start.
quay_loaded_storage_config() {
  local ns=$1 py
  py="$(oc -n "${ns}" exec deploy/registry-quay-app -c quay-app -- \
    sh -c 'command -v /quay-registry/venv/bin/python || command -v python3 || command -v python' \
    2>/dev/null | tr -d '\r' || true)"
  [[ -n "${py}" ]] || return 1
  oc -n "${ns}" exec deploy/registry-quay-app -c quay-app -- "${py}" -c '
import pathlib, sys
paths = [pathlib.Path("/conf/stack/config.yaml"), pathlib.Path("/quay-registry/conf/stack/config.yaml")]
text = ""
for path in paths:
    if path.is_file():
        data = path.read_text(errors="ignore")
        if "DISTRIBUTED_STORAGE_CONFIG" in data:
            text = data
            break
ids = []
prefs = []
in_cfg = False
in_pref = False
for line in text.splitlines():
    if line.startswith("DISTRIBUTED_STORAGE_PREFERENCE:"):
        inline = line.split(":", 1)[1].strip()
        if inline.startswith("[") and inline.endswith("]") and inline[1:-1].strip():
            prefs.extend([part.strip() for part in inline[1:-1].split(",") if part.strip()])
        elif inline:
            prefs.append(inline)
        in_pref = True
        in_cfg = False
        continue
    if line.startswith("DISTRIBUTED_STORAGE_CONFIG:"):
        in_cfg = True
        in_pref = False
        continue
    if in_pref:
        stripped = line.strip()
        if stripped.startswith("- "):
            prefs.append(stripped[2:].strip())
            continue
        if line.strip() == "":
            continue
        in_pref = False
    if in_cfg:
        if line.startswith("  ") and not line.startswith("   ") and line.rstrip().endswith(":"):
            ids.append(line.strip()[:-1])
        elif line and not line.startswith(" "):
            in_cfg = False
preference_ok = bool(ids) and bool(prefs) and prefs[0] in ids
short_host = any(
    line.strip().startswith("hostname:")
    and line.strip().endswith(".svc")
    and ".cluster.local" not in line
    for line in text.splitlines()
)
proxy_ok = "FEATURE_PROXY_STORAGE: true" in text
sys.exit(0 if ("signature_version: s3v4" in text and "region_name:" in text and preference_ok and proxy_ok and not short_host) else 1)
'
}

restart_quay_app() {
  local ns=$1 host
  echo "Restarting Quay so it reloads the MinIO storage config."
  oc -n "${ns}" rollout restart deploy/registry-quay-app >/dev/null
  oc -n "${ns}" rollout status deploy/registry-quay-app --timeout=300s || return 1
  host="$(detect_quay_url 2>/dev/null || true)"
  if [[ -n "${host}" ]]; then
    wait_for_quay "${host}" || return 1
  fi
}

ensure_quay_storage_signature() {
  local ns=$1
  local cfg updated
  if ! oc -n "${ns}" get secret quay-config-bundle >/dev/null 2>&1; then
    return 0
  fi
  cfg="$(mktemp)"
  updated="$(mktemp)"
  oc -n "${ns}" get secret quay-config-bundle -o jsonpath='{.data.config\.yaml}' | base64 -d > "${cfg}"
  py_rc=0
  python3 - "${cfg}" "${updated}" <<'PY' || py_rc=$?
import pathlib, sys
src, dst = sys.argv[1], sys.argv[2]
rows = pathlib.Path(src).read_text().splitlines()

def storage_ids(lines):
    ids = []
    in_cfg = False
    for raw in lines:
        if raw.startswith("DISTRIBUTED_STORAGE_CONFIG:"):
            in_cfg = True
            continue
        if not in_cfg:
            continue
        if raw.startswith("  ") and not raw.startswith("   ") and raw.rstrip().endswith(":"):
            ids.append(raw.strip()[:-1])
            continue
        if raw and not raw.startswith(" "):
            in_cfg = False
    return ids

ids = storage_ids(rows)
has_sig = any(line.strip().startswith("signature_version:") for line in rows)
has_region = any(line.strip().startswith("region_name:") for line in rows)
out = []
i = 0
while i < len(rows):
    line = rows[i]
    if line.startswith("DISTRIBUTED_STORAGE_PREFERENCE:"):
        i += 1
        while i < len(rows) and (rows[i].strip() == "" or rows[i].strip().startswith("- ")):
            i += 1
        continue
    if line.strip().startswith("signature_version:"):
        indent = line[:len(line) - len(line.lstrip())]
        out.append(f"{indent}signature_version: s3v4")
        i += 1
        continue
    out.append(line)
    if not has_sig and line.strip().startswith("storage_path:"):
        indent = line[:len(line) - len(line.lstrip())]
        out.append(f"{indent}signature_version: s3v4")
        has_sig = True
    i += 1
if has_sig and not has_region:
    out.append("      region_name: us-east-1")
    has_region = True
if not has_sig or not has_region or not ids:
    sys.exit(2)
inserted = []
placed = False
for line in out:
    if not placed and line.startswith("DISTRIBUTED_STORAGE_CONFIG:"):
        inserted.append("DISTRIBUTED_STORAGE_PREFERENCE:")
        inserted.append(f"  - {ids[0]}")
        placed = True
    inserted.append(line)
if not placed:
    sys.exit(2)
final = []
saw_proxy = False
for line in inserted:
    stripped = line.strip()
    if stripped.startswith("FEATURE_PROXY_STORAGE:"):
        final.append("FEATURE_PROXY_STORAGE: true")
        saw_proxy = True
        continue
    if stripped.startswith("hostname:") and stripped.endswith(".svc") and ".cluster.local" not in stripped:
        indent = line[:len(line) - len(line.lstrip())]
        final.append(f"{indent}{stripped}.cluster.local")
        continue
    final.append(line)
if not saw_proxy:
    final.insert(0, "FEATURE_PROXY_STORAGE: true")
pathlib.Path(dst).write_text("\n".join(final) + "\n")
PY
  if [[ "${py_rc}" -ne 0 ]]; then
    echo "Error: Quay config.yaml has no usable DISTRIBUTED_STORAGE_CONFIG entry." >&2
    rm -f "${cfg}" "${updated}"
    return 1
  fi
  if ! cmp -s "${cfg}" "${updated}"; then
    oc -n "${ns}" create secret generic quay-config-bundle \
      --from-file=config.yaml="${updated}" \
      --dry-run=client -o yaml | oc apply -f - >/dev/null
    echo "Updated Quay storage: proxy blobs through Quay, s3v4 signature, and a resolvable MinIO hostname."
    nudge_quayregistry "${ns}"
  fi
  rm -f "${cfg}" "${updated}"

  if ! oc -n "${ns}" get deploy registry-quay-app >/dev/null 2>&1; then
    return 0
  fi
  # A secret volume update does not reload the running Quay process.
  local config_rv restarted
  config_rv="$(oc -n "${ns}" get secret quay-config-bundle -o jsonpath='{.metadata.resourceVersion}')"
  restarted="$(oc -n "${ns}" get deploy registry-quay-app -o jsonpath='{.metadata.annotations.roadshow/storage-config-restarted}' 2>/dev/null || true)"
  if [[ "${restarted}" != "${config_rv}" ]] || ! quay_loaded_storage_config "${ns}"; then
    restart_quay_app "${ns}" || return 1
    oc -n "${ns}" annotate deploy/registry-quay-app \
      "roadshow/storage-config-restarted=${config_rv}" --overwrite >/dev/null || true
  fi
  # The operator copies the bundle into the pod secret on its own rollout.
  # Wait until that file names the configured location, or blob upload 500s.
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if quay_loaded_storage_config "${ns}"; then
      return 0
    fi
    sleep 10
  done
  echo "Quay did not load region_name from config.yaml. Setting AWS_DEFAULT_REGION on the registry."
  oc -n "${ns}" set env deploy/registry-quay-app -c quay-app \
    AWS_DEFAULT_REGION=us-east-1 AWS_REGION=us-east-1 >/dev/null
  oc -n "${ns}" rollout status deploy/registry-quay-app --timeout=300s || return 1
  local host
  host="$(detect_quay_url 2>/dev/null || true)"
  if [[ -n "${host}" ]]; then
    wait_for_quay "${host}" || return 1
  fi
  if quay_loaded_storage_config "${ns}"; then
    return 0
  fi
  echo "Error: Quay did not load a storage preference that matches DISTRIBUTED_STORAGE_CONFIG." >&2
  return 1
}

# Blob upload returns HTTP 500 when bucket quay is missing, MinIO rejects
# the request signature, or DISTRIBUTED_STORAGE_PREFERENCE still says local_us.
# Repair all three even if /v2/ is already answering.
repair_quay_storage() {
  local ns=$1 user pass
  user="$(minio_credential "${ns}" MINIO_ROOT_USER 2>/dev/null || minio_credential "${ns}" MINIO_ACCESS_KEY 2>/dev/null || true)"
  pass="$(minio_credential "${ns}" MINIO_ROOT_PASSWORD 2>/dev/null || minio_credential "${ns}" MINIO_SECRET_KEY 2>/dev/null || true)"
  if [[ -z "${user}" || -z "${pass}" ]]; then
    echo "Error: could not read MinIO credentials from deployment/minio in ${ns}." >&2
    return 1
  fi
  local port host
  port="$(oc -n "${ns}" get svc minio -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
  port="${port:-9000}"
  # Short name minio.<ns>.svc is not a CoreDNS record. Image pulls query it
  # as an absolute name and fail with "no such host".
  host="minio.${ns}.svc.cluster.local"
  ensure_minio_bucket "${ns}" "${user}" "${pass}" "${host}" "${port}" || return 1
  ensure_quay_storage_signature "${ns}" || return 1
}

# QuayRegistry "registry" publishes route registry-quay, which the lab expects.
ensure_quay_registry() {
  local ns=$1
  if oc -n "${ns}" get quayregistry registry >/dev/null 2>&1; then
    echo "QuayRegistry ${ns}/registry already exists."
    return 0
  fi
  local existing
  existing="$(oc -n "${ns}" get quayregistry --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${existing}" != "0" ]]; then
    echo "QuayRegistry objects already exist in ${ns}; not creating another."
    return 0
  fi

  echo "No QuayRegistry in ${ns}. Creating registry so the operator publishes a route."
  local user pass svc port host
  user="$(minio_credential "${ns}" MINIO_ROOT_USER 2>/dev/null || minio_credential "${ns}" MINIO_ACCESS_KEY 2>/dev/null || true)"
  pass="$(minio_credential "${ns}" MINIO_ROOT_PASSWORD 2>/dev/null || minio_credential "${ns}" MINIO_SECRET_KEY 2>/dev/null || true)"
  if [[ -z "${user}" || -z "${pass}" ]]; then
    echo "Error: could not read MinIO credentials from deployment/minio in ${ns}." >&2
    return 1
  fi

  if ! oc -n "${ns}" get svc minio >/dev/null 2>&1; then
    echo "Creating Service ${ns}/minio"
    oc -n "${ns}" expose deploy/minio --name=minio --port=9000 --target-port=9000 >/dev/null
  fi
  svc="minio"
  port="$(oc -n "${ns}" get svc "${svc}" -o jsonpath='{.spec.ports[0].port}')"
  port="${port:-9000}"
  host="${svc}.${ns}.svc.cluster.local"

  ensure_minio_bucket "${ns}" "${user}" "${pass}" "${host}" "${port}" || return 1

  local cfg
  cfg="$(mktemp)"
  MINIO_USER="${user}" MINIO_PASS="${pass}" MINIO_HOST="${host}" MINIO_PORT="${port}" python3 -c '
import json, os
user = json.dumps(os.environ["MINIO_USER"])
password = json.dumps(os.environ["MINIO_PASS"])
host = json.dumps(os.environ["MINIO_HOST"])
port = os.environ["MINIO_PORT"]
print(f"""ALLOW_PULLS_WITHOUT_STRICT_LOGGING: false
AUTHENTICATION_TYPE: Database
DEFAULT_TAG_EXPIRATION: 2w
ENTERPRISE_LOGO_URL: /static/img/RH_Logo_Quay_Black_UX-horizontal_white.png
FEATURE_BUILD_SUPPORT: false
FEATURE_DIRECT_LOGIN: true
FEATURE_MAILING: false
FEATURE_USER_INITIALIZE: true
FEATURE_PROXY_STORAGE: true
REGISTRY_TITLE: Red Hat Quay
REGISTRY_TITLE_SHORT: Red Hat Quay
SETUP_COMPLETE: true
TAG_EXPIRATION_OPTIONS:
  - 2w
TEAM_RESYNC_STALE_TIME: 60m
TESTING: false
DISTRIBUTED_STORAGE_PREFERENCE:
  - default
DISTRIBUTED_STORAGE_CONFIG:
  default:
    - RadosGWStorage
    - access_key: {user}
      secret_key: {password}
      bucket_name: quay
      hostname: {host}
      is_secure: false
      port: {port}
      storage_path: /datastorage/registry
      signature_version: s3v4
      region_name: us-east-1
""")
' > "${cfg}"
  oc -n "${ns}" create secret generic quay-config-bundle \
    --from-file=config.yaml="${cfg}" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  rm -f "${cfg}"

  oc -n "${ns}" apply -f - <<EOF
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: registry
spec:
  configBundleSecret: quay-config-bundle
  components:
    - kind: objectstorage
      managed: false
EOF
  echo "Created QuayRegistry ${ns}/registry (route will be registry-quay)."
}

# Ask the Quay operator to reconcile again now that MinIO can start.
nudge_quayregistry() {
  local ns=$1 name
  local found=false
  while read -r name; do
    [[ -z "${name}" ]] && continue
    found=true
    echo "Requesting reconcile of QuayRegistry ${ns}/${name}"
    oc -n "${ns}" annotate "quayregistry/${name}" \
      "quay-operator.redhat.com/objectstorage-retry=$(date +%s)" --overwrite >/dev/null
  done < <(oc -n "${ns}" get quayregistry -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  if [[ "${found}" == false ]]; then
    echo "No QuayRegistry in namespace ${ns}. The operator will not create a route until that object exists."
  fi
}

show_quay_status() {
  local ns=$1
  echo "Quay workloads in ${ns}:"
  oc -n "${ns}" get pods,route --no-headers 2>/dev/null || true
  oc -n "${ns}" get quayregistry -o json 2>/dev/null | jq -r '
    .items[]? | "QuayRegistry \(.metadata.name):",
    (.status.conditions[]? | "  \(.type)=\(.status) \(.reason // "") \(.message // "")")
  ' || true
}

# quay.io/minio/mc rejects anonymous pulls. The bucket Job used to run that
# client, which left an ImagePullBackOff hook that blocks the Quay Argo sync.
# Bucket creation is the OpenShift CLI Job plus ensure_minio_bucket, so these
# Jobs are safe to delete. Deleting the Job also deletes its pods.
remove_unpullable_minio_mc_jobs() {
  local ns=$1 name
  while read -r name; do
    [[ -z "${name}" ]] && continue
    echo "Deleting Job ${ns}/${name}: quay.io/minio/mc rejects anonymous pulls."
    oc -n "${ns}" delete job "${name}" --wait=false || return 1
  done < <(oc -n "${ns}" get jobs -o json | jq -r '
    .items[]?
    | select(any(
        ((.spec.template.spec.containers // []) + (.spec.template.spec.initContainers // []))[];
        (.image // "") | test("minio/mc")
      ))
    | .metadata.name
  ')
}

# Repair Quay object storage before the rest of the lab. A healthy registry
# is left alone. A MinIO pod that cannot pull, or is not already on the
# public mirror, is switched to MINIO_REPLACEMENT_IMAGE.
do_ensure_quay() {
  local ns host repaired=false
  ns="$(quay_namespace)" || {
    echo "Error: Quay namespace not found (tried quay, quay-enterprise)." >&2
    return 1
  }
  echo "Checking Quay in namespace ${ns}"
  remove_unpullable_minio_mc_jobs "${ns}" || return 1

  if quay_v2_ready; then
    echo "Quay is up at $(detect_quay_url)."
    repair_quay_storage "${ns}" || return 1
    return 0
  fi

  if minio_needs_public_image "${ns}"; then
    echo "Quay is down. MinIO will use ${MINIO_REPLACEMENT_IMAGE}"
    repoint_minio_image "${ns}" || return 1
    repaired=true
  else
    echo "Quay is not healthy yet. MinIO is already on ${MINIO_REPLACEMENT_IMAGE}."
  fi

  # The operator does not create a route until a QuayRegistry exists.
  ensure_quay_registry "${ns}" || return 1
  nudge_quayregistry "${ns}"
  echo "Waiting for the Quay route..."
  local deadline=$((SECONDS + 600))
  local next_note=0
  while (( SECONDS < deadline )); do
    host="$(detect_quay_url 2>/dev/null || true)"
    if [[ -n "${host}" ]]; then
      wait_for_quay "${host}" || return 1
      repair_quay_storage "${ns}" || return 1
      echo "Quay is up at ${host}"
      return 0
    fi
    if (( SECONDS >= next_note )); then
      show_quay_status "${ns}"
      next_note=$((SECONDS + 30))
    fi
    sleep 5
  done

  echo "Error: Quay route did not appear within 600s (namespace ${ns})." >&2
  if [[ "${repaired}" == true ]]; then
    echo "MinIO is running ${MINIO_REPLACEMENT_IMAGE}, but the registry route is still missing." >&2
  fi
  show_quay_status "${ns}" >&2 || true
  oc -n "${ns}" logs deploy/minio --tail=40 >&2 || true
  return 1
}

progress_run "Verify OpenShift access" do_verify_admin
progress_run "Store Lightspeed API token" configure_lightspeed_token
progress_run "Read Quay credentials" load_quay_env
progress_run "Install TSSC CLIs (cosign, oc-mirror, ec)" do_tssc_clis

# Kick off RHACS configure in the background so demo apps / Quay work can overlap.
configure_pid=""
configure_log="${LOG_DIR}/rhacs-configure-bg-$(date +%Y%m%d-%H%M%S).log"
if [[ "${SKIP_RHACS_CONFIGURE}" != true ]]; then
  PROGRESS_CURRENT=$((PROGRESS_CURRENT + 1))
  progress_render "RHACS configure (background — overlaps with apps/Quay)"
  {
    echo ""
    echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) START background rhacs-configure ====="
  } >> "${LOG_FILE}"
  configure_args=()
  [[ "${VERBOSE}" == true ]] && configure_args+=(--verbose)
  # Log-only while backgrounded so this TTY keeps a single progress bar
  (
    bash "${SCRIPT_DIR}/rhacs-configure.sh" "${configure_args[@]+"${configure_args[@]}"}"
  ) >"${configure_log}" 2>&1 &
  configure_pid=$!
fi

progress_run "Configure RHACS CLI variables" do_cli_vars
progress_run "Verify RHACS API access" do_verify_api

# While optional RHACS configure runs in the background, clone demo-apps for image builds.
if [[ "${SKIP_DEMO_APPS}" != true ]]; then
  progress_run "Clone workshop application sources" do_clone_demo_apps
  if [[ "${SKIP_DEMO_APPLY}" != true ]]; then
    progress_run "Deploy workshop applications" do_apply_demo_apps
  fi
fi

if [[ -n "${configure_pid}" ]]; then
  # Heartbeat while background configure runs so the bar does not look stuck.
  while kill -0 "${configure_pid}" 2>/dev/null; do
    progress_render "Waiting for RHACS configure to finish"
    sleep 2
  done
  set +e
  wait "${configure_pid}"
  cfg_rc=$?
  set -e
  if [[ "${cfg_rc}" -ne 0 ]]; then
    if [[ -t 1 ]]; then printf '\n'; fi
    echo "FAILED: RHACS configure (exit ${cfg_rc}). Log: ${configure_log}" >&2
    tail -n 40 "${configure_log}" >&2 || true
    exit "${cfg_rc}"
  fi
  {
    echo ""
    echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) END background rhacs-configure (ok) ====="
    cat "${configure_log}"
  } >> "${LOG_FILE}"
  progress_render "RHACS configure finished"
  load_roadshow_env
fi

progress_done "Lab environment setup complete"
load_roadshow_env

if [[ "${LIGHTSPEED_TOKEN_SAVED:-false}" == true ]]; then
  lightspeed_banner="Lightspeed API token stored"
else
  lightspeed_banner="Lightspeed API token skipped"
fi
progress_success_banner "Lab environment setup completed successfully" \
  "${lightspeed_banner}" \
  "Quay credentials read from the cluster" \
  "RHACS CLI ready (ROX_CENTRAL_ADDRESS / ROX_API_TOKEN saved)" \
  "TSSC CLIs on PATH (cosign, oc-mirror, ec in ~/.local/bin)" \
  "Env file: ${ROADSHOW_ENV_FILE}" \
  "Detailed log: ${LOG_FILE}"
