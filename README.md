# scrappy-installers

Public bootstrap scripts for the [Scrappy](https://scrappy.hu) infrastructure. The application code itself lives in a separate private repo — these scripts only handle initial host setup and pull pre-built images from a private container registry.

## Available scripts

### `install-worker.sh`

Provisions a Scrappy worker on a fresh mini-PC. Sets up Docker, writes the env file, generates a docker-compose with the worker container + Watchtower for auto-updates, logs in to the private GHCR, and starts everything.

Prerequisites:
- A Linux host (Ubuntu 22.04 / 24.04 tested). Root access.
- A worker token issued from the admin UI (`wk_live_…`).
- A GitHub fine-grained PAT with `read:packages` scope on the `xupegroup/scrappy-worker` package only. **Same PAT can be reused across the whole fleet** — rotate via re-running this script.
- (Optional) MinIO/S3 credentials if you want screenshot capture.

Usage:

```bash
# On the mini-PC, as root:
curl -fsSL https://raw.githubusercontent.com/xupegroup/scrappy-installers/main/install-worker.sh -o install-worker.sh
chmod +x install-worker.sh
sudo ./install-worker.sh
```

The script prompts interactively for everything it needs. After first install, Watchtower keeps the worker on the latest image automatically — pollus every 5 minutes.

To re-run with new config (e.g. rotate the PAT or change the worker name), just run the script again.

### `install-runner.sh`

Provisions a self-hosted GitHub Actions runner on the production CT. See the [private repo's `docs/RUNNER_SETUP.md`](https://github.com/xupegroup/scrappy/blob/main/docs/RUNNER_SETUP.md) for the full operator playbook.

## Why a separate public repo

Mini-PCs over residential ISPs need to fetch the install script over plain HTTPS, no auth. Keeping the script here (public) while the application code stays in the private `xupegroup/scrappy` repo means:

- The bootstrap step requires zero git credentials on the new host.
- The actual worker bytes are in a private GHCR image, pulled with a read-only PAT.
- Operational scripts can be reviewed by anyone considering the project; no compliance concern.

## Updating

Push to `main` here and the next mini-PC install will pick up the new script. Existing installs are independent — they run a copy at `/opt/scrappy/...` and only touch this repo when the operator explicitly re-runs the script.
