#!/bin/bash
# Packs a trimmed runtime folder (wine/ and prefix/, made by build-runtime.sh) into
# runtime.tar.xz, leaving nothing in it that belongs to the machine or user that built it.
# Usage: pack-runtime.sh <runtime folder> [hostname of the machine that built the prefix]
set -euo pipefail
cd "${1:?usage: pack-runtime.sh <runtime folder> [build hostname]}"
BUILD_HOST=${2:-$(hostname)}

# Wine's user folders become plain folders instead of links into the builder's home.
find prefix/drive_c/users -type l | while read -r link; do rm "$link"; mkdir "$link"; done
# Wine recreates every drive letter except C: and Z: on each machine.
find prefix/dosdevices -mindepth 1 ! -name 'c:' ! -name 'z:' -delete

# The registry forgets the build machine's name and its audio devices.
python3 - "$BUILD_HOST" prefix/system.reg prefix/user.reg <<'PY'
import re, sys
host, paths = sys.argv[1], sys.argv[2:]
stale = ("\\\\MMDevices\\\\Audio\\\\Render\\\\", "\\\\MMDevices\\\\Audio\\\\Capture\\\\", ".drv\\\\devices\\\\")
for path in paths:
    with open(path, encoding="latin-1", newline="") as f:
        keys = f.read().split("\n\n")
    keys = [k for k in keys if not any(s in k.split("]", 1)[0] for s in stale)]
    text = re.sub(re.escape(host), "raspberrypi", "\n\n".join(keys), flags=re.I)
    with open(path, "w", encoding="latin-1", newline="") as f:
        f.write(text)
PY

cat > run.sh <<'EOF'
#!/bin/sh
# Klass of 99: a 32-bit Windows game, run with the trimmed Wine kept in this folder.
here=$(dirname "$(readlink -f "$0")")
# The prefix was made for a Windows user called "pi"; Wine uses that name for everyone.
export WINEPREFIX="$here/prefix" WINEUSERNAME=pi WINEDEBUG=-all
export WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d"
# Wake the X server first. If Wine is the first X client of an Xwayland that has
# not started yet, the game window never appears.
xdpyinfo >/dev/null 2>&1
cd "$here/game" && exec "$here/wine/bin/wine" KO99.exe
EOF
chmod +x run.sh

tar -cJf runtime.tar.xz --owner=0 --group=0 --numeric-owner wine prefix run.sh
ls -l "$PWD/runtime.tar.xz"
