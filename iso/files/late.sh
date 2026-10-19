#!/usr/bin/env bash
#
# late.sh — autoinstall late-command. Runs in the live installer after the
# target system is installed at /target. Installs the Scrappy first-boot
# pieces and the host policy (no release upgrades, nightly security reboot).

set -euo pipefail

SRC=/cdrom/scrappy
T=/target

# ─── Scrappy files ──────────────────────────────────────────────────────
install -D -m 0755 "${SRC}/install-worker.sh"          "${T}/usr/local/sbin/install-worker.sh"
install -D -m 0755 "${SRC}/scrappy-firstboot.sh"       "${T}/usr/local/sbin/scrappy-firstboot"
install -D -m 0644 "${SRC}/scrappy-firstboot.service"  "${T}/etc/systemd/system/scrappy-firstboot.service"
install -D -m 0644 "${SRC}/docker-archive-keyring.asc" "${T}/etc/apt/keyrings/docker.asc"
install -d -m 0755 "${T}/var/lib/scrappy"
curtin in-target --target="$T" -- systemctl enable scrappy-firstboot.service

# ─── network: DHCP on every wired port, none of them blocks boot ────────
# Written only into /target: no netplan apply runs in the installer (that
# raced with disk probing). Replaces whatever the installer generated, which
# names just the interfaces seen during install.
rm -f "${T}"/etc/netplan/*.yaml
install -D -m 0600 /dev/stdin "${T}/etc/netplan/01-scrappy.yaml" <<'EOF'
# Scrappy worker: DHCP on every wired port. optional: true -> a port without
# a cable never delays boot; scrappy-firstboot waits for the network itself.
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      optional: true
EOF
# cloud-init must not write its own netplan config on first boot.
install -d "${T}/etc/cloud/cloud.cfg.d"
printf 'network: {config: disabled}\n' > "${T}/etc/cloud/cloud.cfg.d/99-scrappy-disable-network.cfg"

# ─── never offer 26.04 ──────────────────────────────────────────────────
RU="${T}/etc/update-manager/release-upgrades"
if [[ -f "$RU" ]]; then
  sed -i 's/^Prompt=.*/Prompt=never/' "$RU"
  grep -q '^Prompt=never$' "$RU" || printf 'Prompt=never\n' >> "$RU"
else
  install -d "${T}/etc/update-manager"
  printf '[DEFAULT]\nPrompt=never\n' > "$RU"
fi

# ─── unattended-upgrades, reboot at 04:00 ───────────────────────────────
cat > "${T}/etc/apt/apt.conf.d/20auto-upgrades" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > "${T}/etc/apt/apt.conf.d/52scrappy" <<'EOF'
// Scrappy worker: stateless, drains in-flight jobs on SIGTERM
// (compose stop_grace_period: 40s), so a nightly reboot is safe.
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

# ─── keep the hostname scrappy-firstboot sets ───────────────────────────
install -d "${T}/etc/cloud/cloud.cfg.d"
printf 'preserve_hostname: true\n' > "${T}/etc/cloud/cloud.cfg.d/99-scrappy-hostname.cfg"
