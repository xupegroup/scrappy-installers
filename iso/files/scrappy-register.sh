#!/usr/bin/env bash
#
# scrappy-register — zero-touch worker registration.
#
# Started by scrappy-firstboot once the host has network, its hostname and
# Docker. It then:
#   1. generates a 256-bit secret once (/var/lib/scrappy/claim_secret, 0600)
#      and registers with the API, sending only its sha256 + the inventory;
#   2. shows the server-generated pairing code on the console login screen;
#   3. polls the claim endpoint until an admin approves (or rejects) it in
#      /admin/workers. On approval the response carries the worker token,
#      exactly once;
#   4. runs install-worker.sh with that token (the usual bootstrap), then
#      deletes the secret.
#
# The secret and the token never appear on a command line or in the log:
# request bodies go to curl on stdin, values reach jq via the environment,
# and the token is written straight to a root-only file.
#
# Terminal states leave a marker so systemd does not restart the loop:
#   register.done      worker installed
#   register.stopped   rejected, token already claimed, or installed by hand
#
# Config: /etc/scrappy/register.env (API_BASE_URL), written at ISO build.
# Log:    journalctl -u scrappy-register

set -euo pipefail

STATE=/var/lib/scrappy
SECRET_FILE="${STATE}/claim_secret"
REG_FILE="${STATE}/registration.json"
TOKEN_FILE="${STATE}/worker_token"
DONE="${STATE}/register.done"
STOPPED="${STATE}/register.stopped"
WORKER_ENV=/opt/scrappy/worker.env
ISSUE=/etc/issue.d/50-scrappy.issue
INSTALL_WORKER=/usr/local/sbin/install-worker.sh
INVENTORY=/usr/local/sbin/scrappy-inventory
INVENTORY_FILE=/opt/scrappy/host-info/inventory.json

API_BASE_URL=${API_BASE_URL:-https://api.scrappy.hu}
API_BASE_URL=${API_BASE_URL%/}

PAIRING_RE='^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$'
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

log() { echo "scrappy-register: $*"; }

[[ $EUID -eq 0 ]] || { log "must run as root"; exit 1; }
[[ "$API_BASE_URL" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/.*)?$ ]] \
  || { log "invalid API_BASE_URL"; exit 1; }
command -v jq >/dev/null || { log "jq missing"; exit 1; }

umask 077
install -d -m 0700 "$STATE"
WORK=$(mktemp -d /run/scrappy-register.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
RESP="${WORK}/response"
HDRS="${WORK}/headers"

# ─── console (agetty expands \n = hostname, \4 = IPv4) ──────────────────
# Only fixed text and values checked against strict patterns go in here.
show() {  # status line, [pairing code]
  install -d /etc/issue.d
  {
    printf 'Scrappy worker \\n   IP: \\4\n'
    printf 'Status: %s\n' "$1"
    if [[ -n "${2:-}" ]]; then
      printf 'Pairing code: %s   (must match the code in /admin/workers)\n' "$2"
    fi
    if [[ "$1" != "worker installed and running" ]]; then
      printf 'Manual install: ssh -t kevin@\\4 sudo install-worker.sh\n'
    fi
    printf '\n'
  } > "${ISSUE}.tmp"
  chmod 0644 "${ISSUE}.tmp"
  mv -f "${ISSUE}.tmp" "$ISSUE"
  agetty --reload 2>/dev/null || true
}

# ─── HTTP: body on stdin, response in $RESP / $HDRS, prints the status ──
post() {  # path
  local code
  code=$(curl -sS --max-time 30 -o "$RESP" -D "$HDRS" -w '%{http_code}' \
    -H 'content-type: application/json' --data-binary @- \
    "${API_BASE_URL}$1" 2>/dev/null) || code=000
  printf '%s' "$code"
}

retry_after() {  # seconds from Retry-After, clamped to [30, 3600]
  local s
  s=$(awk 'tolower($1)=="retry-after:" {gsub(/\r/,"",$2); print $2; exit}' "$HDRS" 2>/dev/null || true)
  [[ "$s" =~ ^[0-9]+$ ]] || s=60
  (( s < 30 )) && s=30
  (( s > 3600 )) && s=3600
  printf '%s' "$s"
}

backoff=30
failed() {  # reason: wait with doubling backoff (30 s .. 10 min)
  log "$1, retrying in ${backoff}s"
  sleep "$backoff"
  backoff=$(( backoff * 2 > 600 ? 600 : backoff * 2 ))
}

stop_with() {  # marker reason, console status
  printf '%s %s\n' "$(date --iso-8601=seconds)" "$1" > "$STOPPED"
  show "$2"
  log "stopped: $1"
  exit 0
}

ensure_secret() {
  if [[ ! -s "$SECRET_FILE" ]]; then
    openssl rand -hex 32 > "${SECRET_FILE}.tmp"
    mv -f "${SECRET_FILE}.tmp" "$SECRET_FILE"
    rm -f "$REG_FILE"
    log "generated a new claim secret"
  fi
  [[ "$(tr -d '\n' < "$SECRET_FILE")" =~ ^[0-9a-f]{64}$ ]] \
    || { log "claim secret is malformed, replacing it"; rm -f "$SECRET_FILE"; ensure_secret; }
}

register() {
  local key_hash inventory code with_inventory=${1:-yes}
  key_hash=$(tr -d '\n' < "$SECRET_FILE" | sha256sum | cut -d' ' -f1)
  inventory='{}'
  if [[ $with_inventory == yes ]] && "$INVENTORY" >/dev/null 2>&1 && [[ -s "$INVENTORY_FILE" ]]; then
    inventory=$(cat "$INVENTORY_FILE")
  fi
  code=$(KEY_HASH="$key_hash" INV="$inventory" HOST="$(hostnamectl --static 2>/dev/null || cat /etc/hostname)" \
    jq -n '{hostname: env.HOST, key_hash: env.KEY_HASH, inventory: (env.INV | fromjson)}' \
    | post /v1/worker-registrations)

  case "$code" in
    200|201)
      local id pairing
      id=$(jq -r '.registration_id // empty' "$RESP")
      pairing=$(jq -r '.pairing_code // empty' "$RESP")
      if [[ ! "$id" =~ $UUID_RE || ! "$pairing" =~ $PAIRING_RE ]]; then
        failed "unexpected registration response"; return
      fi
      jq -n --arg id "$id" --arg pairing "$pairing" '{registration_id: $id, pairing_code: $pairing}' > "$REG_FILE"
      backoff=30
      show "waiting for approval" "$pairing"
      log "registered (id ${id}, pairing code ${pairing}); waiting for approval"
      ;;
    400|413)
      if [[ $with_inventory == yes ]]; then
        log "registration rejected with HTTP ${code}, retrying without inventory"
        register no
      else
        failed "registration rejected with HTTP ${code}"
      fi
      ;;
    404)
      show "self-registration is switched off on the server (use the manual install)"
      log "self-registration is off (HTTP 404); checking again in 10 minutes"
      sleep 600
      ;;
    409)
      # This secret already belongs to a decided registration: start over.
      log "secret already used (HTTP 409), generating a new one"
      rm -f "$SECRET_FILE" "$REG_FILE"
      ;;
    429)
      local wait; wait=$(retry_after)
      log "rate limited (HTTP 429), waiting ${wait}s"
      sleep "$wait"
      ;;
    *)
      failed "registration failed (HTTP ${code})"
      ;;
  esac
}

