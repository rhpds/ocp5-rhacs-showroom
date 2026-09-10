#!/usr/bin/env bash
# Practice Check for the TSSC overview. Idempotent. Does not reset a filled token.
set -euo pipefail
NS=lw-poc-validate

oc get namespace "${NS}" >/dev/null

if ! oc -n "${NS}" get configmap report-00-check-demo >/dev/null 2>&1; then
  oc -n "${NS}" create configmap report-00-check-demo \
    --from-literal=module=00 \
    --from-literal=title='How checks work' \
    --from-literal=check_flow=REPLACE_ME
fi

cat >/tmp/job-00.yaml <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: validate-00-check-demo
  namespace: lw-poc-validate
  labels:
    app.kubernetes.io/name: validate-jobs
    app.kubernetes.io/component: validate
    tssc.workshop/module: "00"
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 60
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app.kubernetes.io/name: validate-jobs
        app.kubernetes.io/component: validate
        tssc.workshop/module: "00"
    spec:
      restartPolicy: Never
      serviceAccountName: validate-jobs
      containers:
        - name: check
          image: registry.redhat.io/openshift4/ose-cli:latest
          imagePullPolicy: IfNotPresent
          command:
            - /bin/bash
            - -ec
            - |
              echo "=== Validate Job 00. How checks work ==="
              TOKEN="$(oc -n lw-poc-validate get configmap report-00-check-demo -o jsonpath='{.data.check_flow}' 2>/dev/null || true)"
              if [[ -z "${TOKEN}" || "${TOKEN}" == "REPLACE_ME" ]]; then
                echo "CHECK FAILED: report-00-check-demo key check_flow is still REPLACE_ME. Set it to checks-work, then re-run this Job."
                exit 1
              fi
              if [[ "${TOKEN}" != "checks-work" ]]; then
                echo "CHECK FAILED: report-00-check-demo key check_flow must be checks-work (got '${TOKEN}')."
                exit 1
              fi
              echo "CHECK PASSED: report token is set. Lab Checks use this same Job flow."
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
EOF

oc -n "${NS}" create configmap validate-job-demo-templates \
  --from-file=job-00.yaml=/tmp/job-00.yaml \
  --dry-run=client -o yaml | oc apply -f -

echo "Practice Check objects are ready in ${NS}."
