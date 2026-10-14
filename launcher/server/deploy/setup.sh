#!/usr/bin/env bash
# One-time set-up of the bot on a fresh Google Cloud e2-micro (Debian 12), from the unpacked dz-deploy bundle:
#   tar xzf dz-deploy.tar.gz && bash dz-deploy/setup.sh <name>.duckdns.org <duckdns token>
# It installs the bot (the prebuilt dz-server next to this script), HTTPS (Caddy), a swap file (the machine has 1 GB),
# a DuckDNS updater (the address follows the machine if its IP changes), asks for the bot token, and takes the data
# bundle (dz-data.tar.gz in the home folder) if it is there.
set -euo pipefail

HOST="${1:?usage: setup.sh <name>.duckdns.org <duckdns token>}"
DUCK_TOKEN="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== packages"
sudo apt-get update -y
sudo apt-get install -y curl debian-keyring debian-archive-keyring apt-transport-https gpg

echo "== swap (1 GB of memory is tight while pictures are drawn)"
if ! swapon --show | grep -q /swapfile; then
    sudo fallocate -l 1G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

echo "== the bot in /opt/dz"
sudo useradd --system --home /opt/dz --shell /usr/sbin/nologin dz 2>/dev/null || true
sudo mkdir -p /opt/dz/data
sudo install -m 755 "$HERE/dz-server" /opt/dz/dz-server
if [ -f "$HOME/dz-data.tar.gz" ]; then
    echo "   taking the data bundle"
    sudo tar xzf "$HOME/dz-data.tar.gz" -C /opt/dz/data
    rm -f "$HOME/dz-data.tar.gz"
fi
if [ ! -s /opt/dz/data/discord_token.txt ]; then
    read -r -s -p "Paste the bot token (Developer Portal > Bot > Reset Token), then Enter: " TOKEN
    echo
    printf '%s' "$TOKEN" | sudo tee /opt/dz/data/discord_token.txt >/dev/null
    unset TOKEN
fi
sudo sed -i 's/"listen": *"[^"]*"/"listen": "127.0.0.1:8787"/' /opt/dz/data/server.json 2>/dev/null || true
sudo chown -R dz:dz /opt/dz/data
sudo chmod 700 /opt/dz/data
sudo chmod 600 /opt/dz/data/discord_token.txt
sudo install -m 644 "$HERE/dz-server.service" /etc/systemd/system/dz-server.service
sudo systemctl daemon-reload
sudo systemctl enable dz-server

echo "== DuckDNS keeps pointing at this machine"
if [ -n "$DUCK_TOKEN" ]; then
    SUB="${HOST%%.duckdns.org}"
    echo "*/5 * * * * root curl -fsS 'https://www.duckdns.org/update?domains=$SUB&token=$DUCK_TOKEN&ip=' >/dev/null 2>&1" \
        | sudo tee /etc/cron.d/duckdns >/dev/null
    sudo chmod 600 /etc/cron.d/duckdns
    curl -fsS "https://www.duckdns.org/update?domains=$SUB&token=$DUCK_TOKEN&ip=" && echo
fi

echo "== Caddy (HTTPS)"
if ! command -v caddy >/dev/null; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y caddy
fi
sed "s/BOT_HOST/$HOST/" "$HERE/Caddyfile" | sudo tee /etc/caddy/Caddyfile >/dev/null
sudo systemctl restart caddy

echo "== start"
sudo systemctl restart dz-server
sleep 3
systemctl --no-pager --lines=8 status dz-server || true
echo
echo "Done. Check https://$HOST/api/health in a browser and /ping in Discord."
echo "Logs: journalctl -u dz-server -f"
