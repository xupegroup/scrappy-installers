#!/usr/bin/env bash
#
# build.sh — build the Scrappy worker autoinstall ISO. Runs INSIDE the
# scrappy-iso-builder container (see Makefile):
#   /src   repo (read-only)
#   /build cache + work dir
#   /out   finished ISOs
#
#   build.sh iso    download + verify Ubuntu ISO, render, repack
#   build.sh lint   shellcheck + render with a dummy hash (no ISO needed)

set -euo pipefail

UBUNTU_VERSION=24.04.5
ISO_NAME="ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
UBUNTU_KEY_FPR=843938DF228D22F7B3742BC0D94AA3F0EFE21092   # Ubuntu CD Image Automatic Signing Key (2012)
DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88   # Docker Release (CE deb)

SRC=/src
ISO_DIR="${SRC}/iso"
CACHE=/build/cache
OUT=/out
GIT_REV=${GIT_REV:-unknown}

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ─── helpers ────────────────────────────────────────────────────────────
key_fpr() {  # primary key fingerprint of an armored key file
  gpg --show-keys --with-colons "$1" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}'
}

download() {  # url dest — skip if dest exists
  [[ -f "$2" ]] && return 0
  curl -fSL --retry 3 -o "$2.part" "$1"
  mv "$2.part" "$2"
}

fetch_ubuntu_iso() {
  local base
  mkdir -p "$CACHE"
  for base in "https://releases.ubuntu.com/${UBUNTU_VERSION}" \
              "https://old-releases.ubuntu.com/releases/${UBUNTU_VERSION}"; do
    if curl -fsS -o "${CACHE}/SHA256SUMS" "${base}/SHA256SUMS" \
       && curl -fsS -o "${CACHE}/SHA256SUMS.gpg" "${base}/SHA256SUMS.gpg"; then
      download "${base}/${ISO_NAME}" "${CACHE}/${ISO_NAME}"
      return 0
    fi
  done
  fail "Ubuntu ${UBUNTU_VERSION} not found on releases/old-releases"
}

verify_ubuntu_iso() {
  local gnupg
  [[ "$(key_fpr "${ISO_DIR}/keys/ubuntu-cdimage.asc")" == "$UBUNTU_KEY_FPR" ]] \
    || fail "iso/keys/ubuntu-cdimage.asc fingerprint mismatch"
  gnupg=$(mktemp -d)
  GNUPGHOME=$gnupg gpg -q --import "${ISO_DIR}/keys/ubuntu-cdimage.asc" 2>/dev/null
  GNUPGHOME=$gnupg gpg --status-fd 1 --verify "${CACHE}/SHA256SUMS.gpg" "${CACHE}/SHA256SUMS" 2>/dev/null \
    | grep -q "VALIDSIG ${UBUNTU_KEY_FPR}" || fail "SHA256SUMS signature invalid"
  rm -rf "$gnupg"
  (cd "$CACHE" && grep " \*${ISO_NAME}\$" SHA256SUMS | sha256sum -c --quiet -) \
    || fail "${ISO_NAME} checksum mismatch"
  ok "Ubuntu ISO signature + checksum OK"
}

load_password_hash() {
  if [[ -z "${PASSWORD_HASH:-}" ]]; then
    local cfg="${ISO_DIR}/config.local"
    [[ -f "$cfg" ]] || fail "missing iso/config.local (copy iso/config.local.example, run: make passwd-hash)"
    PASSWORD_HASH=$(sed -n "s/^PASSWORD_HASH=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}\$/\1/p" "$cfg")
  fi
  # shellcheck disable=SC2016  # literal crypt prefixes, not expansions
  [[ "$PASSWORD_HASH" == '$y$'* || "$PASSWORD_HASH" == '$6$'* ]] \
    || fail "PASSWORD_HASH must be a yescrypt (\$y\$) or sha512 (\$6\$) crypt hash"
  [[ "$PASSWORD_HASH" == *REPLACE_ME* ]] && fail "PASSWORD_HASH is still the example value"
  export PASSWORD_HASH
}

render_autoinstall() {  # dest
  python3 - "${ISO_DIR}/autoinstall.yaml.tpl" "${ISO_DIR}/keys/authorized_keys" "$1" <<'PY'
import os, sys, yaml

tpl, keys_file, dest = sys.argv[1:4]
doc = yaml.safe_load(open(tpl))
ai = doc["autoinstall"]

# authorized_keys: drop comments and blank lines; one list item per key.
keys = []
for raw in open(keys_file):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if not line.startswith(("ssh-", "sk-ssh-", "ecdsa-", "sk-ecdsa-")):
        sys.exit(f"authorized_keys: not a public key line: {line[:40]}...")
    keys.append(line)
if not keys:
    sys.exit("authorized_keys: no keys found")

if ai["ssh"]["authorized-keys"] != ["@SSH_KEYS@"]:
    sys.exit("template: ssh.authorized-keys must be exactly one item \"@SSH_KEYS@\"")
ai["ssh"]["authorized-keys"] = keys

if ai["identity"]["password"] != "@PASSWORD_HASH@":
    sys.exit("template: identity.password must be \"@PASSWORD_HASH@\"")
ai["identity"]["password"] = os.environ["PASSWORD_HASH"]

if list(doc) != ["autoinstall"]:
    sys.exit("template: 'autoinstall' must be the only top-level key")
out = "#cloud-config\n" + yaml.safe_dump(doc, sort_keys=False, width=1000)
if "@SSH_KEYS@" in out or "@PASSWORD_HASH@" in out:
    sys.exit("render: build placeholder left in output")
if "__SCRAPPY_TARGET_DISK__" not in out:
    sys.exit("render: install-time disk placeholder missing")
yaml.safe_load(out)
open(dest, "w").write(out)
print(f"rendered {dest}: {len(keys)} SSH key(s)")
PY
}

