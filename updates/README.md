# Environment updates

Instructor scripts that SSH to every bastion in a credential CSV. They use password authentication on the SSH port from that file.

Keep the real CSV on your machine. Do not commit it. `updates/bastions.csv`, `updates/ssh_access.csv`, `gameify/bastions.csv`, `updates/logs/`, and `updates/.venv/` are gitignored.

## Setup

```bash
cd updates
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r requirements.txt
```

## CSV columns

Header required. Same columns as `gameify/bastions.csv`:

| Column | Required | Default | Description |
| --- | --- | --- | --- |
| host | yes | — | Bastion hostname. `hostname` is accepted as an alias |
| port | no | 22 | SSH port |
| user | no | lab-user | SSH user. `username` is accepted as an alias |
| password | yes | — | SSH password |
| email | no | — | Printed in the per-host header. Not used to connect |
| guid | no | — | RHDP cluster guid, when the export has one. Showroom is `deploy/showroom` in `showroom-<guid>` or `showroom-<guid>-<n>` |
| ssh_command | no | — | Ignored. The script connects with the columns above |

See [bastions.example.csv](bastions.example.csv).

## Refresh the lab guide

Showroom clones the guide in an init container (`git-cloner`) every time the pod starts. The catalog stores a pinned `GIT_REPO_REF`. This script changes the cloner so each rebuild checks out `main` and then builds the site. The catalog pin is left in place and is not what the cloner checks out.

Wetty runs in the same pod, so open Showroom terminals drop until the new pod is Ready.

```bash
python3 refresh_showroom.py --csv bastions.csv
```

One bastion:

```bash
python3 refresh_showroom.py -H ssh.example.com --port 32194 --user lab-user -P 'secret' --guid exampl
```

Useful flags: `--workers` (default 5), `--namespace`, `--deployment`, `--timeout` (default 420 seconds).

Each host prints the namespace, deployment, pod Ready state, and `GIT_REF`. The run ends with `N/M refreshed`.

## Re-run bastion setup

This updates `~/ocp5-rhacs-showroom` on the bastion (`git pull --ff-only`, or a clone when the checkout is missing) and runs `setup/lab-environment.sh`. A dirty tree is reported and left alone. Module labs under `setup/` are not run.

```bash
python3 configure_environments.py --csv bastions.csv
```

When setup exits 0 and the follow-up checks pass, the host prints `up to date and configured`. Checks confirm `oc whoami`, that `QUAY_TOKEN` and `ROX_API_TOKEN` are defined in `~/.acs-roadshow/env` (values are not printed), and that `cosign`, `oc-mirror`, `ec`, and `mvn` are on `PATH`. The run ends with `N/M configured`.

Setup can take many minutes because it waits for the RHEL webserver VM. `--timeout` defaults to 3600 seconds. `--workers` defaults to 5.

## Refresh the security response snapshot

The OpenShift security response track is rendered from `content/modules/security-response`. Upstream source is a filtered snapshot in `vendor/security-response`, taken from the GitHub fork of [jmhbnz/workshops](https://github.com/jmhbnz/workshops).

The fork for this account is [mfosterrox/workshops](https://github.com/mfosterrox/workshops). `jmhbnz/workshops` stays the parent. To pull new commits into the fork and refresh the snapshot:

```bash
updates/sync-security-response.sh
```

The script syncs the fork from `jmhbnz/workshops` when `gh` can see that fork, sparse-clones it, and copies an allowlist. It records the commit in `vendor/security-response/UPSTREAM`.

It does not edit Showroom pages. After it runs, review the snapshot and update `content/modules/security-response` by hand.

`SECURITY_RESPONSE_REPO` overrides the fork (`owner/name`). `UPSTREAM_SLUG` overrides the parent (default `jmhbnz/workshops`).

The snapshot omits `exercise4.mdx` and `setup/exercise4/exploit/`.

## Logs

Stdout is a short status per bastion. The header includes the email when the CSV has one. Full remote output is written to `updates/logs/<host>-<port>.log`. Both scripts append a summary to `updates/results.log`. The process exits non-zero when any bastion fails.
