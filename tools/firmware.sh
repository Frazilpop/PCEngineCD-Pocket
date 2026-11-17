#!/bin/sh
# PC Engine CD for Analogue Pocket: build the MPU's firmware.
#
#   tools/firmware.sh            build src/cdfw into dist's pce_mpu_bios.bin
#
# The firmware is C++ for the core's small RISC-V CPU (rv32imac), and the Pocket
# loads it from the card, so a firmware change needs no Quartus. The compiler is
# Ubuntu 24.04's GCC 13.2 in Docker, which rebuilt Mazamars312's 0.2.3 binary
# byte for byte from its source; the image is made here the first time, under
# Colima as a Quartus build is. Afterwards the size is checked against the 64K the CPU has.

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
    # clean each time: make doesn't follow the makefile's flags or the linker script
    docker run --rm -v "$HOME":"$HOME" -w "$1" "$image" sh -c 'sh ./build.sh clean && sh ./build.sh'
}

run "$repo/src/cdfw"
bin=$repo/src/cdfw/app/build.riscv.pce_mpu_bios/pce_mpu_bios.bin
elf=$repo/src/cdfw/app/build.riscv.pce_mpu_bios/pce_mpu_bios
# lib/'s memset, memcpy and so on are loops. A compiler that makes one of those
# loops a call to the function hangs the MPU at the first call, and make test
# can't see it, as it runs on the Mac's own. 0.3.0 had this until 4390df9.
lst=$repo/src/cdfw/app/build.riscv.pce_mpu_bios/pce_mpu_bios.lst
self=$(awk '/^[0-9a-f]+ <.*>:$/ { fn = $2; sub(/:$/, "", fn) }
            /\t(jal|j)\t/ && $NF == fn && fn !~ /_exit_loop/ { print fn }' "$lst" | sort -u)
if [ -n "$self" ]; then
    echo "== these call themselves, and shouldn't: $self"; exit 1
fi

cp "$bin" "$out"
echo "== written: $out, $(wc -c < "$out") bytes"
docker run --rm -v "$HOME":"$HOME" "$image" riscv64-unknown-elf-size "$elf"
