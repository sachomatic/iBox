#!/usr/bin/env bash
# Installs dist/ibox.deb on the iPhone over SSH and (re)starts iBox.
#   ./deploy.sh                 # uses the "iphone4" host from ~/.ssh/config, user root
#   IBOX_HOST=root@192.168.1.128 ./deploy.sh
#   IBOX_PORT=22022 IBOX_HOST=root@127.0.0.1 ./deploy.sh   # over USB via tools/usbproxy.py
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
HOST="${IBOX_HOST:-root@iphone4}"
PORT="${IBOX_PORT:-22}"
OPTS=(-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa
      -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1 ${IBOX_SSH_OPTS:-})

scp -O -P "$PORT" "${OPTS[@]}" "$ROOT/dist/ibox.deb" "$HOST:/tmp/ibox.deb"
ssh -p "$PORT" "${OPTS[@]}" "$HOST" '
    killall iBox 2>/dev/null
    dpkg -i /tmp/ibox.deb && rm -f /tmp/ibox.deb
    sleep 1
    su mobile -c /usr/bin/ibox-launch 2>/dev/null || /usr/bin/ibox-launch
'
echo "iBox installed and launched."
