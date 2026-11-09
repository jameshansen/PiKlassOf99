#!/bin/bash
# PiKlassOf99: installs Klass of 99 on 64-bit Raspberry Pi OS.
#
# Run it from the Pi's desktop. It uses the game's zip (KlassOf99Win1.0.7.zip) when one
# sits next to this script, and otherwise downloads it from the game's page or takes one
# you point it to. The game goes into ~/Games/KlassOf99, with an entry in the Games menu
# and a shortcut on the desktop. Run it again to reinstall or remove.
set -u
: "${HOME:?}"

TITLE="PiKlassOf99"
GAME="Klass of 99"
GAME_URL="https://bitglint.itch.io/klassof99"
ZIP_NAME="KlassOf99Win1.0.7.zip"
HERE=$(dirname "$(readlink -f "$0")")
RUNTIME="$HERE/runtime.tar.xz"
RUNTIME_FILES=520   # entries in runtime.tar.xz, for the progress bar
ICON="$HERE/icon.png"
DEST="$HOME/Games/KlassOf99"
MENU="${XDG_DATA_HOME:-$HOME/.local/share}/applications/klassof99.desktop"
SHORTCUT="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")/klassof99.desktop"
BOOTCFG=/boot/firmware/config.txt

if ! command -v zenity >/dev/null || [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  echo "Run this installer from the Raspberry Pi desktop. It needs zenity (sudo apt install zenity)." >&2
  exit 1
fi

# A page with up to three buttons, left to right: --cancel-label, --ok-label, --extra-button.
# OK returns 0. The extra button prints its label and returns 1, like Cancel.
page() { zenity --question --title="$TITLE" --width=560 --icon="$ICON" "$@" 2>/dev/null; }
note() { zenity --info --title="$TITLE" --width=560 --icon="$ICON" --text="$1" 2>/dev/null; }
fail() { zenity --error --title="$TITLE" --width=560 --no-markup --text="$1" 2>/dev/null; exit 1; }
busy() { zenity --progress --title="$TITLE" --width=560 --no-cancel --auto-close "$@" 2>/dev/null; }
as_root() { if sudo -n true 2>/dev/null; then sudo "$@"; else pkexec "$@"; fi; }

# True if the zip holds the game, wherever KO99.exe sits inside it.
is_game_zip() {
  python3 - "$1" <<'PY' 2>/dev/null
import sys, zipfile
names = zipfile.ZipFile(sys.argv[1]).namelist()
sys.exit(0 if any(n.lower().endswith("ko99.exe") for n in names) else 1)
PY
}

# Unpacks the folder that holds KO99.exe straight into the game folder.
unpack_game() {
  python3 - "$1" "$2" <<'PY'
import os, sys, zipfile
archive, dest = zipfile.ZipFile(sys.argv[1]), sys.argv[2]
exe = next(n for n in archive.namelist() if n.lower().endswith("ko99.exe"))
root = exe[: exe.rfind("/") + 1]
for info in archive.infolist():
    rel = info.filename[len(root):]
    if info.is_dir() or not info.filename.startswith(root) or ".." in rel.split("/"):
        continue
    target = os.path.join(dest, rel)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with archive.open(info) as src, open(target, "wb") as out:
        out.write(src.read())
PY
}

# Downloads the game's zip to $1 the way the Download button on the game's page does:
# load the page, then ask for the file with the page's own cookie and token. itch.io
# answers "429 Too Many Requests" now and then, so each request is tried a few times.
download_game() (
  set -e -o pipefail
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  web() { curl -fsS -L --retry 3 --retry-delay 5 -b "$work/cookies" -c "$work/cookies" -e "$GAME_URL" "$@"; }
  web "$GAME_URL" -o "$work/page.html"
  read -r token upload < <(python3 - "$work/page.html" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8", errors="replace").read()
token = re.search(r'<meta name="csrf_token" value="([^"]+)"', html).group(1)
# each file on the page has an upload id, followed by its name
upload = next(m.group(1) for m in re.finditer(r'data-upload_id="(\d+)"(?=(.{0,1500}))', html, re.S)
              if re.search(r"KlassOf99Win[\w.]*\.zip", m.group(2).split("data-upload_id")[0], re.I))
print(token, upload)
PY
  )
  url=$(web -H "X-Requested-With: XMLHttpRequest" --data-urlencode "csrf_token=$token" \
          "$GAME_URL/file/$upload?source=view_game&as_props=1&after_download_lightbox=true" |
        python3 -c 'import json, sys; print(json.load(sys.stdin)["url"])')
  curl -fsS -L --retry 3 --retry-delay 5 "$url" -o "$1"
)

# Shows a pulsing bar while the game downloads. Sets $zip and returns 0 if it worked.
fetch_game() {
  local target="$HERE/$ZIP_NAME" status
  [ -w "$HERE" ] || target="$(mktemp -d)/$ZIP_NAME"
  { download_game "$target" 2>/dev/null; status=$?; echo 100; exit $status; } |
    busy --pulsate --text="Downloading $GAME from the game's website..."
  [ "${PIPESTATUS[0]}" -eq 0 ] && is_game_zip "$target" && zip=$target
}

# Prints progress for the bar on stdout (a number, or "# text"); errors go to stderr.
install_files() (
  set -e -o pipefail
  mkdir -p "$DEST/game" "$(dirname "$MENU")" "$(dirname "$SHORTCUT")"
  rm -rf "$DEST/wine" "$DEST/prefix"
  echo "# Unpacking Wine, which runs the game..."
  count=0
  tar -xvJf "$RUNTIME" -C "$DEST" | while read -r _; do
    count=$((count + 1))
    if [ $((count % 8)) -eq 0 ] && [ "$count" -lt "$RUNTIME_FILES" ]; then echo $((count * 90 / RUNTIME_FILES)); fi
  done
  echo 92
  echo "# Unpacking $GAME..."
  unpack_game "$zip" "$DEST/game"
  echo 96
  echo "# Adding the menu entry and the desktop shortcut..."
  cp "$ICON" "$DEST/icon.png"
  cat >"$MENU" <<EOF
[Desktop Entry]
Type=Application
Name=$GAME
Comment=Skool Daze: Klass of 99
Exec="$DEST/run.sh"
Icon=$DEST/icon.png
Terminal=false
Categories=Game;
StartupWMClass=ko99.exe
EOF
  rm -f "$SHORTCUT"
  cp "$MENU" "$SHORTCUT"
  "$DEST/wine/bin/wine" --version >&2
)

[ "$(dpkg --print-architecture 2>/dev/null)" = arm64 ] ||
  fail "This installer is for 64-bit Raspberry Pi OS. This system is $(uname -m)."
[ -f "$RUNTIME" ] && [ -f "$ICON" ] ||
  fail "runtime.tar.xz and icon.png belong next to install.sh, and one of them is missing. Download the whole package again."

# The game's zip, if a valid one sits next to this script.
zip=$(find "$HERE" -maxdepth 1 -iname 'klassof99win*.zip' | sort | tail -1)
if [ -n "$zip" ] && ! is_game_zip "$zip"; then zip=; fi

step=welcome
manual_note="If you do not have $ZIP_NAME yet, open the game's website and download it there."
while [ "$step" != install ]; do
  case $step in
  welcome)
    if [ -e "$DEST/run.sh" ]; then
      choice=$(page --text="<b>$GAME is already installed on this Raspberry Pi.</b>\n\nReinstall sets it up again and keeps your saved settings. Remove deletes the game, its settings and its shortcuts." \
        --cancel-label="Cancel" --ok-label="Reinstall" --extra-button="Remove")
      status=$?
      if [ "$choice" = "Remove" ]; then
        rm -rf "$DEST" "$MENU" "$SHORTCUT"
        note "$GAME has been removed from this Raspberry Pi."
        exit 0
      fi
      [ "$status" -eq 0 ] || exit 0
    else
      found=
      [ -z "$zip" ] || found="\n\nThe game's zip file, $(basename "$zip"), is next to the installer and will be used."
      page --text="<b>Welcome to the $TITLE Installer</b>\n\nThis installer will set up $GAME, the Skool Daze remake by BitGlint Games, on this Raspberry Pi. It puts the game in the Games folder in your home folder, adds it to the Games menu and places a shortcut on the desktop.\n\nThe game needs about 130 MB of space.$found" \
        --cancel-label="Cancel" --ok-label="Next" || exit 0
      [ "$(df -k --output=avail "$HOME" | tail -1)" -ge 200000 ] ||
        fail "There is less than 200 MB free in your home folder. Free up some space and run the installer again."
    fi

    # Wine needs 4K memory pages. A Pi 5 or Pi 500 starts a 16K kernel unless told otherwise.
    if [ "$(getconf PAGESIZE)" != 4096 ]; then
      [ -f "$BOOTCFG" ] && [ -f /boot/firmware/kernel8.img ] ||
        fail "This system uses $(getconf PAGESIZE)-byte memory pages. Wine, which runs the game, needs 4096-byte pages."
      if grep -q '^kernel=kernel8.img' "$BOOTCFG"; then
        note "This Raspberry Pi is already set to start its 4K kernel. Restart it, then run the installer again."
        exit 0
      fi
      page --text="<b>This Raspberry Pi needs its 4K kernel for the game.</b>\n\nA Pi 5 or Pi 500 starts a kernel that uses 16K memory pages, and Wine, which runs the game, needs 4K pages. The installer will switch this Pi to the 4K kernel that is already on it, by adding three lines to $BOOTCFG.\n\nThe change takes effect after a restart. Run the installer again afterwards." \
        --cancel-label="Cancel" --ok-label="Switch Kernel" || exit 0
      printf '\n# 4K-page kernel, needed by Wine (added by the PiKlassOf99 installer)\n[pi5]\nkernel=kernel8.img\n[all]\n' |
        as_root tee -a "$BOOTCFG" >/dev/null || fail "The installer could not change $BOOTCFG."
      page --text="<b>The kernel is switched.</b>\n\nRestart this Raspberry Pi, then run the installer again." \
        --cancel-label="Later" --ok-label="Restart Now" && as_root systemctl reboot
      exit 0
    fi
    if [ -n "$zip" ]; then step=install; else step=source; fi
    ;;

  source)
    choice=$(page --text="<b>The game's files</b>\n\n$GAME is free from BitGlint Games, and the installer needs its zip file, $ZIP_NAME.\n\nThe installer can download it from the game's website now, or use a copy you already have." \
      --cancel-label="Back" --ok-label="Download Game Zip File" --extra-button="Choose Zip File to Use")
    if [ $? -eq 0 ]; then
      if fetch_game; then
        step=install
      else
        manual_note="The download did not work. Open the game's website and download $ZIP_NAME there."
        step=manual
      fi
    elif [ "$choice" = "Choose Zip File to Use" ]; then
      step=manual
    else
      step=welcome
    fi
    ;;

  manual)
    choice=$(page --text="<b>Choose the game's zip file</b>\n\n$manual_note\n\nThen choose the file here. Leave it zipped." \
      --cancel-label="Back" --ok-label="Open Website" --extra-button="Choose Zip File")
    if [ $? -eq 0 ]; then
      xdg-open "$GAME_URL" >/dev/null 2>&1 &
    elif [ "$choice" = "Choose Zip File" ]; then
      picked=$(zenity --file-selection --title="Choose the $GAME zip file" \
        --filename="$(xdg-user-dir DOWNLOAD 2>/dev/null || echo "$HOME")/" --file-filter="Zip files | *.zip *.ZIP" 2>/dev/null) || continue
      if is_game_zip "$picked"; then
        zip=$picked
        step=install
      else
        manual_note="$(basename "$picked") is not the $GAME download. The right zip file has KO99.exe inside it."
      fi
    else
      step=source
    fi
    ;;
  esac
done

log=$(mktemp)
{ install_files 2>"$log"; status=$?; echo 100; exit $status; } | busy --percentage=0 --text="Installing $GAME..."
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  fail "The install did not finish. Wine needs 64-bit Raspberry Pi OS 13 (trixie) or newer.

$(tail -5 "$log")"
fi
rm -f "$log"

page --text="<b>$GAME is installed.</b>\n\nIt is in the Games menu and on the desktop. The window size is set in the game under Options, Video Mode." \
  --cancel-label="Close" --ok-label="Play Now" && setsid "$DEST/run.sh" >/dev/null 2>&1 &
