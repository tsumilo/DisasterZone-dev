#!/usr/bin/env bash
# Build dz-server for the server: one static Linux binary (musl), so the small cloud machine never compiles (1 GB RAM
# is too little for it) and it runs on any Linux image. Run in WSL (Ubuntu) from anywhere:
#   wsl -d Ubuntu-26.04 -- bash /mnt/c/Users/emilo/CDLoot-dev/launcher/server/deploy/build-linux.sh
# Result: launcher/server/target/x86_64-unknown-linux-musl/release/dz-server
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"
TARGET=x86_64-unknown-linux-musl

if ! command -v musl-gcc >/dev/null; then
    apt-get update -y && apt-get install -y musl-tools build-essential curl
fi
if [ ! -x "$HOME/.cargo/bin/cargo" ]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
fi
# shellcheck disable=SC1091
source "$HOME/.cargo/env"
rustup target add "$TARGET" >/dev/null

# (the build folder stays on the Linux side: building on /mnt/c is many times slower)
export CARGO_TARGET_DIR="$HOME/dz-server-target"
(cd "$SRC" && cargo build --release --target "$TARGET")
mkdir -p "$SRC/target/$TARGET/release"
cp "$CARGO_TARGET_DIR/$TARGET/release/dz-server" "$SRC/target/$TARGET/release/dz-server"

# the bundle to upload: the binary + the scripts (dz-deploy.tar.gz in launcher/server/target)
STAGE="$(mktemp -d)/dz-deploy"
mkdir -p "$STAGE"
cp "$CARGO_TARGET_DIR/$TARGET/release/dz-server" "$HERE/setup.sh" "$HERE/update.sh" "$HERE/dz-server.service" "$HERE/Caddyfile" "$STAGE/"
sed -i 's/\r$//' "$STAGE"/*.sh "$STAGE/dz-server.service" "$STAGE/Caddyfile"
tar czf "$SRC/target/dz-deploy.tar.gz" -C "$(dirname "$STAGE")" dz-deploy
ls -la "$SRC/target/dz-deploy.tar.gz"
file "$SRC/target/$TARGET/release/dz-server" 2>/dev/null || true
