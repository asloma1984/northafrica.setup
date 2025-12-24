#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "[FAIL] line=$LINENO cmd=$BASH_COMMAND" >&2' ERR

# If script was executed via pipe: curl ... | bash
# make sure stdin is a real TTY so premium.sh can ask questions.
if [[ ! -t 0 && -r /dev/tty ]]; then
  exec </dev/tty
fi

# ==========================================================
# NorthAfrica Setup Installer (Encrypted Payload Bootstrap)
# IPv4-ONLY MODE:
#   - register file contains IPv4 only
#   - we force IPv4 when calling KEY_URL so Worker sees IPv4
# ==========================================================

# ====== CONFIG (override via env) ======
REG_URL="${REG_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-public/main/register}"

ENC_URL="${ENC_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.enc}"
SHA_URL="${SHA_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.enc.sha256}"

# Your Cloudflare Worker (custom domain) key endpoint
KEY_URL="${KEY_URL:-https://install.my-north-africa.com/key}"

WORKDIR="${WORKDIR:-/tmp/northafrica-install}"
OUT_TAR="${OUT_TAR:-$WORKDIR/north.tar.gz}"
OUT_DIR="${OUT_DIR:-$WORKDIR/payload}"

# Force IPv4 for Worker calls (important if server has IPv6)
CURL4="curl -4"

say() { echo -e "==> $*"; }

need_root() {
  [[ $(id -u) -eq 0 ]] || { echo "Please run as root."; exit 1; }
}

get_ipv4() {
  # Force IPv4 to avoid returning IPv6
  $CURL4 -fsS https://api.ipify.org 2>/dev/null \
    || $CURL4 -fsS https://ifconfig.me 2>/dev/null \
    || echo ""
}

safe_clear() {
  # clear only if output is a terminal
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
MYIP="$(get_ipv4)"
TS="$(date +%s)"

say "Prepare workdir: $WORKDIR"
rm -rf "$WORKDIR"
install -d -m 700 "$WORKDIR"

say "1) Check registration (recommended)"
if [[ -n "${MYIP}" ]]; then
  # cache-bust register fetch
  if ! curl -fsSL "${REG_URL}?t=${TS}" | grep -qw "$MYIP"; then
    deny
  fi
else
  echo "[WARN] Could not detect public IPv4. Skipping register check."
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

say "4) Fetch key from KEY_URL (must be HEX-64) via IPv4"
HTTP_CODE="$($CURL4 -sS -w '%{http_code}' -o "$WORKDIR/key.txt" "${KEY_URL}?ip=${MYIP}&t=${TS}" || true)"

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "[FAIL] KEY_URL HTTP=$HTTP_CODE"
  echo "Body:"
  cat "$WORKDIR/key.txt" || true
  deny
fi

KEY="$(tr -d '\r\n ' < "$WORKDIR/key.txt")"
if ! echo "$KEY" | grep -qiE '^[0-9a-f]{64}$'; then
  echo "[FAIL] Invalid key format (expected 64 hex chars)"
  echo "Body:"
  cat "$WORKDIR/key.txt" || true
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