check_grub() {  # exactly the two Scrappy entries carry the nocloud seed
  python3 - "${ISO_DIR}/grub.cfg" <<'PY'
import re, sys
cfg = open(sys.argv[1]).read()
entries = re.findall(r'menuentry\s+"([^"]+)"\s*\{(.*?)\n\}', cfg, re.S)
seed = r"autoinstall ds=nocloud\;s=/cdrom/scrappy/ scrappy.mode="
with_seed = [t for t, body in entries if seed in body]
if len(with_seed) != 2:
    sys.exit(f"grub.cfg: expected 2 entries with the nocloud seed, found {len(with_seed)}")
for t, body in entries:
    if seed not in body and ("autoinstall" in body or "ds=nocloud" in body):
        sys.exit(f"grub.cfg: non-Scrappy entry '{t}' references autoinstall")
print(f"grub.cfg OK: seed in {with_seed}")
PY
}

stage_files() {  # work dir
  local w=$1
  rm -rf "$w"
  mkdir -p "${w}/scrappy"
  check_grub
  # nocloud seed: user-data + (empty) meta-data, read via ds=nocloud;s=/cdrom/scrappy/
  render_autoinstall "${w}/scrappy/user-data"
  : > "${w}/scrappy/meta-data"
  cp "${ISO_DIR}/grub.cfg" "${w}/grub.cfg"
  cp "${ISO_DIR}/files/pick-disk.sh" "${ISO_DIR}/files/late.sh" \
     "${ISO_DIR}/files/scrappy-firstboot.sh" "${ISO_DIR}/files/scrappy-firstboot.service" \
     "${ISO_DIR}/files/docker-archive-keyring.asc" "${SRC}/install-worker.sh" \
     "${w}/scrappy/"
  [[ "$(key_fpr "${w}/scrappy/docker-archive-keyring.asc")" == "$DOCKER_KEY_FPR" ]] \
    || fail "docker-archive-keyring.asc fingerprint mismatch"
  ok "staged files in ${w}"
}

shellcheck_all() {
  shellcheck "${ISO_DIR}/build.sh" "${ISO_DIR}"/files/*.sh "${SRC}/install-worker.sh"
  ok "shellcheck OK"
}

# ─── commands ───────────────────────────────────────────────────────────
cmd=${1:-iso}
case "$cmd" in
  lint)
    shellcheck_all
    # shellcheck disable=SC2016  # literal dummy hash
    PASSWORD_HASH='$y$j9T$lintlintlintlintlint$lintlintlintlintlintlintlintlintlin'
    export PASSWORD_HASH
    stage_files /build/lint
    ;;
  iso)
    shellcheck_all
    load_password_hash
    step "Fetching Ubuntu ${UBUNTU_VERSION}"
    fetch_ubuntu_iso
    verify_ubuntu_iso
    step "Staging files"
    W=/build/work
    stage_files "$W"
    # Keep casper's media check happy: update the grub.cfg line in md5sum.txt.
    xorriso -indev "${CACHE}/${ISO_NAME}" -osirrox on \
      -extract /md5sum.txt "${W}/md5sum.txt" >/dev/null 2>&1
    chmod u+w "${W}/md5sum.txt"
    new_md5=$(md5sum "${W}/grub.cfg" | cut -d' ' -f1)
    sed -i "s#^[0-9a-f]\{32\}  ./boot/grub/grub.cfg\$#${new_md5}  ./boot/grub/grub.cfg#" "${W}/md5sum.txt"
    grep -q "^${new_md5}  ./boot/grub/grub.cfg\$" "${W}/md5sum.txt" || fail "md5sum.txt update failed"

    # subiquity 24.04 would use a root /autoinstall.yaml even from the manual
    # entry; the stock ISO has none and we never add one.
    if xorriso -indev "${CACHE}/${ISO_NAME}" -find /autoinstall.yaml 2>/dev/null | grep -q autoinstall; then
      fail "source ISO unexpectedly contains /autoinstall.yaml"
    fi

    step "Repacking ISO"
    mkdir -p "$OUT"
    out_iso="${OUT}/scrappy-worker-${UBUNTU_VERSION}-${GIT_REV}.iso"
    rm -f "$out_iso"
    xorriso -indev "${CACHE}/${ISO_NAME}" -outdev "$out_iso" \
      -map "${W}/grub.cfg" /boot/grub/grub.cfg \
      -map "${W}/md5sum.txt" /md5sum.txt \
      -map "${W}/scrappy" /scrappy \
      -boot_image any replay
    if xorriso -indev "$out_iso" -find /autoinstall.yaml 2>/dev/null | grep -q autoinstall; then
      fail "output ISO has a root /autoinstall.yaml"
    fi
    (cd "$OUT" && sha256sum "$(basename "$out_iso")" > "$(basename "$out_iso").sha256")
    ok "built ${out_iso#/out/}"
    ;;
  *)
    fail "usage: build.sh [iso|lint]"
    ;;
esac
