#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[FAIL] line=$LINENO cmd=$BASH_COMMAND" >&2' ERR

# Public register
REG_URL="${REG_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-public/main/register}"

# Encrypted payload (public repo)
ENC_URL="${ENC_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.enc}"
SHA_URL="${SHA_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.enc.sha256}"

# Key endpoint (Cloudflare Worker / your domain)
KEY_URL="${KEY_URL:-https://install.my-north-africa.com/key}"

deny() {
  clear || true
  echo "404 NOT FOUND AUTOSCRIPT"
  echo
  echo "PERMISSION DENIED!"
  echo "Your VPS is NOT registered."
  echo "VPS IP          : ${MYIP:-}"
  echo "Subscriber Name : ${NAME:-}"
  echo
  echo "Please contact the developer for activation."
  sleep 2
  exit 1
}

get_ip() {
  local ip url
  local urls=(
    "https://api.ipify.org"
    "https://ipv4.icanhazip.com"
    "https://checkip.amazonaws.com"
    "https://ifconfig.me/ip"
    "https://ipinfo.io/ip"
  )
  for url in "${urls[@]}"; do
    ip="$(curl -4 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '\r\n ')" || ip=""
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

# --- Name input (single prompt, clean)
if [[ -z "${NAME:-}" ]]; then
  printf "Subscriber Name : " > /dev/tty
  IFS= read -r NAME < /dev/tty
  printf "\n" > /dev/tty
fi

# sanitize: keep only A-Za-z0-9._-
NAME="$(printf "%s" "$NAME" \
  | tr -d '\r\n' \
  | tr -d '\000-\037\177' \
  | tr -cd 'A-Za-z0-9._-')"
[[ -n "$NAME" ]] || { echo "Subscriber name cannot be empty"; exit 1; }

MYIP="$(get_ip)" || deny

# --- Register check: format "### NAME YYYY-MM-DD IP"
REG_DATA="$(curl -fsSL "${REG_URL}?t=$(date +%s)" | tr -d '\r')" || deny
LINE="$(echo "$REG_DATA" | awk -v ip="$MYIP" '$NF==ip{print; exit}')"
[[ -n "$LINE" ]] || deny

REG_NAME="$(echo "$LINE" | awk '{print $2}')"
REG_EXP="$(echo "$LINE" | awk '{print $3}')"

[[ "$NAME" == "$REG_NAME" ]] || deny

today="$(date +%F)"
if [[ "$today" > "$REG_EXP" ]]; then
  deny
fi

# --- Fetch decrypt key from your KEY endpoint (no key sent manually to customers)
ENC_KEY="$(curl -fsSL --max-time 10 "${KEY_URL}?ip=${MYIP}&name=${NAME}" | tr -d '\r\n ')" || deny
[[ -n "$ENC_KEY" ]] || deny

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

curl -fsSL -o "$tmpdir/north.enc" "$ENC_URL"
curl -fsSL -o "$tmpdir/north.enc.sha256" "$SHA_URL"

got="$(sha256sum "$tmpdir/north.enc" | awk '{print $1}')"
exp="$(tr -d '\r\n ' < "$tmpdir/north.enc.sha256")"
[[ "$got" == "$exp" ]] || { echo "[ERROR] Payload checksum mismatch"; exit 1; }

openssl enc -aes-256-cbc -d -pbkdf2 -iter 200000 \
  -in "$tmpdir/north.enc" -out "$tmpdir/north.tar.gz" \
  -pass pass:"$ENC_KEY"

mkdir -p /root/NorthAfrica
tar -xzf "$tmpdir/north.tar.gz" -C /root/NorthAfrica

chmod +x /root/NorthAfrica/premium.sh
bash /root/NorthAfrica/premium.sh
