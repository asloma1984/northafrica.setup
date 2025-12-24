#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "[FAIL] line=$LINENO cmd=$BASH_COMMAND" >&2' ERR

# ==========================================================
# NorthAfrica Setup Installer (Encrypted Payload Bootstrap)
# - Supports running via: curl ... | bash
# - Fixes "not a terminal" by attaching stdin to /dev/tty
# - Checks VPS IP registration (recommended)
# - Downloads encrypted payload + sha256 (cache-bust)
# - Verifies sha256 integrity
# - Fetches decryption key from KEY_URL (allowed VPS only)
# - Decrypts + extracts payload
# - Finds and runs premium.sh from extracted payload
# ==========================================================

# ====== CONFIG (override via environment variables) ======
REG_URL="${REG_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-public/main/register}"

ENC_URL="${ENC_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.enc}"
SHA_URL="${SHA_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.enc.sha256}"

# Cloudflare Worker / custom domain endpoint
KEY_URL="${KEY_URL:-https://install.my-north-africa.com/key}"

WORKDIR="${WORKDIR:-/tmp/northafrica-install}"
OUT_TAR="${OUT_TAR:-$WORKDIR/north.tar.gz}"
OUT_DIR="${OUT_DIR:-$WORKDIR/payload}"

DEBUG="${DEBUG:-0}"

# If script is executed via pipe, stdin is not a TTY.
# Attach stdin to /dev/tty so interactive scripts (premium.sh) work.
if [[ -t 1 && ! -t 0 && -r /dev/tty ]]; then
  exec </dev/tty
fi

(( DEBUG == 1 )) && set -x

say() { echo -e "==> $*"; }

need_root() {
  [[ $(id -u) -eq 0 ]] || { echo "Please run as root."; exit 1; }
}

get_ip() {
  curl -fsS https://api.ipify.org 2>/dev/null \
    || curl -fsS https://ifconfig.me 2>/dev/null \
    || echo ""
}

safe_clear() {
  [[ -t 1 ]] && clear || true
}

deny() {
  safe_clear
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

say "4) Fetch key from KEY_URL (must be HEX-64)"
HTTP_CODE="$(curl -sS -w '%{http_code}' -o "$WORKDIR/key.txt" "${KEY_URL}?ip=${MYIP}&t=${TS}" || true)"
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "[FAIL] KEY_URL HTTP=$HTTP_CODE"
  echo "Body:"
  cat "$WORKDIR/key.txt" || true
  deny
fi

KEY="$(tr -d '\r\n ' < "$WORKDIR/key.txt")"
echo "$KEY" | grep -qiE '^[0-9a-f]{64}$' || { echo "[FAIL] Key is not valid HEX-64"; deny; }

say "5) Decrypt payload"
openssl enc -aes-256-cbc -d -pbkdf2 \
  -in "$WORKDIR/north.enc" -out "$OUT_TAR" \
  -pass pass:"$KEY"

say "6) Extract payload"
install -d -m 755 "$OUT_DIR"
tar -xzf "$OUT_TAR" -C "$OUT_DIR"

say "7) Find premium.sh"
# Prefer root premium.sh if exists; otherwise find inside dist/ or subfolders
PREMIUM=""
if [[ -f "$OUT_DIR/premium.sh" ]]; then
  PREMIUM="$OUT_DIR/premium.sh"
else
  PREMIUM="$(find "$OUT_DIR" -maxdepth 3 -type f -name "premium.sh" | head -n 1 || true)"
fi

if [[ -z "${PREMIUM}" ]]; then
  echo "[FAIL] premium.sh not found inside payload"
  echo "Found files (top):"
  find "$OUT_DIR" -maxdepth 2 -type f | head -n 120
  exit 1
fi

echo "Found: $PREMIUM"

say "8) Run installer (premium.sh)"
chmod +x "$PREMIUM"

# Make sure premium.sh also gets a TTY if available
if [[ -r /dev/tty ]]; then
  (cd "$(dirname "$PREMIUM")" && bash "./$(basename "$PREMIUM")" </dev/tty)
else
  (cd "$(dirname "$PREMIUM")" && bash "./$(basename "$PREMIUM")")
fi

say "DONE ✅"