#!/usr/bin/env bash
#
# scrappy-firstboot — one-shot first-boot setup for a Scrappy worker.
#
#   1. wait for the network (up to ~10 min per attempt; a late-plugged
#      cable is fine, systemd retries after that)
#   2. hostname scrappy-worker-<last 6 hex of the MAC>, only while it is
#      still the installer placeholder (the API may rename it later)
#   3. Docker from the official apt repo (key shipped on the ISO)
#   4. done-marker, then hands over to scrappy-register (self-registration:
#      pairing code on the console, admin approval, token, install-worker)
#
# A failure leaves no marker; systemd retries (Restart=on-failure) and the
# next boot runs it again. Log: journalctl -u scrappy-firstboot
#
# Manual fallback (no self-registration):
#   ssh -t kevin@<ip> sudo install-worker.sh

set -euo pipefail

DONE=/var/lib/scrappy/firstboot.done
PLACEHOLDER_HOSTNAME=scrappy-worker-new
WAIT_SECONDS=600

log() { echo "scrappy-firstboot: $*"; }

# ─── 1. network ─────────────────────────────────────────────────────────
log "waiting for network"
deadline=$((SECONDS + WAIT_SECONDS))
until curl -fsS --max-time 5 -o /dev/null https://download.docker.com/linux/ubuntu/gpg; do
  if (( SECONDS >= deadline )); then
    log "no network after ${WAIT_SECONDS}s, will retry"
    exit 1
  fi
  sleep 5
done
log "network OK"

# ─── 2. hostname ────────────────────────────────────────────────────────
nic=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
if [[ -z "$nic" ]]; then
  nic=$(find /sys/class/net -maxdepth 1 -name 'en*' -printf '%f\n' | sort | head -n1)
fi
[[ -n "$nic" ]] || { log "no ethernet interface found"; exit 1; }

current=$(hostnamectl --static 2>/dev/null || cat /etc/hostname)
if [[ "$current" == "$PLACEHOLDER_HOSTNAME" ]]; then
  mac=$(tr -d ':' < "/sys/class/net/${nic}/address")
  name="scrappy-worker-${mac: -6}"
  hostnamectl set-hostname "$name"
  if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${name}/" /etc/hosts
  else
    printf '127.0.1.1 %s\n' "$name" >> /etc/hosts
  fi
  # Re-announce over DHCP so the router shows the new name.
  networkctl renew "$nic" 2>/dev/null || true
  log "hostname set to ${name} (from ${nic})"
else
  log "hostname already ${current}, leaving it"
fi

# ─── 3. Docker ──────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  log "installing Docker"
  # shellcheck source=/dev/null
  . /etc/os-release
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io \
    docker-compose-plugin docker-buildx-plugin
  systemctl enable --now docker
fi
log "$(docker --version)"

# ─── 4. marker, then self-registration ──────────────────────────────────
# agetty expands \n (hostname) and \4 (IPv4) on the login screen;
# scrappy-register replaces this with the pairing code once registered.
install -d /etc/issue.d
cat > /etc/issue.d/50-scrappy.issue <<'EOF'
Scrappy worker \n   IP: \4
Status: registering with the Scrappy API
Manual install: ssh -t kevin@\4 sudo install-worker.sh

EOF
agetty --reload 2>/dev/null || true

install -d "$(dirname "$DONE")"
date --iso-8601=seconds > "$DONE"
log "done, starting scrappy-register"
# --no-block: this unit is a oneshot; waiting for the registration loop
# would keep it "activating" until an admin approves the machine.
systemctl start --no-block scrappy-register.service
