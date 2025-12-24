#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "[FAIL] line=$LINENO cmd=$BASH_COMMAND" >&2' ERR

# ==========================================================
# NorthAfrica Setup Installer (Encrypted Payload Bootstrap)
# - IPv4-only registration check
# - Downloads north.enc + sha256 (cache-bust)
# - Verifies sha256
# - Fetches AES key from KEY_URL (allowed VPS only)
# - Decrypts + extracts payload
# - Serves extracted payload via local HTTP
# - Runs premium.sh with REPO_URL pointing to local server
# ==========================================================

# ====== CONFIG (override via env) ======
REG_URL="${REG_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-public/main/register}"

ENC_URL="${ENC_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.enc}"
SHA_URL="${SHA_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.enc.sha256}"

KEY_URL="${KEY_URL:-https://install.my-north-africa.com/key}"

WORKDIR="${WORKDIR:-/tmp/northafrica-install}"
OUT_TAR="${OUT_TAR:-$WORKDIR/north.tar.gz}"
OUT_DIR="${OUT_DIR:-$WORKDIR/payload}"

say(){ echo -e "==> $*"; }

need_root(){ [[ "$(id -u)" -eq 0 ]] || { echo "Please run as root."; exit 1; }; }

safe_clear(){
  # avoid: "open terminal failed: not a terminal"
  if [[ -t 1 ]]; then clear || true; fi
}

get_ipv4(){
  # IPv4 only
  curl -4 -fsS https://api.ipify.org 2>/dev/null \
    || curl -4 -fsS https://ifconfig.me 2>/dev/null \
    || echo ""
}

deny(){
  safe_clear
  echo "404 NOT FOUND AUTOSCRIPT"
  echo
  echo "PERMISSION DENIED!"
  echo "Your VPS is NOT registered."
  echo "VPS IP : ${MYIP:-unknown}"
  exit 1
}

choose_port(){
  # pick a free port in 18000-18999
  local p
  for p in $(seq 18000 18999); do
    if ! ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":${p}$"; then
      echo "$p"
      return 0
    fi
  done
  echo "18080"
}

need_root

TS="$(date +%s)"
MYIP="$(get_ipv4)"

say "Prepare workdir: $WORKDIR"
rm -rf "$WORKDIR"
install -d -m 700 "$WORKDIR"

say "1) Check registration (IPv4, recommended)"
if [[ -n "${MYIP}" ]]; then
  if ! curl -fsSL "${REG_URL}?t=${TS}" | grep -qw "$MYIP"; then
    deny
  fi
else
  echo "[WARN] Could not detect public IPv4. Skipping register check."
fi

say "2) Download encrypted payload + sha256 (cache-bust)"
curl -fsSL -o "$WORKDIR/north.enc"        "${ENC_URL}?t=${TS}"
curl -fsSL -o "$WORKDIR/north.enc.sha256" "${SHA_URL}?t=${TS}"

say "3) Verify sha256"
REMOTE_SHA="$(tr -d '\r\n' < "$WORKDIR/north.enc.sha256")"
LOCAL_SHA="$(sha256sum "$WORKDIR/north.enc" | awk '{print $1}')"
echo "REMOTE_SHA=$REMOTE_SHA"
echo "LOCAL_SHA =$LOCAL_SHA"
[[ "$REMOTE_SHA" == "$LOCAL_SHA" ]] || { echo "[FAIL] SHA mismatch"; exit 1; }

say "4) Fetch key from KEY_URL (must be HEX-64)"
# always pass ipv4 in query (worker should trust ip=)
HTTP_CODE="$(curl -sS -w '%{http_code}' -o "$WORKDIR/key.txt" \
  "${KEY_URL}?ip=${MYIP}&t=${TS}" || true)"

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "[FAIL] KEY_URL HTTP=$HTTP_CODE"
  echo "Body:"
  cat "$WORKDIR/key.txt" || true
  deny
fi

KEY="$(tr -d '\r\n ' < "$WORKDIR/key.txt")"
echo "$KEY" | grep -qiE '^[0-9a-f]{64}$' || { echo "[FAIL] INVALID_NA_KEY_FORMAT"; deny; }

say "5) Decrypt payload"
openssl enc -aes-256-cbc -d -pbkdf2 \
  -in "$WORKDIR/north.enc" -out "$OUT_TAR" \
  -pass pass:"$KEY"

say "6) Extract payload"
install -d -m 755 "$OUT_DIR"
tar -xzf "$OUT_TAR" -C "$OUT_DIR"

# sanity (optional)
[[ -f "$OUT_DIR/premium.sh" ]] || { echo "[FAIL] premium.sh not found inside payload"; exit 1; }

say "7) Start local payload server (so premium.sh downloads local files, not GitHub)"
PORT="$(choose_port)"
# run in background
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$OUT_DIR" >/dev/null 2>&1 &
HTTP_PID="$!"

cleanup(){
  kill "$HTTP_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Quick probe (optional)
curl -fsS "http://127.0.0.1:${PORT}/files/sshd" >/dev/null 2>&1 || true

say "8) Run installer (premium.sh) using local REPO_URL"
# IMPORTANT: override REPO_URL so all downloads hit local payload paths
export REPO_URL="http://127.0.0.1:${PORT}/"
export REG_URL="$REG_URL"

# avoid "Text file busy" on reinstall
systemctl stop ws 2>/dev/null || true
pkill -x ws 2>/dev/null || true
rm -f /usr/bin/ws 2>/dev/null || true

chmod +x "$OUT_DIR/premium.sh"
(cd "$OUT_DIR" && bash ./premium.sh)

say "DONE ✅"