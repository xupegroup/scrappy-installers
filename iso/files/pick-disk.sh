#!/usr/bin/env bash
#
# pick-disk.sh — autoinstall early-command: choose the internal target disk.
#
# Runs in the live installer before any storage action. It edits the RUNNING
# installer's config, /autoinstall.yaml in the live root filesystem: subiquity
# (24.04.5, server.py select_autoinstall) copies the nocloud user-data there
# and re-reads it after early-commands. The seed on the install media
# (/cdrom/scrappy/user-data) is read-only and is never touched. The chosen
# disk replaces __SCRAPPY_TARGET_DISK__; any failure here stops the install
# BEFORE a disk is touched.
#
# Candidates: whole disks, not USB, not removable, not the install media,
# not zram/loop, >= 16 GB. Exactly one -> use it. Several -> use the single
# NVMe if there is exactly one. Otherwise abort.
#
# Mode (kernel cmdline scrappy.mode=, set by the ISO boot menu):
#   fresh     -> refuse a disk that already holds a Linux install (LVM PV /
#                ubuntu-vg, Linux partition type, ext2/3/4, xfs, btrfs, swap,
#                md RAID member). Empty disks and factory Windows (NTFS) disks
#                are installed onto. A pendrive left plugged in therefore can
#                never wipe a running worker.
#   reinstall -> the disk is overwritten, whatever is on it
#   anything else -> abort

set -euo pipefail

CFG=/autoinstall.yaml            # live installer copy, NOT the /cdrom seed
PLACEHOLDER=__SCRAPPY_TARGET_DISK__
MIN_BYTES=$((16 * 1024 * 1024 * 1024))

LINUX_FSTYPE_RE='^(ext2|ext3|ext4|xfs|btrfs|swap|LVM2_member|linux_raid_member)$'
# GPT: Linux filesystem, LVM, swap, RAID, /home, root (x86-64), /srv.
# MBR: 0x83 Linux, 0x8e LVM, 0x82 swap, 0xfd RAID.
LINUX_PARTTYPES=" 0fc63daf-8483-4772-8e79-3d69d8477de4 e6d6d379-f507-44c2-a23c-238f2a3df928 \
0657fd6d-a4ab-43c4-84e5-0933c84b4f4f a19d880f-05fc-4d3b-a006-743f0f84911e \
933ac7e1-2eb4-4f13-b844-0e14e2aef915 4f68bce3-e8cd-4db1-96e7-fbcaf984b709 \
3b8f8425-20e0-4f3b-907f-1a25a76f98e8 0x83 0x8e 0x82 0xfd "

say() {
  echo "scrappy-pick-disk: $*" >&2
  echo "scrappy-pick-disk: $*" > /dev/console 2>/dev/null || true
}

show_disks() {
  lsblk -o NAME,SIZE,TYPE,TRAN,RM,FSTYPE,MODEL >&2 || true
  lsblk -o NAME,SIZE,TYPE,TRAN,RM,FSTYPE,MODEL > /dev/console 2>/dev/null || true
}

die() {
  say "HIBA: $*"
  say "A telepites leallt, egyetlen lemez sem lett torolve."
  show_disks
  exit 1
}

# Print "node:reason" for every Linux trace on the disk (and its children).
linux_traces() {
  local dev=$1 line node fstype parttype probed
  local re='^NAME="([^"]*)" FSTYPE="([^"]*)" PARTTYPE="([^"]*)"$'
  while IFS= read -r line; do
    [[ "$line" =~ $re ]] || continue
    node=${BASH_REMATCH[1]} fstype=${BASH_REMATCH[2]} parttype=${BASH_REMATCH[3],,}
    # lsblk relies on the udev db; probe directly as well.
    probed=$(blkid -p -s TYPE -o value "$node" 2>/dev/null || true)
    for t in "$fstype" "$probed"; do
      [[ -n "$t" && "$t" =~ $LINUX_FSTYPE_RE ]] && echo "${node}:${t}"
    done
    if [[ -n "$parttype" && "$LINUX_PARTTYPES" == *" ${parttype} "* ]]; then
      echo "${node}:parttype=${parttype}"
    fi
  done < <(lsblk -nbpP -o NAME,FSTYPE,PARTTYPE "$dev")
  # LVM PVs on the disk or its partitions (e.g. ubuntu-vg).
  if command -v pvs >/dev/null 2>&1; then
    pvs --noheadings -o pv_name,vg_name 2>/dev/null \
      | awk -v d="$dev" 'index($1, d) == 1 { print $1 ":vg=" $2 }'
  fi
}

