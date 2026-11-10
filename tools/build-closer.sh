#!/bin/sh
# Builds Closer.exe and Closer.dll from tools/closer.c with zig (https://ziglang.org),
# on any machine. Both are 32-bit Windows code with no C runtime, like the game, so zig
# only lends its compiler and its Windows headers.
set -e
cd "$(dirname "$0")/.."
headers=$(dirname "$(readlink -f "$(command -v zig)")")/lib/libc/include/any-windows-any
build() { zig cc -target x86-windows-gnu -nostdlib -isystem "$headers" -Os -s -fno-builtin -fno-sanitize=undefined "$@" tools/closer.c -lkernel32 -luser32; }
build -o Closer.exe -Wl,--subsystem,windows -Wl,-e,closer_main
build -o Closer.dll -shared -DCLOSER_DLL
rm -f closer.lib Closer.lib   # the import library the linker writes alongside
ls -l Closer.exe Closer.dll
