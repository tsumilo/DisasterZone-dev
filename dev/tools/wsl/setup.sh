#!/bin/bash
# One-time set-up of the Linux side of the test runner (tools/wsl/README.md): the WSL distro's default user,
# a Python venv at /opt/dzenv with the packages of dev/requirements.txt. Safe to run again.
#   wsl -d Ubuntu-26.04 -u root -e bash /mnt/c/Users/emilo/CDLoot-dev/dev/tools/wsl/setup.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DEV="$(dirname "$(dirname "$HERE")")"

printf '[user]\ndefault=root\n[boot]\nsystemd=false\n' > /etc/wsl.conf

if ! python3 -m venv --help >/dev/null 2>&1 || ! dpkg -s python3-venv >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq python3-venv python3-pip >/dev/null
fi
[ -x /opt/dzenv/bin/python ] || python3 -m venv /opt/dzenv
/opt/dzenv/bin/pip install -q --disable-pip-version-check -r "$DEV/requirements.txt" numpy==2.5.3 pillow==12.3.0 shapely==2.1.2
/opt/dzenv/bin/python - <<'EOF'
import lupa, numpy
from lupa import lua51
print("dzenv ok: lupa", lupa.__version__, "numpy", numpy.__version__, lua51.LuaRuntime().eval("_VERSION"))
EOF