# ─── the config we edit must be the live, writable copy ─────────────────
cfg_real=$(readlink -f "$CFG" 2>/dev/null || echo "$CFG")
case "$cfg_real" in
  /cdrom/*) die "${CFG} a telepito mediara mutat (${cfg_real}), az csak olvashato" ;;
esac
[[ -f "$CFG" ]] || die "${CFG} nem letezik a live rendszerben"
[[ -w "$CFG" ]] || die "${CFG} nem irhato"
grep -q "$PLACEHOLDER" "$CFG" || die "${CFG} nem tartalmazza a ${PLACEHOLDER} helyorzot"

# ─── mode ───────────────────────────────────────────────────────────────
mode=""
read -r -a cmdline < /proc/cmdline
for arg in "${cmdline[@]}"; do
  case "$arg" in
    scrappy.mode=*) mode=${arg#scrappy.mode=} ;;
  esac
done
case "$mode" in
  fresh|reinstall) say "mode: ${mode}" ;;
  *) die "ismeretlen vagy hianyzo scrappy.mode='${mode}' (fresh|reinstall)" ;;
esac

# ─── install media (never a candidate) ──────────────────────────────────
media_disk=""
media_src=$(findmnt -no SOURCE /cdrom 2>/dev/null || true)
if [[ -n "$media_src" ]]; then
  media_disk=$(lsblk -no PKNAME "$media_src" 2>/dev/null | head -n1 || true)
  [[ -n "$media_disk" ]] || media_disk=$(basename "$media_src")
fi
say "install media: ${media_disk:-ismeretlen}"

# ─── candidates ─────────────────────────────────────────────────────────
candidates=()
nvme=()
pair_re='^NAME="([^"]*)" TYPE="([^"]*)" TRAN="([^"]*)" RM="([^"]*)" SIZE="([^"]*)"$'
while IFS= read -r line; do
  [[ "$line" =~ $pair_re ]] || continue
  name=${BASH_REMATCH[1]} type=${BASH_REMATCH[2]} tran=${BASH_REMATCH[3]}
  rm_flag=${BASH_REMATCH[4]} size=${BASH_REMATCH[5]}
  [[ "$type" == disk ]] || continue
  [[ "$name" == zram* || "$name" == loop* ]] && continue
  [[ "$name" == "$media_disk" ]] && continue
  [[ "$tran" == usb ]] && continue
  [[ "$rm_flag" == 1 ]] && continue
  (( size >= MIN_BYTES )) || continue
  candidates+=("$name")
  if [[ "$tran" == nvme || "$name" == nvme* ]]; then
    nvme+=("$name")
  fi
done < <(lsblk -dnbP -o NAME,TYPE,TRAN,RM,SIZE)

say "jeloltek: ${candidates[*]:-nincs}"

if (( ${#candidates[@]} == 1 )); then
  target=${candidates[0]}
elif (( ${#candidates[@]} > 1 && ${#nvme[@]} == 1 )); then
  target=${nvme[0]}
elif (( ${#candidates[@]} == 0 )); then
  die "nincs belso lemez (USB-s lemezre soha nem telepitunk)"
else
  die "tobb belso lemez, nem egyertelmu: ${candidates[*]}"
fi

dev=/dev/${target}

# ─── fresh mode: refuse a disk with an existing Linux install ───────────
if [[ "$mode" == fresh ]]; then
  traces=$(linux_traces "$dev" | sort -u | tr '\n' ' ')
  if [[ -n "$traces" ]]; then
    say "Linux nyomok: ${traces}"
    die "A lemezen (${dev}) mar van Linux-telepites. Ujratelepiteshez valaszd a masodik menupontot."
  fi
  say "${dev}: nincs rajta Linux (ures vagy pl. gyari Windows), telepitheto"
fi

sed -i "s#${PLACEHOLDER}#${dev}#" "$CFG"
if grep -q "$PLACEHOLDER" "$CFG"; then
  die "a helyorzo csereje nem sikerult"
fi
say "celmeghajto: ${dev} (mode: ${mode})"
