#!/bin/bash

export RISCV=/work/riscv64
export PATH=/work/riscv64/bin:$PATH
cd /work
./fast-setup.sh && \
    source ./source.sh && \
    mkdir -p b/sdk.build
cd b/sdk.build && \
    cmake ../../sdk && \
    make && make install && \
    cd .. && \
    cmake .. -DLINUX_SIFIVE=y && \
    make image && \
    make run-tests-in-renode
