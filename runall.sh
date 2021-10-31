#!/bin/bash

apt update && apt install apt-transport-https ca-certificates -y && update-ca-certificates

export RISCV=/work/riscv64
export PATH=/work/riscv64/bin:$PATH
cd /work
# source source.sh
./fast-setup.sh && \
    source ./source.sh && \
    mkdir -p b/sdk.build
cd b/sdk.build && \
    cmake ../../sdk && \
    make && make install && \
    cd .. && \
    cmake .. -DLINUX_SIFIVE=y && \
    make && \
    make image
