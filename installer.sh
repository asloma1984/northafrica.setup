#!/usr/bin/env bash
set -Eeuo pipefail

# ===================== CONFIG =====================
REG_URL="https://raw.githubusercontent.com/asloma1984/NorthAfrica/main/register"
ENC_URL="https://install.my-north-africa.com/private/north.enc"
KEY_FILE="/etc/northafrica/north.key"

SESSION="northafrica"
LOG="/var/log/northafrica-install.log"
# ==================================================

say(){ echo -e "$*"; }
die(){ say "[ERROR] $*"; exit 1; }
info(){ say "[INFO] $*"; }

need_root(){ [[ "$(id -u)" == "0" ]] || die "Run as root"; }

get_ip(){
  curl -fsS https://api.ipify.org 2>/dev/null \
  || curl -fsS ipv4.icanhazip.com 2>/dev/null \
  || hostname -I 2>/dev/null | awk '{print $1}'
}

install_deps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get upgrade -y >/dev/null 2>&1 || true
  apt-get install -y curl wget unzip openssl tmux ca-certificates >/dev/null 2>&1
}

check_license(){
  local ip="$1" line exp now_ts exp_ts
  line="$(curl -fsSL "$REG_URL" | tr -d '\r' | awk -v ip="$ip" '$NF==ip{print; exit}')"
  [[ -n "${line:-}" ]] || die "PERMISSION DENIED! Your VPS $ip is not registered."

  exp="$(echo "$line" | awk '{print $3}')"
  [[ -n "${exp:-}" ]] || die "Bad register format (missing expiry)."

  now_ts="$(date +%s)"
  exp_ts="$(date -d "$exp" +%s 2>/dev/null || echo 0)"
  (( exp_ts > now_ts )) || die "License expired ($exp)."

  mkdir -p /etc/northafrica
  echo "$line" | awk '{print $2}' > /etc/northafrica/user
  echo "$exp" > /etc/northafrica/expiry
  info "Licensed for $(cat /etc/northafrica/user) until $exp"
}

fetch_key(){
  [[ -s "$KEY_FILE" ]] || die "Key file not found: $KEY_FILE"
  tr -d '\r\n' < "$KEY_FILE"
}

run_install(){
  local ip key tmp
  ip="$(get_ip)"; [[ -n "${ip:-}" ]] || die "Cannot detect IP"
  info "VPS IP: $ip"

  check_license "$ip"
  key="$(fetch_key)"
  [[ ${#key} -ge 16 ]] || die "Bad key length"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  info "Downloading encrypted payload..."
  curl -fsSL -o "$tmp/north.enc" "$ENC_URL" || die "Failed to download north.enc"

  info "Decrypting payload..."
  openssl enc -aes-256-cbc -d -pbkdf2 \
    -in "$tmp/north.enc" -out "$tmp/north.tar.gz" \
    -pass pass:"$key" || die "Decrypt failed (wrong key?)"

  tar -xzf "$tmp/north.tar.gz" -C "$tmp" || die "Extract failed"
  [[ -f "$tmp/premium.sh" ]] || die "premium.sh not found inside payload"

  chmod +x "$tmp/premium.sh"
  info "Starting installer..."
  mkdir -p "$(dirname "$LOG")"
  bash "$tmp/premium.sh" 2>&1 | tee -a "$LOG"
}

need_root
install_deps

if [[ -z "${TMUX:-}" ]]; then
  info "Install is running in tmux session: $SESSION"
  info "Log: $LOG"
  info "Attach: tmux attach -t $SESSION"
  tmux new-session -d -s "$SESSION" "bash -lc 'bash $0; echo; echo DONE. Log: $LOG; read -n 1'"
  exit 0
fi

run_install
info "DONE ✅"
