# Environment updates

Instructor scripts that SSH to every bastion in an RHDP export. They use password authentication on the high SSH port from that export.

Keep the real CSV on your machine. Do not commit it. `updates/bastions.csv`, `updates/ssh_access.csv`, `updates/logs/`, and `updates/.venv/` are gitignored.

## Setup

```bash
cd updates
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r requirements.txt
```

## CSV columns

Header required. This is the RHDP bastion export (`ssh_access.csv`):

| Column | Required | Default | Description |
| --- | --- | --- | --- |
| guid | no | — | Cluster guid. Showroom is `deploy/showroom` in `showroom-<guid>` or `showroom-<guid>-<n>` (these clusters use `showroom-<guid>-1`) |
| hostname | yes | — | Bastion hostname. `host` is accepted as an alias |
| port | no | 22 | SSH port |
| username | no | lab-user | SSH user. `user` is accepted as an alias |
| password | yes | — | SSH password |
| ssh_command | no | — | Ignored. The script connects with the columns above |

See [bastions.example.csv](bastions.example.csv).

## Refresh the lab guide

Showroom clones the guide in an init container (`git-cloner`) every time the pod starts. The catalog stores a pinned `GIT_REPO_REF`. This script changes the cloner so each rebuild checks out `main` and then builds the site. The catalog pin is left in place and is not what the cloner checks out.

Wetty runs in the same pod, so open Showroom terminals drop until the new pod is Ready.

```bash
python3 refresh_showroom.py --csv /path/to/ssh_access.csv
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
python3 configure_environments.py --csv /path/to/ssh_access.csv
```

When setup exits 0 and the follow-up checks pass, the host prints `up to date and configured`. Checks confirm `oc whoami`, that `QUAY_TOKEN` and `ROX_API_TOKEN` are defined in `~/.acs-roadshow/env` (values are not printed), and that `cosign`, `oc-mirror`, `ec`, and `mvn` are on `PATH`. The run ends with `N/M configured`.

Setup can take many minutes because it waits for the RHEL webserver VM. `--timeout` defaults to 3600 seconds. `--workers` defaults to 5.

## Logs

Stdout is a short status per bastion. Full remote output is written to `updates/logs/<guid>-<port>.log`. Both scripts append a summary to `updates/results.log`. The process exits non-zero when any bastion fails.
