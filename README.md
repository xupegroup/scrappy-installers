# scrappy-installers

Public bootstrap scripts for the [Scrappy](https://scrappy.hu) infrastructure. The application code itself lives in a separate private repo — these scripts only handle initial host setup and pull pre-built images from a private container registry.

## Available scripts

### `install-worker.sh`

Provisions a Scrappy worker on a fresh mini-PC. Sets up Docker, writes the env file, generates a docker-compose with the worker container + Watchtower for auto-updates, logs in to the private GHCR, and starts everything.

Prerequisites:
- A Linux host (Ubuntu 22.04 / 24.04 tested). Root access.
- A worker token issued from the admin UI (`wk_live_…`). **This is the only secret the operator types.**

That's it. The GHCR pull credentials, S3 screenshot upload (handled by the API), and any other infrastructure secrets stay on the control plane — the mini-PC never sees them. The worker process talks to one network counterparty: `api.scrappy.hu`.

Usage:

```bash
# On the mini-PC, as root:
curl -fsSL https://raw.githubusercontent.com/xupegroup/scrappy-installers/main/install-worker.sh -o install-worker.sh
chmod +x install-worker.sh
sudo ./install-worker.sh
```

The script prompts for the worker token, then calls `api.scrappy.hu/v1/internal/bootstrap` to fetch the registry creds. After first install, Watchtower keeps the worker on the latest image automatically — polls every 5 minutes.

To re-run with new config (e.g. after a GHCR PAT rotation on the control plane), just run the script again with the same worker token.

### `install-runner.sh`

Provisions a self-hosted GitHub Actions runner on the production CT. See the [private repo's `docs/RUNNER_SETUP.md`](https://github.com/xupegroup/scrappy/blob/main/docs/RUNNER_SETUP.md) for the full operator playbook.

## Why a separate public repo

Mini-PCs over residential ISPs need to fetch the install script over plain HTTPS, no auth. Keeping the script here (public) while the application code stays in the private `xupegroup/scrappy` repo means:

- The bootstrap step requires zero git credentials on the new host.
- The actual worker bytes are in a private GHCR image. The script does NOT bake a PAT — it asks the control plane for a fresh one using the operator's worker token.
- Operational scripts can be reviewed by anyone considering the project; no compliance concern.

## Secrets architecture

A mini-PC ends up with three things on disk, two of which the operator never types:

| Secret | Source | Purpose |
|---|---|---|
| `WORKER_TOKEN` | typed by operator into the install prompt | Authenticates worker to the API for poll / heartbeat / result / screenshot upload |
| GHCR PAT | fetched from `/v1/internal/bootstrap` at install time | `docker login ghcr.io` so Watchtower can pull image updates |
| (none for S3) | — | Workers don't talk to S3. Screenshot bytes go to the API which uploads. |

Rotating the GHCR PAT is a control-plane operation: update `GHCR_PAT` on the prod CT, then re-run `install-worker.sh` on each mini-PC (it picks up the new value via the bootstrap call).

## Updating

Push to `main` here and the next mini-PC install will pick up the new script. Existing installs are independent — they run a copy at `/opt/scrappy/...` and only touch this repo when the operator explicitly re-runs the script.
