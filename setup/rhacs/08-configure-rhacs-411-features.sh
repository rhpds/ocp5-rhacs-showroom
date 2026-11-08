#!/bin/bash
# RHACS 5.0 demo configuration — Scanner V4, runtime features, and Lightspeed risk enrichment.
#
# Requires: oc logged in, jq. ROX_API_TOKEN is required except for --risk-enrichment-only.
# Optional: SKIP_RHACS_411_TP_FLAGS=1
#           --risk-enrichment-only  only the Lightspeed binding, policy, and endpoint

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
ROX_CENTRAL_ADDRESS="${ROX_CENTRAL_ADDRESS:-}"
ATTACH_POLICY_NAME="${ATTACH_POLICY_NAME:-Kubernetes Actions: Attach to Pod}"
LIGHTSPEED_NAMESPACE="${LIGHTSPEED_NAMESPACE:-openshift-lightspeed}"
LIGHTSPEED_ENDPOINT="${ROX_LIGHTSPEED_ENDPOINT:-https://lightspeed-app-server.openshift-lightspeed.svc:8443}"
LIGHTSPEED_QUERY_ROLE="lightspeed-operator-query-access"
LIGHTSPEED_BINDING="central-lightspeed-query-access"
LIGHTSPEED_POLICY="allow-rhacs-central-lightspeed"
RISK_ENRICHMENT_ONLY=false
if [ "${1:-}" = "--risk-enrichment-only" ]; then
    RISK_ENRICHMENT_ONLY=true
fi

