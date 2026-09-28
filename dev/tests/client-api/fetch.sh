#!/bin/sh
# usage: fetch.sh path/under/Interface...  -> saves to src/<path>
for p in "$@"; do
  out="src/$p"
  mkdir -p "$(dirname "$out")"
  if [ ! -s "$out" ]; then
    curl -sS -m 60 -o "$out" "https://raw.githubusercontent.com/Gethe/wow-ui-source/classic_anniversary/$p" || echo "FAIL $p"
  fi
done