claim() {
  local id pairing code interval
  id=$(jq -r '.registration_id // empty' "$REG_FILE" 2>/dev/null || true)
  pairing=$(jq -r '.pairing_code // empty' "$REG_FILE" 2>/dev/null || true)
  if [[ ! "$id" =~ $UUID_RE ]]; then rm -f "$REG_FILE"; return; fi

  code=$(SECRET="$(tr -d '\n' < "$SECRET_FILE")" jq -n '{claim_secret: env.SECRET}' \
    | post "/v1/worker-registrations/${id}/claim")

  case "$code" in
    202)
      backoff=30
      interval=$(jq -r '.retry_after_seconds // 30' "$RESP" 2>/dev/null || echo 30)
      [[ "$interval" =~ ^[0-9]+$ ]] || interval=30
      (( interval < 10 )) && interval=10
      (( interval > 300 )) && interval=300
      sleep $(( interval + RANDOM % 10 ))
      ;;
    200)
      if jq -r '.worker_token // empty' "$RESP" > "$TOKEN_FILE" \
         && [[ "$(cat "$TOKEN_FILE")" =~ ^wk_live_[A-Za-z0-9]+$ ]]; then
        rm -f "$RESP"
        log "approved; worker token received"
        show "approved, installing the worker"
      else
        rm -f "$TOKEN_FILE" "$RESP"
        failed "approved, but the response had no valid token"
      fi
      ;;
    404)
      # Expired (pending > 24 h or approval not claimed in 7 days):
      # register again with the same secret, which gets a new pairing code.
      log "registration expired or unknown (HTTP 404), registering again"
      rm -f "$REG_FILE"
      ;;
    409)
      stop_with "token-already-claimed" \
        "token was already claimed and is lost; rotate it in /admin/workers and use the manual install"
      ;;
    410)
      stop_with "rejected" "registration REJECTED by an admin; reinstall or use the manual install"
      ;;
    429)
      local wait; wait=$(retry_after)
      log "rate limited (HTTP 429), waiting ${wait}s"
      sleep "$wait"
      ;;
    *)
      [[ -n "$pairing" ]] && show "waiting for approval (server unreachable, retrying)" "$pairing"
      failed "claim failed (HTTP ${code})"
      ;;
  esac
}

install_worker() {
  log "running install-worker.sh"
  if WORKER_TOKEN="$(cat "$TOKEN_FILE")" API_BASE_URL="$API_BASE_URL" "$INSTALL_WORKER" < /dev/null; then
    rm -f "$TOKEN_FILE" "$SECRET_FILE"
    date --iso-8601=seconds > "$DONE"
    show "worker installed and running"
    log "done: worker installed"
    exit 0
  fi
  # Keep the token and retry only the install, never the claim.
  failed "install-worker.sh failed"
}

# ─── main loop ──────────────────────────────────────────────────────────
log "API ${API_BASE_URL}"
while true; do
  [[ -f "$DONE" ]] && exit 0
  if [[ -s "$TOKEN_FILE" ]]; then
    install_worker
    continue
  fi
  if [[ -f "$WORKER_ENV" ]]; then
    stop_with "installed-manually" "worker installed manually; self-registration not needed"
  fi
  ensure_secret
  if [[ ! -s "$REG_FILE" ]]; then
    register
  else
    claim
  fi
done
