#!/bin/bash
# Runs a dev/ Python command in the WSL distro (tools/wsl/README.md) with what the harness needs there.
# tf_e/run_all.py calls it for every suite it runs in WSL; by hand, from Windows:
#   wsl -d Ubuntu-26.04 -e bash /mnt/c/Users/emilo/CDLoot-dev/dev/tools/wsl/run.sh tests/votes/test_votes.py -k x
HERE="$(cd "$(dirname "$0")" && pwd)"
DEV="$(dirname "$(dirname "$HERE")")"
cd "$DEV" || exit 2
export DISASTERZONE_ADDON_DIR="${DISASTERZONE_ADDON_DIR:-/mnt/c/World of Warcraft/_anniversary_/Interface/AddOns/DisasterZone}"
# compiled Python modules on the Linux disk (not next to the sources on /mnt/c, and not recompiled every run)
export PYTHONPYCACHEPREFIX=/var/cache/dz-pyc
# one thread per suite for numpy's maths: run_all gives each suite one slot (the stand-in generator took 12 cores)
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
# the harness's Linux-side bytecode cache (tools/harness.py NATIVE_DIR): drop what nothing used for two weeks, daily
CACHE=/var/cache/dz-bc
if [ -d "$CACHE" ] && [ -z "$(find "$CACHE/.pruned" -mtime -1 2>/dev/null)" ]; then
  touch "$CACHE/.pruned"
  find "$CACHE" -type f -name '[0-9a-f]*' -mtime +14 -delete 2>/dev/null
fi
exec /opt/dzenv/bin/python "$@"
