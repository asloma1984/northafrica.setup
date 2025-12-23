#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[FAIL] line=$LINENO cmd=$BASH_COMMAND" >&2' ERR

# ✅ register public
REG_URL="${REG_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-public/main/register}"

# ✅ encrypted payload (   repo )
ENC_URL="${ENC_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.enc}"
SHA_URL="${SHA_URL:-https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.enc.sha256}"

# ✅ endpoint  KEY  
KEY_URL="${KEY_URL:-https://install.my-north-africa.com/key}"

get_ip(){ curl -4 -fsS https://api.ipify.org || curl -4 -fsS https://ipv4.icanhazip.com; }

deny(){
  clear
  echo "404 NOT FOUND AUTOSCRIPT"
  echo
  echo "PERMISSION DENIED!"
  echo "Your VPS is NOT registered."
  echo "VPS IP          : $MYIP"
  echo "Subscriber Name : $NAME"
  echo
  echo "Please contact the developer for activation."
  sleep 3
  exit 1
}

# -------- input
read -r -p "Enter subscriber name (as registered): " NAME
# تنظيف الاسم
NAME="$(printf '%s' "$NAME" | sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g; s/[^A-Za-z0-9._-]//g')"
[[ -n "$NAME" ]] || { echo "Subscriber name cannot be empty"; exit 1; }

MYIP="$(get_ip)"

# -------- fetch register + match (### NAME YYYY-MM-DD IP)
REG_DATA="$(curl -fsSL "${REG_URL}?t=$(date +%s)" | tr -d '\r')" || deny
LINE="$(echo "$REG_DATA" | awk -v ip="$MYIP" '$NF==ip{print; exit}')"
[[ -n "$LINE" ]] || deny

REG_NAME="$(echo "$LINE" | awk '{print $2}')"
REG_EXP="$(echo "$LINE"  | awk '{print $3}')"

[[ "$NAME" == "$REG_NAME" ]] || deny

# expiry check
today="$(date +%F)"
if [[ "$today" > "$REG_EXP" ]]; then deny; fi

# -------- get ENC_KEY automatically (from your server/worker)
ENC_KEY="$(curl -fsSL "${KEY_URL}?ip=$MYIP&name=$NAME" | tr -d '\r\n ')" || deny
[[ -n "$ENC_KEY" ]] || deny

# -------- download + integrity + decrypt + run
tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' EXIT

curl -fsSL -o "$tmpdir/north.enc" "$ENC_URL"
curl -fsSL -o "$tmpdir/north.enc.sha256" "$SHA_URL"
got="$(sha256sum "$tmpdir/north.enc" | awk '{print $1}')"
exp="$(tr -d '\r\n ' < "$tmpdir/north.enc.sha256")"
[[ "$got" == "$exp" ]] || { echo "[FAIL] Integrity check failed"; exit 1; }

openssl enc -aes-256-cbc -d -pbkdf2 -iter 200000 \
  -in "$tmpdir/north.enc" -pass pass:"$ENC_KEY" \
  -out "$tmpdir/premium.real"

chmod +x "$tmpdir/premium.real"
exec bash "$tmpdir/premium.real"