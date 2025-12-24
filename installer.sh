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
# - Runs premium.sh
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

need_root(){
  [[ $(id -u) -eq 0 ]] || { echo "Please run as root."; exit 1; }
}

safe_clear(){
  # avoid "not a terminal" messages when output is piped/redirected
  if [[ -t 1 ]]; then clear || true; fi
}

get_ip(){
  curl -fsS https://api.ipify.org 2>/dev/null \
  || curl -fsS https://ifconfig.me 2>/dev/null \
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

fetch_key(){
  # Tries KEY_URL without ip first (best security).
  # If your Worker still requires ip param, it falls back to ?ip=
  local ts="$1"
  local key_file="$WORKDIR/key.txt"
  local http body

  # 1) no ip
  http="$(curl -sS -w '%{http_code}' -o "$key_file" "${KEY_URL}?t=${ts}" || true)"
  body="$(tr -d '\r\n' < "$key_file" 2>/dev/null || true)"
  if [[ "$http" == "200" ]]; then
    echo "$body"
    return 0
  fi

  # 2) fallback with ip (compat)
  http="$(curl -sS -w '%{http_code}' -o "$key_file" "${KEY_URL}?ip=${MYIP}&t=${ts}" || true)"
  body="$(tr -d '\r\n' < "$key_file" 2>/dev/null || true)"
  if [[ "$http" == "200" ]]; then
    echo "$body"
    return 0
  fi

  echo "[FAIL] KEY_URL HTTP=$http"
  echo "Body:"
  cat "$key_file" 2>/dev/null || true
  return 1
}

need_root
TS="$(date +%s)"
MYIP="$(get_ip)"

say "Prepare workdir: $WORKDIR"
rm -rf "$WORKDIR"
install -d -m 700 "$WORKDIR"

say "1) Check registration (recommended)"
if [[ -n "${MYIP}" ]]; then
  # cache-bust to avoid GitHub/ISP cache delays
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
KEY="$(fetch_key "$TS")" || deny
KEY="$(echo -n "$KEY" | tr -d '\r\n ' | tr 'A-F' 'a-f')"
echo "$KEY" | grep -qE '^[0-9a-f]{64}$' || { echo "[FAIL] Invalid key format (need 64 hex chars)"; exit 1; }

say "5) Decrypt payload"
openssl enc -aes-256-cbc -d -pbkdf2 \
  -in "$WORKDIR/north.enc" -out "$OUT_TAR" \
  -pass pass:"$KEY"

say "6) Extract payload"
install -d -m 755 "$OUT_DIR"
tar -xzf "$OUT_TAR" -C "$OUT_DIR"

# Your repo contains premium.sh in root (and also dist/premium.sh)
if [[ -f "$OUT_DIR/premium.sh" ]]; then
  say "7) Run installer (premium.sh)"
  chmod +x "$OUT_DIR/premium.sh"
  (cd "$OUT_DIR" && bash ./premium.sh)
elif [[ -f "$OUT_DIR/dist/premium.sh" ]]; then
  say "7) Run installer (dist/premium.sh)"
  chmod +x "$OUT_DIR/dist/premium.sh"
  (cd "$OUT_DIR/dist" && bash ./premium.sh)
else
  echo "[FAIL] premium.sh not found inside payload"
  echo "Found files:"
  find "$OUT_DIR" -maxdepth 3 -type f | head -n 80
  exit 1
fi

say "DONE ✅"