#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "[FAIL] line=$LINENO cmd=$BASH_COMMAND rc=$?" >&2' ERR

# ==========================================================
# NorthAfrica Setup Installer (Encrypted Payload Bootstrap)
# - Registration check (IPv4)
# - Download north.enc + sha256 (cache-bust)
# - Verify sha256
# - Fetch AES key from KEY_URL (allowed VPS only)
# - Decrypt + extract payload
# - Serve extracted payload via local HTTP (127.0.0.1)
# ==========================================================

# ====== CONFIG (override via env) ======
REG_URL="${REG_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-public/main/register}"

ENC_URL="${ENC_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.setup.enc}"
SHA_URL="${SHA_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.setup.enc.sha256}"

KEY_URL="${KEY_URL:-https://install.my-north-africa.com/key}"

WORKDIR="${WORKDIR:-/tmp/northafrica-install}"
OUT_TAR="${OUT_TAR:-$WORKDIR/north.tar.gz}"
OUT_DIR="${OUT_DIR:-$WORKDIR/payload}"

say(){ echo -e "==> $*"; }

need_root(){ [[ "$(id -u)" -eq 0 ]] || { echo "Please run as root."; exit 1; }; }

safe_clear(){
  if [[ -t 1 ]]; then clear || true; fi
}

get_ipv4(){
  curl -4 -fsS --connect-timeout 10 https://api.ipify.org 2>/dev/null \
    || curl -4 -fsS --connect-timeout 10 https://ifconfig.me 2>/dev/null \
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

# Ensure deps
export DEBIAN_FRONTEND=noninteractive
command -v curl >/dev/null 2>&1 || apt-get update -y && apt-get install -y curl ca-certificates
command -v openssl >/dev/null 2>&1 || apt-get install -y openssl
command -v tar >/dev/null 2>&1 || apt-get install -y tar
command -v ss >/dev/null 2>&1 || apt-get install -y iproute2
command -v python3 >/dev/null 2>&1 || apt-get install -y python3

TS="$(date +%s)"
MYIP="$(get_ipv4)"

say "Prepare workdir: $WORKDIR"
rm -rf "$WORKDIR"
install -d -m 700 "$WORKDIR"

say "1) Check registration (IPv4)"
if [[ -n "${MYIP}" ]]; then
  # IMPORTANT: do NOT use grep -w for IPv4 (dots break -w)
  if ! curl -fsSL --connect-timeout 15 "${REG_URL}?t=${TS}" | grep -Fq "$MYIP"; then
    deny
  fi
else
  echo "[WARN] Could not detect public IPv4. Skipping register check."
fi

say "2) Download encrypted payload + sha256 (cache-bust)"
curl -fsSL --connect-timeout 20 -o "$WORKDIR/north.setup.enc"        "${ENC_URL}?t=${TS}"
curl -fsSL --connect-timeout 20 -o "$WORKDIR/north.setup.enc.sha256" "${SHA_URL}?t=${TS}"

say "3) Verify sha256"
REMOTE_SHA="$(awk '{print $1}' "$WORKDIR/north.setup.enc.sha256" | tr -d '\r\n')"
LOCAL_SHA="$(sha256sum "$WORKDIR/north.setup.enc" | awk '{print $1}')"
[[ -n "$REMOTE_SHA" ]] || { echo "[FAIL] Empty remote sha"; exit 1; }
[[ "$REMOTE_SHA" == "$LOCAL_SHA" ]] || { echo "[FAIL] SHA mismatch"; exit 1; }

say "4) Fetch key from KEY_URL"
HTTP_CODE="$(curl -4 -sS -w '%{http_code}' -o "$WORKDIR/key.txt" \
  --connect-timeout 20 \
  "${KEY_URL}?t=${TS}" || true)"

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "[FAIL] KEY_URL HTTP=$HTTP_CODE"
  echo "Body:"
  cat "$WORKDIR/key.txt" || true
  deny
fi

KEY="$(tr -d '\r\n ' < "$WORKDIR/key.txt")"
echo "$KEY" | grep -qiE '^[0-9a-f]{64}$' || { echo "[FAIL] INVALID_KEY_FORMAT"; deny; }

say "5) Decrypt payload"
openssl enc -aes-256-cbc -d -pbkdf2 \
  -in "$WORKDIR/north.setup.enc" -out "$OUT_TAR" \
  -pass pass:"$KEY"

say "6) Extract payload"
install -d -m 755 "$OUT_DIR"
tar -xzf "$OUT_TAR" -C "$OUT_DIR"
  ( [[ -f "$OUT_DIR/north.setup" || -f "$OUT_DIR/premium.sh" || -f "$OUT_DIR/setup" ]] ) || { echo "[FAIL] No installer file in payload"; exit 1; }

say "7) Start local payload server"
PORT="$(choose_port)"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$OUT_DIR" >/dev/null 2>&1 &
HTTP_PID="$!"

cleanup(){
  kill "$HTTP_PID" >/dev/null 2>&1 || true
  #:
  # rm -rf "$WORKDIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# probe
curl -fsS "http://127.0.0.1:${PORT}/files/sshd" >/dev/null 2>&1 || true

say "8) Run extracted installer using local REPO_URL"
export REPO_URL="http://127.0.0.1:${PORT}/"
export REG_URL="$REG_URL"
  # Detect extracted entry file
  ENTRY=""
  for f in north.setup premium.sh setup; do
  if [[ -f "$OUT_DIR/$f" ]]; then
    ENTRY="$OUT_DIR/$f"
    break
  fi
  done

  if [[ -z "$ENTRY" ]]; then
  ENTRY="$(find "$OUT_DIR" -maxdepth 1 -type f | head -n 1 || true)"
  fi

  [[ -n "$ENTRY" && -f "$ENTRY" ]] || { echo "[FAIL] No entry file extracted"; exit 1; }
  chmod +x "$ENTRY"
  echo "==> Running: $ENTRY"
  (cd "$OUT_DIR" && bash "./$(basename "$ENTRY")")

# avoid "Text file busy" on reinstall
systemctl stop ws 2>/dev/null || true
pkill -x ws 2>/dev/null || true
rm -f /usr/bin/ws 2>/dev/null || true


say "DONE ✅"
