# Running Keystone in Renode (WIP)

## Commands to run

First, build keystone with the runall.sh script.

``` bash
docker run -it -m 2000m -v $(pwd):/work --network host keystoneenclaveorg/keystone:init-rv64gc /work/runall.sh
```

Secondly, start renode in headless mode.

``` bash
renode --disable-xwt -P 7891
```

Then, in a new terminal window, attach to the renode monitor.

``` bash
telnet localhost 7891
```

In the monitor window, include the keystone_unleashed.resc script.

``` bash
i @renode/keystone_unleashed.resc
```

If you don't want to debug the program with GDB, then just run `s` to
start the emulation. Otherwise continue reading...

Now start the GDB server.

``` bash
machine StartGdbServer 3333
```

Now use GDB to connect. We still use the same keystone docker image to run GDB.

``` bash
docker run -it -m 2000m -v $(pwd):/work --network host keystoneenclaveorg/keystone:init-rv64gc bash
```

In this bash, run GDB.

``` bash
apt update && apt install -y libpython2.7
/work/riscv64/bin/riscv64-unknown-elf-gdb /work/b/bootrom.build/bootrom.elf
# or this if you want to debug the security monitor or linux kernel:
/work/riscv64/bin/riscv64-unknown-elf-gdb /work/b/sm.build/platform/generic/firmware/fw_payload.elf
```

In GDB, connect to the server, set breakpoint, then run.

``` gdb
target remote :3333
b *0x101a
monitor start
c
```

## Misc

See https://renode.readthedocs.io/en/latest/basic/running.html for relevant documentations.
