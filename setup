#!/usr/bin/env bash
set -euo pipefail

REPO="asloma1984/northafrica.setup"
BRANCH="main"
DIR="/root/northafrica.setup"
SESSION="northafrica"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git tmux curl wget ca-certificates

rm -rf "$DIR"
git clone --depth 1 -b "$BRANCH" "https://github.com/$REPO.git" "$DIR"
chmod +x "$DIR/installer.sh"

if [[ -z "${TMUX:-}" ]]; then
  tmux new-session -d -s "$SESSION" "bash $DIR/installer.sh 2>&1 | tee /var/log/northafrica-install.log; echo DONE; read -n 1"
  echo "Install is running in tmux: $SESSION"
  echo "Attach: tmux attach -t $SESSION"
  exit 0
fi

bash "$DIR/installer.sh"