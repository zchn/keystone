#!/bin/bash

apt update && apt install apt-transport-https ca-certificates python3-pip -y && update-ca-certificates

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
    # cmake .. && \
    # make && \
    make image && \
    make run-tests-in-renode
