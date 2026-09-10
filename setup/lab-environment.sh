#!/usr/bin/env bash
# Provision the ACS roadshow lab environment on the bastion host.
# Runs RHACS CLI token setup, clones demo-apps (for Dockerfiles), and
# builds/pushes Quay images. Cluster-wide RHACS/Compliance/demo-app
# deploy is owned by OpenShift GitOps (roadshow-prereqs + roadshow-demo-apps).
#
# Quiet by default (progress bar + current step). Use --verbose for full logs.
#
# Usage:
#   bash setup/lab-environment.sh \
#     --quay-user QUAYADMIN \
#     --quay-password 'secret'
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
        export\ ROX_*|export\ QUAY_*|export\ TUTORIAL_HOME=*|export\ APP_HOME=*|export\ RHACS_NAMESPACE=*)
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
  --quay-user USER          Quay admin username (required unless --deploy-skupper-only)
  --quay-password PASS      Quay admin password (required unless --deploy-skupper-only)
  --deploy-skupper-only     Deploy patient-portal after frontend repo is public in Quay
  --skip-demo-apps          Skip cloning the demo-apps repository
  --apply-demo-apps         oc apply demo-apps manifests (GitOps deploys these by default)
  --skip-images             Skip golden image and frontend build/push
  --rhacs-configure         Run setup/rhacs-configure.sh (GitOps owns this by default)
  --skip-rhacs-configure    Deprecated; configure is skipped unless --rhacs-configure
  --verbose                 Stream detailed command output
  --work-dir DIR            Base directory for clones (default: $HOME)
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quay-user) QUAY_USER=$2; shift 2 ;;
    --quay-password) QUAY_PASSWORD=$2; shift 2 ;;
    --deploy-skupper-only) DEPLOY_SKUPPER_ONLY=true; shift ;;
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

if [[ "${DEPLOY_SKUPPER_ONLY}" == true ]]; then
  deploy_skupper
  exit 0
fi

if [[ -z "${QUAY_USER}" || -z "${QUAY_PASSWORD}" ]]; then
  echo "Error: --quay-user and --quay-password are required for full setup." >&2
  usage
  exit 1
fi
if [[ "${QUAY_USER}" == *'{'* || "${QUAY_PASSWORD}" == *'{'* ]]; then
  echo "Error: --quay-user / --quay-password still contain Showroom placeholders." >&2
  echo "Use the values from the credentials table (username is usually admin), not {quay_admin_username}." >&2
  exit 1
fi

# Count top-level lab steps (cluster RHACS/Compliance/apps come from GitOps)
TOTAL=0
TOTAL=$((TOTAL + 2)) # admin + wait central
[[ "${SKIP_RHACS_CONFIGURE}" != true ]] && TOTAL=$((TOTAL + 1))
TOTAL=$((TOTAL + 2)) # CLI vars + verify API
[[ "${SKIP_DEMO_APPS}" != true ]] && TOTAL=$((TOTAL + 1)) # clone
[[ "${SKIP_DEMO_APPS}" != true && "${SKIP_DEMO_APPLY}" != true ]] && TOTAL=$((TOTAL + 1)) # apply
[[ "${SKIP_IMAGES}" != true ]] && TOTAL=$((TOTAL + 3)) # quay login + golden + frontend

LOG_DIR="${HOME}/.acs-roadshow"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/lab-environment-$(date +%Y%m%d-%H%M%S).log"
progress_init "${TOTAL}" "${LOG_FILE}" "Lab environment setup"

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

do_cli_vars() {
  load_roadshow_env
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
  dest="${HOME}/.local/bin"
  mkdir -p "${dest}"
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
  export PATH="${dest}:${PATH}"
  if ! grep -qE '(^|:)\$HOME/\.local/bin|^export PATH="\$HOME/\.local/bin' "${HOME}/.bashrc" 2>/dev/null; then
    printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "${HOME}/.bashrc"
  fi
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
  cat /tmp/quay-init.json 2>/dev/null || true
  echo
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
    return 0
  fi
  local cluster_pass=""
  cluster_pass="$(oc -n quay get secret quay-admin-password -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
  if [[ -n "${cluster_pass}" && "${cluster_pass}" != "${QUAY_PASSWORD}" ]]; then
    echo "Login failed with the Showroom password; trying secret/quay-admin-password..."
    initialize_quay_admin "${QUAY_URL}" "${QUAY_USER}" "${cluster_pass}"
    if podman_login_quay "${QUAY_URL}" "${QUAY_USER}" "${cluster_pass}"; then
      persist_var QUAY_PASSWORD "${cluster_pass}"
      return 0
    fi
  fi
  echo "Error: podman login to ${QUAY_URL} failed for user '${QUAY_USER}'." >&2
  echo "Create the first user (once) with:" >&2
  echo "  curl -sk -X POST 'https://${QUAY_URL}/api/v1/user/initialize' -H 'Content-Type: application/json' \\" >&2
  echo "    -d '{\"username\":\"${QUAY_USER}\",\"password\":\"<password>\",\"email\":\"${QUAY_USER}@example.com\",\"access_token\":true}'" >&2
  return 1
}

do_golden_image() {
  ensure_podman || return 1
  podman pull "${PYTHON_ALPINE_BASE}"
  podman tag "${PYTHON_ALPINE_BASE}" "${QUAY_URL}/${QUAY_USER}/python-alpine-golden:0.1"
  podman push "${QUAY_URL}/${QUAY_USER}/python-alpine-golden:0.1"
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
  podman push "${QUAY_URL}/${QUAY_USER}/frontend:0.1" --remove-signatures
}

progress_run "Verify OpenShift access" do_verify_admin
progress_run "Wait for RHACS Central" do_wait_central

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

if [[ "${SKIP_IMAGES}" != true ]]; then
  progress_run "Log in to Quay" do_quay_login
  progress_run "Build and push golden base image" do_golden_image
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

if [[ "${SKIP_IMAGES}" != true ]]; then
  progress_run "Build and push frontend image" do_frontend_image
fi

progress_done "Lab environment setup complete"
load_roadshow_env

progress_success_banner "Lab environment setup completed successfully" \
  "RHACS CLI ready (ROX_CENTRAL_ADDRESS / ROX_API_TOKEN saved)" \
  "demo-apps cloned for image builds (cluster deploy is GitOps)" \
  "Quay images ready (golden base + frontend, when image steps ran)" \
  "Env file: ${ROADSHOW_ENV_FILE}" \
  "Detailed log: ${LOG_FILE}"
