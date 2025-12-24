#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "[FAIL] line=$LINENO cmd=$BASH_COMMAND" >&2' ERR

# ==========================================================
# NorthAfrica Setup Installer (Encrypted Payload Bootstrap)
# - Checks VPS IP registration (optional but recommended)
# - Downloads encrypted payload + sha256
# - Verifies sha256 integrity
# - Fetches decryption key from KEY_URL (allowed VPS only)
# - Decrypts + extracts payload
# - Runs premium.sh from extracted payload
# ==========================================================

# ====== CONFIG (override via environment variables) ======
REG_URL="${REG_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-public/main/register}"

ENC_URL="${ENC_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.enc}"
SHA_URL="${SHA_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.enc.sha256}"

# Key endpoint (Cloudflare Worker / your domain) - returns the decryption key for allowed VPS only
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

# Download helper with cache-busting to avoid GitHub CDN stale files
dl() {
  local url="$1" out="$2" ts sep
  ts="$(date +%s)"
  sep='?'; [[ "$url" == *\?* ]] && sep='&'
  curl -fsSL -o "$out" "${url}${sep}t=${ts}"
}

# Try to fetch key in multiple formats to avoid KEY_URL 400 issues
fetch_key() {
  local k=""

  # 1) Plain
  k="$(curl -fsSL "$KEY_URL" 2>/dev/null || true)"
  k="$(echo -n "$k" | tr -d '\r\n ')"
  if [[ ${#k} -ge 32 ]]; then
    echo -n "$k"
    return 0
  fi

  # 2) With IP param
  if [[ -n "${MYIP:-}" ]]; then
    k="$(curl -fsSL "${KEY_URL}?ip=${MYIP}" 2>/dev/null || true)"
    k="$(echo -n "$k" | tr -d '\r\n ')"
    if [[ ${#k} -ge 32 ]]; then
      echo -n "$k"
      return 0
    fi
  fi

  # 3) With header (some workers expect header instead of query)
  if [[ -n "${MYIP:-}" ]]; then
    k="$(curl -fsSL -H "X-Client-IP: ${MYIP}" "$KEY_URL" 2>/dev/null || true)"
    k="$(echo -n "$k" | tr -d '\r\n ')"
    if [[ ${#k} -ge 32 ]]; then
      echo -n "$k"
      return 0
    fi
  fi

  return 1
}

need_root
MYIP="$(get_ip)"

say "Prepare workdir: $WORKDIR"
rm -rf "$WORKDIR"
install -d -m 700 "$WORKDIR"

say "1) Check registration (optional but recommended)"
# If you want to allow install without register check, comment this block.
if [[ -n "${MYIP}" ]]; then
  if ! curl -fsSL "$REG_URL" | grep -qw "$MYIP"; then
    deny
  fi
else
  echo "[WARN] Could not detect public IP. Skipping register check."
fi

say "2) Download encrypted payload + sha256"
dl "$ENC_URL" "$WORKDIR/north.enc"
dl "$SHA_URL" "$WORKDIR/north.enc.sha256"

say "3) Verify sha256"
REMOTE_SHA="$(tr -d '\r\n' < "$WORKDIR/north.enc.sha256")"
LOCAL_SHA="$(sha256sum "$WORKDIR/north.enc" | awk '{print $1}')"
echo "REMOTE_SHA=$REMOTE_SHA"
echo "LOCAL_SHA =$LOCAL_SHA"
[[ "$REMOTE_SHA" == "$LOCAL_SHA" ]] || { echo "[FAIL] SHA mismatch"; exit 1; }

say "4) Fetch key from KEY_URL"
if ! KEY="$(fetch_key)"; then
  echo "[FAIL] Could not fetch key (KEY_URL returned error or empty key)."
  echo "TIP: Your key service may require a parameter/header. Tested: plain, ?ip=, X-Client-IP."
  echo "MYIP=${MYIP:-unknown}"
  exit 1
fi

[[ ${#KEY} -ge 32 ]] || { echo "[FAIL] Key looks too short"; deny; }

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