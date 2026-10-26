# Showroom module tests

The runner reads each lab page under `content/modules/ROOT/pages`. It walks `role=execute` commands in order and compares the output to the sample in that module.

Tracks come from `content/modules/ROOT/nav.adoc`: `101`, `201`, `301`, `acs`, `tssc`, and `virt`.

Expected output is, in order:

- the following `[.console-output]` block
- otherwise the next source block that is not `role=execute`
- otherwise backtick text in a `TIP` or `NOTE` on that step

Cluster hostnames, timestamps, large UIDs, image digests, and `...` or `YYYYMMDD-HHMMSS` placeholders are wildcards. A non-zero exit code fails the step. Commands with no sample are judged on exit code. `oc edit`, `vi`, `read`, a tty `oc exec` or `oc rsh`, and `oc get -w` / `oc logs -f` are skipped. Any other command that does not return in 45 seconds is stopped and the runner moves on. A command that sets its own `--timeout` may run up to 150 seconds.

Before a module runs, the runner deletes namespaces that module creates with `oc new-project` or `oc create namespace`. It leaves `openshift-*`, `kube-*`, `default`, and `rhacs-operator` in place.

Use the current `oc` login. Set `SHOWROOM_COMMON_PASSWORD` when a command still contains `{common_password}`.

```bash
python3 tests/run.py
python3 tests/run.py --track acs
python3 tests/run.py --module 101-01
python3 tests/run.py --content-only

make test
make test TRACK=acs
make test MODULE=101-01
make test CONTENT_ONLY=1
```

Each run writes `tests/reports/<timestamp>/summary.md`, `summary.json`, and one markdown file per track. The process exits non-zero when a content check or command step fails.
