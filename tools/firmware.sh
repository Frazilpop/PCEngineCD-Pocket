#!/bin/sh
# PC Engine CD for Analogue Pocket: build the MPU's firmware.
#
#   tools/firmware.sh            build src/cdfw into dist's pce_mpu_bios.bin
#   tools/firmware.sh --check    build 0.2.3's source from git, and compare it
#                                with the binary 0.2.3 shipped
#
# The firmware is C++ for the core's small RISC-V CPU (rv32imac), and the Pocket
# loads it from the card, so a firmware change needs no Quartus. The compiler is
# Ubuntu 24.04's GCC 13.2 in Docker, with which PR 69's author got 0.2.3's binary
# byte for byte; the image is made here the first time, under Colima as a Quartus
# build is. Afterwards the size is checked against the 64K the CPU has.

set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
image=pce-riscv:13
out=$repo/dist/Assets/pcecd/frazilpop.PCEngineCD/pce_mpu_bios.bin

if ! colima status >/dev/null 2>&1; then
    echo "== starting Colima"
    colima start
    touch "$HOME/.colima/started-for-build"
fi
if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "== making the compiler's image (once; some minutes)"
    printf 'FROM ubuntu:24.04\nRUN apt-get update -qq && apt-get install -y -qq --no-install-recommends gcc-riscv64-unknown-elf libnewlib-dev picolibc-riscv64-unknown-elf make >/dev/null && rm -rf /var/lib/apt/lists/*\n' \
        | docker build -q -t "$image" -
fi

run() { # <source folder>
    mkdir -p "$repo/build"
    docker run --rm -v "$HOME":"$HOME" -w "$1" "$image" sh ./build.sh
}

if [ "${1:-}" = "--check" ]; then
    tmp=$repo/build/fw-check
    rm -rf "$tmp"; mkdir -p "$tmp"
    git -C "$repo" archive 6803fdd src/cdfw | tar -x -C "$tmp"
    git -C "$repo" show a1588ac:src/cdfw/drivers/cue/cue.cpp > "$tmp/src/cdfw/drivers/cue/cue.cpp"
    run "$tmp/src/cdfw"
    git -C "$repo" show 'a1588ac:dist/Assets/pcecd/Mazamars312.PC Engine CD/pce_mpu_bios.bin' > "$tmp/shipped.bin"
    if cmp "$tmp/src/cdfw/app/build.riscv.pce_mpu_bios/pce_mpu_bios.bin" "$tmp/shipped.bin"; then
        echo "== the same, byte for byte: 0.2.3's binary is its source"
    else
        echo "== they differ"; exit 1
    fi
    exit 0
fi

run "$repo/src/cdfw"
bin=$repo/src/cdfw/app/build.riscv.pce_mpu_bios/pce_mpu_bios.bin
elf=$repo/src/cdfw/app/build.riscv.pce_mpu_bios/pce_mpu_bios
cp "$bin" "$out"
echo "== written: $out, $(wc -c < "$out") bytes"
docker run --rm -v "$HOME":"$HOME" "$image" riscv64-unknown-elf-size "$elf"
