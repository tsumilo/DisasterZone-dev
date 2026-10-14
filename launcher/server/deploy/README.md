# The bot on a free server (Google Cloud e2-micro)

The bot (`dz-server`) runs all the time on Google Cloud's free e2-micro machine. Every member's launcher syncs the
game with it (Settings > Discord). Google asks for a card at sign-up; the free tier is not charged.

What the free tier covers (check cloud.google.com/free, it can change): one e2-micro in us-west1, us-central1 or
us-east1, a 30 GB *standard* disk, 1 GB of outgoing traffic a month. The launchers are built to stay far under that
(they ask only while WoW runs, and an unchanged answer is one line).

## 1. The machine (once, in the browser)

1. console.cloud.google.com: sign up, make a project (e.g. `disasterzone`).
2. **Billing > Budgets & alerts > Create budget**: $1, alerts at 50% and 100%. If anything ever costs money you hear
   about it at once. Whether the machine's public IP is free is not certain; the budget tells you within days.
3. **Compute Engine > VM instances > Create instance** (enable the API when asked):
   - Region **us-central1** (or us-west1 / us-east1); machine type **e2-micro**
   - Boot disk: **Debian 12**, disk type **Standard persistent disk**, 30 GB
   - Firewall: tick **Allow HTTP traffic** and **Allow HTTPS traffic**
4. Note the instance's External IP.

## 2. A name for HTTPS (once)

duckdns.org: sign in, add a subdomain (e.g. `disasterzone`), set it to the External IP. Keep the token shown at the
top of the page: setup.sh uses it so the name follows the machine if its IP ever changes.

## 3. The two bundles (on your PC)

- `dz-deploy.tar.gz`: the bot + scripts. Build it in WSL:
  `wsl -d Ubuntu-26.04 -- bash /mnt/c/Users/emilo/CDLoot-dev/launcher/server/deploy/build-linux.sh`
  It lands in `launcher\server\target\`.
- `dz-data.tar.gz`: the bot's data folder (`C:\Users\emilo\DisasterZoneBot\data`): server.json, the signing key,
  bot_art, Items.lua, profiles, posts. Pack it in WSL:
  `wsl -d Ubuntu-26.04 -- tar czf /mnt/c/Users/emilo/DisasterZoneBot/dz-data.tar.gz -C /mnt/c/Users/emilo/DisasterZoneBot/data .`

## 4. Install (in the browser)

VM instances > **SSH** (opens a terminal in the browser). Its gear menu > **Upload file**: upload both bundles. Then:

    tar xzf dz-deploy.tar.gz && bash dz-deploy/setup.sh disasterzone.duckdns.org <duckdns token>

It asks for the bot token (Developer Portal > Bot > Reset Token). Paste it; nothing shows while you do.

Check: `https://disasterzone.duckdns.org/api/health` in a browser, `/ping` in Discord.
Logs: `journalctl -u dz-server -f`.

**From now on the server's copy of the data folder is the real one.** The one on your PC is a backup: never run a
bot from it again (the signing key's one-time signatures must never be used twice). Take a fresh backup now and then:
`sudo tar czf ~/dz-backup.tar.gz -C /opt/dz/data .`, then gear menu > Download file.

## 5. The launchers

Put `https://disasterzone.duckdns.org` in `launcher/server.txt` before the next launcher release (until then:
launcher > Settings > Advanced > Bot server). Each member types `/launcher` in Discord and pastes the code in
Settings > Discord.

## Updating the bot

Build a new `dz-deploy.tar.gz`, upload it, then: `tar xzf dz-deploy.tar.gz && bash dz-deploy/update.sh`

## Testing at home first

    set DZ_DATA=C:\Users\emilo\DisasterZoneBot\data
    cargo run --release            (in launcher/server)

It listens on http://127.0.0.1:8787; set launcher > Settings > Advanced > Bot server to that. On Windows the bot
token is taken from the launcher's old host mode when there is no `discord_token.txt`. Only one copy of the bot may
be online at a time, and only one copy of the data folder may ever sign.
