#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "[FAIL] line=$LINENO cmd=$BASH_COMMAND" >&2' ERR

# ==========================================================
# NorthAfrica Setup Installer (Encrypted Payload Bootstrap)
# - Checks VPS IP registration (recommended)
# - Downloads encrypted payload + sha256 (cache-bust)
# - Verifies sha256 integrity
# - Fetches decryption key from KEY_URL (allowed VPS only)
# - Decrypts + extracts payload
# - Runs premium.sh from extracted payload
# ==========================================================

# ====== CONFIG (override via environment variables) ======
REG_URL="${REG_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-public/main/register}"

ENC_URL="${ENC_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.enc}"
SHA_URL="${SHA_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.enc.sha256}"

# Cloudflare Worker / your domain (returns HEX decryption key for allowed VPS only)
KEY_URL="${KEY_URL:-https://install.my-north-africa.com/key}"

WORKDIR="${WORKDIR:-/tmp/northafrica-install}"
OUT_TAR="${OUT_TAR:-$WORKDIR/north.tar.gz}"
OUT_DIR="${OUT_DIR:-$WORKDIR/payload}"

say() { echo -e "==> $*"; }

need_root() {
  [[ $(id -u) -eq 0 ]] || { echo "Please run as root."; exit 1; }
}

get_ip() {
  curl -fsS https://api.ipify.org 2>/dev/null \
    || curl -fsS https://ifconfig.me 2>/dev/null \
    || echo ""
}

deny() {
  clear || true
  echo "404 NOT FOUND AUTOSCRIPT"
  echo
  echo "PERMISSION DENIED!"
  echo "Your VPS is NOT registered."
  echo "VPS IP : ${MYIP:-unknown}"
  exit 1
}

need_root
MYIP="$(get_ip)"
TS="$(date +%s)"

say "Prepare workdir: $WORKDIR"
rm -rf "$WORKDIR"
install -d -m 700 "$WORKDIR"

say "1) Check registration (recommended)"
if [[ -n "${MYIP}" ]]; then
  if ! curl -fsSL "${REG_URL}?t=${TS}" | grep -qw "$MYIP"; then
    deny
  fi
else
  echo "[WARN] Could not detect public IP. Skipping register check."
fi

say "2) Download encrypted payload + sha256 (cache-bust)"
curl -fsSL -o "$WORKDIR/north.enc" "${ENC_URL}?t=${TS}"
curl -fsSL -o "$WORKDIR/north.enc.sha256" "${SHA_URL}?t=${TS}"

say "3) Verify sha256"
REMOTE_SHA="$(tr -d '\r\n' < "$WORKDIR/north.enc.sha256")"
LOCAL_SHA="$(sha256sum "$WORKDIR/north.enc" | awk '{print $1}')"
echo "REMOTE_SHA=$REMOTE_SHA"
echo "LOCAL_SHA =$LOCAL_SHA"
[[ "$REMOTE_SHA" == "$LOCAL_SHA" ]] || { echo "[FAIL] SHA mismatch"; exit 1; }

say "4) Fetch key from KEY_URL (must be HEX key)"

# Print HTTP code + body for easier debugging
KEY_RESP="$(curl -sS -w '\n%{http_code}' "${KEY_URL}?ip=${MYIP}&t=${TS}" || true)"
KEY_CODE="$(echo "$KEY_RESP" | tail -n 1)"
KEY_BODY="$(echo "$KEY_RESP" | head -n -1 | tr -d '\r\n')"

if [[ "$KEY_CODE" != "200" ]]; then
  echo "[FAIL] KEY_URL HTTP=$KEY_CODE"
  echo "Body:"
  echo "$KEY_BODY"
  exit 1
fi

KEY="$KEY_BODY"

# Must be HEX and >= 32 chars (prefer 64 for aes-256 pass)
if ! [[ "$KEY" =~ ^[0-9a-fA-F]+$ ]]; then
  echo "[FAIL] Key is not HEX!"
  exit 1
fi
if [[ ${#KEY} -lt 32 ]]; then
  echo "[FAIL] Key looks too short (len=${#KEY})"
  exit 1
fi

say "5) Decrypt payload"
openssl enc -aes-256-cbc -d -pbkdf2 \
  -in "$WORKDIR/north.enc" -out "$OUT_TAR" \
  -pass pass:"$KEY"

say "6) Extract payload"
install -d -m 755 "$OUT_DIR"
tar -xzf "$OUT_TAR" -C "$OUT_DIR"

# The payload must contain ./premium.sh at the root
if [[ -f "$OUT_DIR/premium.sh" ]]; then
  say "7) Run installer (premium.sh)"
  chmod +x "$OUT_DIR/premium.sh"
  (cd "$OUT_DIR" && bash ./premium.sh)
else
  echo "[FAIL] premium.sh not found inside payload"
  echo "Found files:"
  find "$OUT_DIR" -maxdepth 2 -type f | head -n 50
  exit 1
fi

say "DONE ✅"