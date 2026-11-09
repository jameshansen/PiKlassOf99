#!/bin/bash
# Trims a full Hangover (Wine) install down to the files Klass of 99 opens.
# Runs on a 64-bit Raspberry Pi with a 4K-page kernel and about 6 GB free.
# Inputs, made by hand first (see "Building the runtime" in README.md):
#   ~/ko99-build/root/usr      full Hangover, extracted from its .debs (2.4 GB)
#   ~/ko99-build/prefix-full   Wine prefix created by that full Wine (2.3 GB)
#   ~/ko99-build/trace*.log    strace logs of the game running under the full Wine
# Output: ~/ko99-build/runtime/{wine,prefix}, ready for pack-runtime.sh.
set -euo pipefail

B=$HOME/ko99-build
FULL=$B/root/usr
FULLPFX=$B/prefix-full
OUT=$B/runtime

rm -rf "$OUT"
mkdir -p "$OUT/wine" "$OUT/prefix"

# 1. Every file the traced runs opened or executed.
{
  cat "$B"/trace*.log | grep -oE '= [0-9]+<[^>]+>$' | sed -E 's/^= [0-9]+<//; s/>$//'
  cat "$B"/trace*.log | grep -oE 'execve\("[^"]+"' | sed -E 's/^execve\("//; s/"$//' | xargs -d '\n' -r realpath -q || true
} | sort -u > "$B/all.txt"

# 2. Wine: copy only the traced files.
add_wine() {  # path relative to the Wine tree
  [ -f "$FULL/$1" ] || return 0
  [ -e "$OUT/wine/$1" ] || (cd "$FULL" && cp -a --parents "$1" "$OUT/wine/")
}
grep "^$FULL/" "$B/all.txt" | sed "s|^$FULL/||" | while read -r rel; do add_wine "$rel"; done

# 3. Prefix: folders, registry, and the traced files. Files identical to a Wine DLL
#    become symlinks into the runtime's Wine, so each DLL is stored once.
(cd "$FULLPFX" && find drive_c -type d -print0 | (cd "$OUT/prefix" && xargs -0 mkdir -p))
(cd "$FULLPFX" && find drive_c -type l -print0 | xargs -0 -r cp -a --parents -t "$OUT/prefix")
mkdir -p "$OUT/prefix/dosdevices"
ln -s ../drive_c "$OUT/prefix/dosdevices/c:"
ln -s / "$OUT/prefix/dosdevices/z:"
cp -a "$FULLPFX"/{system.reg,user.reg,userdef.reg} "$OUT/prefix/"
echo disable > "$OUT/prefix/.update-timestamp"   # never try to rebuild the prefix from the trimmed Wine

grep "^$FULLPFX/drive_c/" "$B/all.txt" | sed "s|^$FULLPFX/||" | while read -r rel; do
  src=$FULLPFX/$rel
  [ -f "$src" ] && [ ! -L "$src" ] || continue
  name=$(basename "$rel")
  linked=
  for arch in aarch64-windows i386-windows; do
    lib=lib/wine/$arch/$name
    if [ -f "$FULL/$lib" ] && cmp -s "$src" "$FULL/$lib"; then
      add_wine "$lib"
      ln -s "$(realpath --relative-to="$(dirname "$OUT/prefix/$rel")" "$OUT/wine/$lib")" "$OUT/prefix/$rel"
      linked=1
      break
    fi
  done
  [ -n "$linked" ] || cp -a "$src" "$OUT/prefix/$rel"
done

# 4. Cut the debug data off every DLL (most of Hangover's size). GNU strip rewrites
#    ARM64 PE files and leaves Wine warning about their relocations, so this only
#    truncates the trailing .debug_* sections and leaves every other byte alone.
find "$OUT/wine/lib/wine/aarch64-windows" "$OUT/wine/lib/wine/i386-windows" -type f -print0 | xargs -0 python3 -c '
import struct, sys
for path in sys.argv[1:]:
    d = bytearray(open(path, "rb").read())
    pe = struct.unpack_from("<I", d, 0x3c)[0] if d[:2] == b"MZ" else 0
    if not pe or d[pe:pe + 4] != b"PE\0\0":
        continue
    nsec, symtab, nsym, optsz = struct.unpack_from("<H4xIIH", d, pe + 6)
    opt = pe + 24
    table = opt + optsz
    strtab = symtab + nsym * 18
    secs = [struct.unpack_from("<8sIIII", d, table + i * 40) for i in range(nsec)]
    def name(raw):
        raw = raw.rstrip(b"\0")
        if raw[:1] == b"/" and symtab:  # long name, kept in the string table
            o = strtab + int(raw[1:])
            raw = bytes(d[o:d.index(0, o)])
        return raw
    keep = nsec
    while keep and name(secs[keep - 1][0]).startswith((b".debug", b".zdebug", b".gnu_debug")):
        keep -= 1
    if keep == nsec or any(name(s[0]) != s[0].rstrip(b"\0") for s in secs[:keep]):
        continue  # nothing to cut, or a kept section still needs the string table
    end = max(ro + rs for _, _, _, rs, ro in secs[:keep])
    _, vsize, va, _, _ = secs[keep - 1]
    align = struct.unpack_from("<I", d, opt + 32)[0]
    struct.pack_into("<H", d, pe + 6, keep)                             # NumberOfSections
    struct.pack_into("<II", d, pe + 12, 0, 0)                           # no COFF symbols
    struct.pack_into("<I", d, opt + 56, -(-(va + vsize) // align) * align)  # SizeOfImage
    d[table + keep * 40:table + nsec * 40] = bytes((nsec - keep) * 40)
    open(path, "wb").write(d[:end])
'
find "$OUT/wine/bin" "$OUT/wine/lib/wine/aarch64-unix" -type f -exec strip --strip-debug {} +

du -sh "$OUT/wine" "$OUT/prefix"
echo "files: $(find "$OUT" -type f | wc -l), symlinks: $(find "$OUT/prefix" -type l | wc -l)"
