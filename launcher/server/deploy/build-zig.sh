#!/usr/bin/env bash
# Build dz-server for the server from Windows, without WSL (build-linux.sh does the same in WSL): one static Linux
# binary (musl), cross-compiled with cargo-zigbuild, zig standing in as the C compiler ring needs. Once:
#   rustup target add x86_64-unknown-linux-musl
#   cargo install cargo-zigbuild
#   python -m pip install ziglang          (zig itself; or put zig on PATH)
# Then, in Git Bash: bash launcher/server/deploy/build-zig.sh   -> launcher/server/target/dz-deploy.tar.gz
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"
TARGET=x86_64-unknown-linux-musl

if ! command -v zig >/dev/null && [ -z "${CARGO_ZIGBUILD_ZIG_PATH:-}" ]; then
    # (the ziglang pip package: its zig.exe next to the Python that installed it)
    for py in python python3 "$HOME/CDLoot-dev/dev/luaenv/Scripts/python.exe"; do
        z="$("$py" -c 'import ziglang, os; print(os.path.join(os.path.dirname(ziglang.__file__), "zig"))' 2>/dev/null || true)"
        if [ -n "$z" ] && { [ -f "$z.exe" ] || [ -f "$z" ]; }; then export CARGO_ZIGBUILD_ZIG_PATH="$z"; break; fi
    done
fi

(cd "$SRC" && cargo zigbuild --release --target "$TARGET")
BIN="$SRC/target/$TARGET/release/dz-server"

STAGE="$(mktemp -d)/dz-deploy"
mkdir -p "$STAGE"
cp "$BIN" "$HERE/setup.sh" "$HERE/update.sh" "$HERE/dz-server.service" "$HERE/Caddyfile" "$STAGE/"
sed -i 's/\r$//' "$STAGE"/*.sh "$STAGE/dz-server.service" "$STAGE/Caddyfile"
tar czf "$SRC/target/dz-deploy.tar.gz" -C "$(dirname "$STAGE")" dz-deploy
ls -la "$SRC/target/dz-deploy.tar.gz"
