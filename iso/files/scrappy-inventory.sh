#!/usr/bin/env bash
#
# scrappy-inventory — collect the host inventory of a Scrappy worker.
#
# Writes /opt/scrappy/host-info/inventory.json (atomically, 0644). The
# worker container mounts /opt/scrappy/host-info read-only and sends the
# file with its heartbeat whenever it changes; scrappy-register sends it
# with the registration request. It runs on the HOST because the
# container would only see its own hostname and overlay disk.
#
# The output must pass the API's strict schema (workerInventorySchema in
# @scrappy/shared): known keys only, printable strings with length limits,
# integers, at most 16 disks / 8 NICs / 8 IPv4 each. Anything the API
# would reject is dropped or clipped here.
#
#   scrappy-inventory           write the file
#   scrappy-inventory --print   write the file and print it
#   scrappy-inventory --stdout  print only (no write, no root needed)

set -euo pipefail

OUT_DIR=/opt/scrappy/host-info
# Input paths are overridable only so the tests can feed hostile values.
DMI_DIR=${SCRAPPY_INV_DMI_DIR:-/sys/class/dmi/id}
OS_RELEASE=${SCRAPPY_INV_OS_RELEASE:-/etc/os-release}
MACHINE_ID_FILE=${SCRAPPY_INV_MACHINE_ID:-/etc/machine-id}
OUT_FILE="${OUT_DIR}/inventory.json"
MAX_BYTES=16384

mode='write'
case "${1:-}" in
  "") ;;
  --print) mode=print ;;
  --stdout) mode=stdout ;;
  *) echo "usage: scrappy-inventory [--print|--stdout]" >&2; exit 2 ;;
esac

command -v jq >/dev/null || { echo "scrappy-inventory: jq missing" >&2; exit 1; }

read_file() { if [[ -r "$1" ]]; then tr -d '\0' < "$1" || true; fi; }

hostname=$(hostnamectl --static 2>/dev/null || read_file /etc/hostname)
machine_id=$(read_file "$MACHINE_ID_FILE" | tr -d '[:space:]')
mem_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
# shellcheck source=/dev/null
os_name=$( (. "$OS_RELEASE" 2>/dev/null && printf '%s' "${NAME:-}") || true)
# shellcheck source=/dev/null
os_version=$( (. "$OS_RELEASE" 2>/dev/null && printf '%s' "${VERSION:-}") || true)
docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)

lscpu_json=$(lscpu -J 2>/dev/null || echo '{}')
lsblk_json=$(lsblk -J -b -d -o NAME,MODEL,SIZE,ROTA,TYPE 2>/dev/null || echo '{}')
ip_json=$(ip -j addr 2>/dev/null || echo '[]')

inventory=$(jq -n -c \
  --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg hostname "$hostname" \
  --arg machine_id "$machine_id" \
  --arg vendor "$(read_file "$DMI_DIR/sys_vendor")" \
  --arg product "$(read_file "$DMI_DIR/product_name")" \
  --arg bios "$(read_file "$DMI_DIR/bios_version")" \
  --arg mem_kb "${mem_kb:-}" \
  --arg os_name "$os_name" \
  --arg os_version "$os_version" \
  --arg kernel "$(uname -r)" \
  --arg docker_version "$docker_version" \
  --argjson lscpu "$lscpu_json" \
  --argjson lsblk "$lsblk_json" \
  --argjson ip "$ip_json" '
  # Printable text only (no C0/C1 controls), trimmed, clipped to $n chars.
  def clean($n): tostring | explode
    | map(select(. >= 32 and (. < 127 or . > 159))) | implode
    | gsub("^\\s+|\\s+$"; "") | .[0:$n];
  def int_or_null: (tostring | tonumber? // null) | if . == null then null else floor end;
  def cpu($field): ($lscpu.lscpu // []) | map(select(.field == $field)) | first | .data // null;
  # Drop nulls, empty strings, empty arrays and empty objects, recursively.
  def prune: walk(
    if type == "object" then with_entries(select(.value != null and .value != "" and .value != [] and .value != {}))
    elif type == "array" then map(select(. != null and . != "" and . != {}))
    else . end);

  (cpu("Socket(s):") | int_or_null) as $sockets
  | (cpu("Core(s) per socket:") | int_or_null) as $cps
  | {
      collected_at: $collected_at,
      hostname: ($hostname | clean(255)),
      machine_id: ($machine_id | if test("^[0-9a-f]{32}$") then . else null end),
      system: {
        vendor: ($vendor | clean(255)),
        product: ($product | clean(255)),
        bios_version: ($bios | clean(255))
      },
      cpu: {
        model: (cpu("Model name:") | if . == null then null else clean(255) end),
        cores: (if $sockets != null and $cps != null then ([$sockets * $cps, 4096] | min) else null end),
        threads: (cpu("CPU(s):") | int_or_null | if . == null then null else ([., 8192] | min) end)
      },
      memory_total_mb: ($mem_kb | int_or_null | if . == null then null else (. / 1024 | floor) end),
      disks: [
        ($lsblk.blockdevices // [])[]
        | select(.type == "disk")
        | select((.name // "") | test("^(loop|ram|zram|sr|fd)") | not)
        | {
            name: (.name | clean(64)),
            model: (.model | if . == null then null else clean(255) end),
            size_bytes: (.size | int_or_null),
            rotational: (.rota | if type == "boolean" then . elif . == "1" or . == 1 then true elif . == "0" or . == 0 then false else null end)
          }
      ][0:16],
      network: [
        $ip[]
        | select(.link_type == "ether")
        | select((.ifname // "") | test("^(en|eth|wl)"))
        | select((.address // "") | test("^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$"))
        | {
            name: (.ifname | clean(64)),
            mac: (.address | ascii_downcase),
            ipv4: ([(.addr_info // [])[] | select(.family == "inet") | .local][0:8])
          }
      ][0:8],
      os: {
        name: ($os_name | clean(64)),
        version: ($os_version | clean(64)),
        kernel: ($kernel | clean(128))
      },
      docker_version: ($docker_version | clean(64))
    }
  | prune
')

if (( ${#inventory} > MAX_BYTES )); then
  echo "scrappy-inventory: inventory is ${#inventory} bytes (limit ${MAX_BYTES}), not written" >&2
  exit 1
fi

if [[ $mode == stdout ]]; then
  printf '%s\n' "$inventory"
  exit 0
fi

install -d -m 0755 "$OUT_DIR"
tmp=$(mktemp "${OUT_DIR}/.inventory.XXXXXX")
printf '%s\n' "$inventory" > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$OUT_FILE"
[[ $mode == print ]] && printf '%s\n' "$inventory"
exit 0
