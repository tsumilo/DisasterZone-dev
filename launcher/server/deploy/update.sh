#!/usr/bin/env bash
# Put a new build of the bot in place and restart it, from a newly unpacked dz-deploy bundle:
#   tar xzf dz-deploy.tar.gz && bash dz-deploy/update.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
sudo install -m 755 "$HERE/dz-server" /opt/dz/dz-server
sudo install -m 644 "$HERE/dz-server.service" /etc/systemd/system/dz-server.service
sudo systemctl daemon-reload
sudo systemctl restart dz-server
sleep 2
systemctl --no-pager --lines=5 status dz-server