get_central_url() {
    if [ -n "${ROX_CENTRAL_ADDRESS}" ]; then
        # Roadshow uses host-only; ensure https:// for curl/API
        if [[ "${ROX_CENTRAL_ADDRESS}" == https://* || "${ROX_CENTRAL_ADDRESS}" == http://* ]]; then
            echo "${ROX_CENTRAL_ADDRESS}"
        else
            echo "https://${ROX_CENTRAL_ADDRESS}"
        fi
        return 0
    fi
    oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || return 1
}

# namespace and name of the Central custom resource.
central_cr_ref() {
    local ns name
    ns="${RHACS_NAMESPACE}"
    name="$(oc get central -n "${ns}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "${name}" ]; then
        ns="$(oc get central -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
        name="$(oc get central -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    fi
    [ -n "${ns}" ] && [ -n "${name}" ] || return 1
    printf '%s %s\n' "${ns}" "${name}"
}

# Replace or append spec.customize.envVars without dropping unrelated entries.
upsert_cr_env() {
    local kind="$1" ns="$2" name="$3"
    shift 3
    local current updated
    current="$(oc get "${kind}" "${name}" -n "${ns}" -o json)"
    updated="$(printf '%s\n' "$@" | jq -R 'split("=") | {name: .[0], value: (.[1:] | join("="))}' | jq -s --argjson obj "${current}" '
        . as $updates
        | ($obj.spec.customize.envVars // []) as $list
        | reduce $updates[] as $u ($list;
            if any(.[]; .name == $u.name) then
              map(if .name == $u.name then .value = $u.value else . end)
            else . + [$u] end)
        | {spec: {customize: {envVars: .}}}
    ')"
    oc patch "${kind}" "${name}" -n "${ns}" --type=merge -p "${updated}" >/dev/null
}

configure_scanner_v4() {
    local ns name
    read -r ns name < <(central_cr_ref) || {
        print_warn "Central custom resource not found; skipping Scanner V4 custom resource update"
        return 0
    }
    print_step "Enabling Scanner V4 on Central ${ns}/${name}..."
    if oc get central "${name}" -n "${ns}" -o json | jq -e '.spec.scanner != null' >/dev/null 2>&1; then
        oc patch central "${name}" -n "${ns}" --type=json -p '[{"op":"remove","path":"/spec/scanner"}]' >/dev/null \
            || print_warn "Could not remove spec.scanner"
    fi
    oc patch central "${name}" -n "${ns}" --type=merge -p '{"spec":{"central":{"rolloutStrategy":"RollingUpdate"},"scannerV4":{"scannerComponent":"Enabled"}}}' >/dev/null \
        || print_warn "Could not set Scanner V4 and RollingUpdate on the Central custom resource"
    print_info "✓ Scanner V4 enabled and Central rolloutStrategy is RollingUpdate"
}

configure_secured_clusters() {
    print_step "Enabling file activity monitoring and VM scanning on SecuredClusters..."
    local found=false ns name
    while read -r ns name; do
        [ -n "${ns}" ] && [ -n "${name}" ] || continue
        found=true
        oc patch securedcluster "${name}" -n "${ns}" --type=merge \
            -p '{"spec":{"perNode":{"fileActivityMonitoring":{"mode":"Enabled"}}}}' >/dev/null \
            || print_warn "Could not enable file activity monitoring on ${ns}/${name}"
        upsert_cr_env securedcluster "${ns}" "${name}" \
            "ROX_VIRTUAL_MACHINES=true" \
            "ROX_VIRTUAL_MACHINES_SCRAPER_POLL_INTERVAL=1m" \
            || print_warn "Could not set VM scanning env on ${ns}/${name}"
        print_info "✓ SecuredCluster ${ns}/${name}: file activity monitoring and VM scraping"
    done < <(oc get securedcluster -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    if [ "${found}" != true ]; then
        print_warn "No SecuredCluster custom resources found"
    fi
}

ensure_lightspeed_risk_enrichment() {
    local ns name app_name
    print_step "Enabling OpenShift Lightspeed risk enrichment..."

    if ! oc get clusterrole "${LIGHTSPEED_QUERY_ROLE}" >/dev/null 2>&1; then
        print_error "ClusterRole ${LIGHTSPEED_QUERY_ROLE} is missing. OpenShift Lightspeed is not installed."
        return 1
    fi
    if ! oc get svc lightspeed-app-server -n "${LIGHTSPEED_NAMESPACE}" >/dev/null 2>&1; then
        print_error "Service ${LIGHTSPEED_NAMESPACE}/lightspeed-app-server is missing. OpenShift Lightspeed is not installed."
        return 1
    fi

    read -r ns name < <(central_cr_ref) || {
        print_error "Central custom resource not found; cannot bind Lightspeed risk enrichment"
        return 1
    }

    oc apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${LIGHTSPEED_BINDING}
  labels:
    app.kubernetes.io/part-of: lightspeed-operator
    app.kubernetes.io/component: rhacs-risk-enrichment
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${LIGHTSPEED_QUERY_ROLE}
subjects:
  - kind: ServiceAccount
    name: central
    namespace: ${ns}
EOF

    app_name="$(oc get deploy lightspeed-app-server -n "${LIGHTSPEED_NAMESPACE}" -o jsonpath='{.spec.selector.matchLabels.app\.kubernetes\.io/name}' 2>/dev/null || true)"
    app_name="${app_name:-lightspeed-service-api}"

    # The operator policy already allows the console, ingress, and Prometheus.
    # This policy adds Central. It also repeats those peers so Central is not
    # the only client if this policy is applied before the operator policy.
    oc apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${LIGHTSPEED_POLICY}
  namespace: ${LIGHTSPEED_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: lightspeed-operator
    app.kubernetes.io/component: rhacs-risk-enrichment
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: ${app_name}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${ns}
          podSelector:
            matchLabels:
              app: central
      ports:
        - protocol: TCP
          port: 8443
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: openshift-console
          podSelector:
            matchLabels:
              app: console
      ports:
        - protocol: TCP
          port: 8443
    - from:
        - namespaceSelector:
            matchLabels:
              network.openshift.io/policy-group: ingress
      ports:
        - protocol: TCP
          port: 8443
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: openshift-monitoring
          podSelector:
            matchExpressions:
              - key: app.kubernetes.io/name
                operator: In
                values:
                  - prometheus
              - key: prometheus
                operator: In
                values:
                  - k8s
      ports:
        - protocol: TCP
          port: 8443
EOF

    upsert_cr_env central "${ns}" "${name}" "ROX_LIGHTSPEED_ENDPOINT=${LIGHTSPEED_ENDPOINT}"

    if ! oc get clusterrolebinding "${LIGHTSPEED_BINDING}" >/dev/null 2>&1; then
        print_error "ClusterRoleBinding ${LIGHTSPEED_BINDING} was not created"
        return 1
    fi
    if ! oc get networkpolicy "${LIGHTSPEED_POLICY}" -n "${LIGHTSPEED_NAMESPACE}" >/dev/null 2>&1; then
        print_error "NetworkPolicy ${LIGHTSPEED_NAMESPACE}/${LIGHTSPEED_POLICY} was not created"
        return 1
    fi
    if ! oc get central "${name}" -n "${ns}" -o json | jq -e --arg endpoint "${LIGHTSPEED_ENDPOINT}" \
        '.spec.customize.envVars[]? | select(.name == "ROX_LIGHTSPEED_ENDPOINT" and .value == $endpoint)' >/dev/null; then
        print_error "Central custom resource is missing ROX_LIGHTSPEED_ENDPOINT=${LIGHTSPEED_ENDPOINT}"
        return 1
    fi

    print_info "✓ Lightspeed risk enrichment: query access, network policy, and ROX_LIGHTSPEED_ENDPOINT"
}

# Set Central env vars for 5.0 features via the custom resource and the deployment.
configure_central_tp_flags() {
    if [ "${SKIP_RHACS_411_TP_FLAGS:-0}" = "1" ]; then
        print_info "Skipping TP feature flags (SKIP_RHACS_411_TP_FLAGS=1)"
        return 0
    fi

    print_step "Enabling RHACS 5.0 Central feature flags..."

    local cr_ns cr_name
    if ! read -r cr_ns cr_name < <(central_cr_ref); then
        print_warn "Central custom resource not found; skipping Central feature flags"
        return 0
    fi

    # The operator copies these onto the deployment. A direct deployment edit is reverted.
    upsert_cr_env central "${cr_ns}" "${cr_name}" \
        "ROX_INIT_CONTAINER_SUPPORT=true" \
        "ROX_POLICY_FILTERS_UI=enabled" \
        "ROX_VIRTUAL_MACHINES=true" \
        "ROX_LIGHTSPEED_ENDPOINT=${LIGHTSPEED_ENDPOINT}" \
        || print_warn "Could not persist Central feature flags on the custom resource"

    if oc get deployment central -n "${cr_ns}" &>/dev/null; then
        oc rollout status deployment/central -n "${cr_ns}" --timeout=300s 2>/dev/null || \
            print_warn "Central rollout may still be in progress after feature flag update"
    fi
    print_info "✓ Central feature flags are set on ${cr_ns}/${cr_name}"
    return 0
}

api_call() {
    local method="$1"
    local endpoint="$2"
    local token="$3"
    local api_base="$4"
    local data="${5:-}"

    local response http_code body
    if [ -n "${data}" ]; then
        response=$(curl -k -s -w "\n%{http_code}" -X "${method}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "${data}" \
            "${api_base}/${endpoint}" 2>/dev/null || echo "")
    else
        response=$(curl -k -s -w "\n%{http_code}" -X "${method}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            "${api_base}/${endpoint}" 2>/dev/null || echo "")
    fi
    http_code=$(echo "${response}" | tail -n1)
    body=$(echo "${response}" | sed '$d')
    if [ "${http_code}" -lt 200 ] || [ "${http_code}" -ge 300 ]; then
        print_warn "API ${method} ${endpoint} returned HTTP ${http_code}"
        echo "${body}" >&2
        return 1
    fi
    echo "${body}"
    return 0
}

ensure_attach_policy() {
    local token="$1"
    local api_base="$2"
    local enforce="${RHACS_ATTACH_POLICY_ENFORCE:-alert}"

    print_step "Verifying Attach to Pod policy (4.11)..."

    local policies policy_id policy_json
    policies=$(api_call "GET" "policies" "${token}" "${api_base}" "") || return 0

    policy_id=$(echo "${policies}" | jq -r --arg n "${ATTACH_POLICY_NAME}" '.policies[]? | select(.name == $n) | .id' 2>/dev/null | head -1)
    if [ -z "${policy_id}" ] || [ "${policy_id}" = "null" ]; then
        print_warn "Default policy '${ATTACH_POLICY_NAME}' not found; may appear after Central upgrade"
        return 0
    fi

    policy_json=$(echo "${policies}" | jq --arg id "${policy_id}" '.policies[] | select(.id == $id)' 2>/dev/null)
    if [ -z "${policy_json}" ]; then
        return 0
    fi

    if [ "${enforce}" = "enforce" ]; then
        policy_json=$(echo "${policy_json}" | jq '.disabled = false | .enforcementActions = ["UNSATISFIABLE"]' 2>/dev/null)
        if api_call "PUT" "policies/${policy_id}" "${token}" "${api_base}" "${policy_json}" >/dev/null 2>&1; then
            print_info "✓ Attach policy enabled with enforcement"
        else
            print_warn "Could not update Attach policy enforcement"
        fi
    else
        local disabled
        disabled=$(echo "${policy_json}" | jq -r '.disabled' 2>/dev/null)
        if [ "${disabled}" = "true" ]; then
            policy_json=$(echo "${policy_json}" | jq '.disabled = false' 2>/dev/null)
            api_call "PUT" "policies/${policy_id}" "${token}" "${api_base}" "${policy_json}" >/dev/null 2>&1 || true
        fi
        print_info "✓ Attach policy '${ATTACH_POLICY_NAME}' present (alert mode)"
    fi
    return 0
}

main() {
    print_info "=========================================="
    print_info "RHACS 5.0 Feature Configuration"
    print_info "=========================================="
    print_info ""

    if ! command -v jq &>/dev/null; then
        print_error "jq is required"
        exit 1
    fi
    if ! oc whoami >/dev/null 2>&1; then
        print_error "oc is not logged in"
        exit 1
    fi

    if [ "${RISK_ENRICHMENT_ONLY}" = true ]; then
        ensure_lightspeed_risk_enrichment
        return 0
    fi

    local token="${ROX_API_TOKEN:-}"
    if [ -z "${token}" ]; then
        print_error "ROX_API_TOKEN is required"
        exit 1
    fi

    local central_url api_host api_base
    central_url=$(get_central_url) || {
        print_error "Could not determine Central URL"
        exit 1
    }
    api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    api_base="https://${api_host}/v1"

    configure_scanner_v4
    configure_central_tp_flags
    configure_secured_clusters

    print_info ""
    ensure_attach_policy "${token}" "${api_base}"

    print_info ""
    ensure_lightspeed_risk_enrichment

    print_info ""
    print_info "=========================================="
    print_info "RHACS 5.0 Feature Configuration Complete"
    print_info "=========================================="
    print_info "  - Scanner V4 enabled; StackRox Scanner removed from the Central custom resource"
    print_info "  - Central rolloutStrategy RollingUpdate"
    print_info "  - File activity monitoring and VM scraping enabled"
    print_info "  - Lightspeed risk enrichment enabled"
    print_info "  - Attach to Pod policy verified"
    print_info ""
}

main "$@"
