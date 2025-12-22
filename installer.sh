#!/usr/bin/env bash
set -Eeuo pipefail

REG_URL="https://raw.githubusercontent.com/asloma1984/northafrica-public/main/register"
ENC_URL="https://raw.githubusercontent.com/asloma1984/northafrica-payload/main/north.enc"
KEY_FILE="/etc/northafrica/north.key"
SESSION="northafrica"
LOG="/var/log/northafrica-install.log"

say(){ echo -e "$*"; }
info(){ say "[INFO] $*"; }
die(){ say "[ERROR] $*"; exit 1; }

need_root(){ [[ "$(id -u)" == "0" ]] || die "Run as root"; }

install_deps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y
  apt-get install -y curl wget unzip openssl tmux ca-certificates
}

get_ip(){
  curl -fsS https://api.ipify.org || curl -fsS https://ifconfig.me || true
}

check_license(){
  local ip="$1" line exp now_ts exp_ts
  line="$(curl -fsSL "$REG_URL" | tr -d '\r' | awk -v ip="$ip" '$NF==ip{print; exit}')"
  [[ -n "${line:-}" ]] || die "Permission denied: VPS not registered"
  exp="$(awk '{print $3}' <<<"$line")"
  now_ts="$(date +%s)"
  exp_ts="$(date -d "$exp" +%s 2>/dev/null || echo 0)"
  (( exp_ts > now_ts )) || die "License expired: $exp"

  mkdir -p /etc/northafrica
  awk '{print $2}' <<<"$line" > /etc/northafrica/user
  echo "$exp" > /etc/northafrica/exp
  info "Licensed for $(cat /etc/northafrica/user) until $exp"
}

fetch_key(){
  [[ -s "$KEY_FILE" ]] || die "Key file missing: $KEY_FILE"
  tr -d '\r\n' < "$KEY_FILE"
}

run_install(){
  local ip key tmp

  ip="$(get_ip)"; [[ -n "${ip:-}" ]] || die "Cannot detect IP"
  info "VPS IP: $ip"
  check_license "$ip"

  key="$(fetch_key)"
  export NA_KEY="$key"
  [[ ${#key} -ge 16 ]] || die "Bad key length"

  tmp="$(mktemp -d)"
  trap '[[ -n "${tmp:-}" ]] && rm -rf "$tmp"' EXIT

  info "Downloading encrypted payload..."
  curl -fsSL -o "$tmp/north.enc" "$ENC_URL" || die "Failed to download north.enc"

  info "Decrypting payload..."
  openssl enc -aes-256-cbc -d -pbkdf2 -md sha256 -iter 200000 \
    -in "$tmp/north.enc" -out "$tmp/north.tar.gz" \
    -pass env:NA_KEY || die "Decrypt failed (wrong key?)"
  unset NA_KEY

  tar -xzf "$tmp/north.tar.gz" -C "$tmp" || die "Extract failed"
  [[ -f "$tmp/premium.sh" ]] || die "premium.sh not found inside payload"
  chmod +x "$tmp/premium.sh"

  info "Starting installer..."
  mkdir -p "$(dirname "$LOG")"
  bash "$tmp/premium.sh" 2>&1 | tee -a "$LOG"
  info "DONE ✅"
}

need_root
install_deps

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

if [[ -z "${TMUX:-}" ]]; then
  info "Install is running in tmux session: $SESSION"
  info "Log: $LOG"
  info "Attach: tmux attach -t $SESSION"

  mkdir -p "$(dirname "$LOG")"
  : > "$LOG"

  tmux kill-session -t "$SESSION" 2>/dev/null || true
  tmux new-session -d -s "$SESSION" \
    "cd /root && TMUX=1 bash -x \"$SELF\" 2>&1 | tee -a \"$LOG\"; echo; echo DONE. Log: $LOG; read -n 1"
  exit 0
fi

run_install
