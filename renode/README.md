# Running Keystone in Renode (WIP)

**`cd` to Keystone's source code directory first.**

## Commands to run

First, build keystone with the runall.sh script.

``` bash
docker run -it -m 2000m -v $(pwd):/work --network host keystoneenclaveorg/keystone:init-rv64gc /work/runall.sh
```

Secondly, start renode in headless mode.

``` bash
renode --disable-xwt -P 7891
```

output:

``` asciidoc
20:36:16.5146 [INFO] Loaded monitor commands from: /data/home/kevin/prog/renode_portable/scripts/monitor.py
20:36:16.5436 [INFO] Monitor available in telnet mode on port 7891
```

Then, in a new terminal window, attach to the renode monitor.

``` bash
telnet localhost 7891
```

In the monitor window, include the keystone_unleashed.resc script.

``` bash
i @renode/keystone_unleashed.resc
```

output:

``` asciidoc
20:36:40.5821 [INFO] Including script: /data/home/kevin/code/keystone/1019/renode/keystone_unleashed.resc
20:36:40.5962 [INFO] System bus created.
20:36:42.4279 [INFO] sysbus: Loading segment of 53861 bytes length at 0x1000.
20:36:42.4533 [INFO] e51: Setting PC value to 0x1000.
20:36:42.4537 [INFO] u54_1: Setting PC value to 0x1000.
20:36:42.4538 [INFO] u54_2: Setting PC value to 0x1000.
20:36:42.4540 [INFO] u54_3: Setting PC value to 0x1000.
20:36:42.4541 [INFO] u54_4: Setting PC value to 0x1000.
```

If you don't want to debug the program with GDB, then just run `s` to
start the emulation. Otherwise continue reading...

Now start the GDB server.

``` bash
machine StartGdbServer 3333
```

``` asciidoc
20:40:00.0793 [INFO] keystone-unleashed: GDB server with all CPUs started on port :3333
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

```

output:

``` asciidoc
Remote debugging using :3333
warning: multi-threaded target stopped without sending a thread-id, using first non-exited thread
0x0000000000001000 in _entry ()
```

The bootrom provided by Keystone (under the `bootrom` directory)
starts the execution at `0x1000` and assumes that the device tree is
loaded right after the bootrom. This is because QEMU (see
`qemu/hw/riscv/virt.c`) copies the device tree after bootrom. In our
case, we want to pass location of the device tree via `a1`
register. The `bootloader.S` in this branch has been changed to that
logic.

Execution will start from the `reset` label in `bootloader.S`, which
is specified in the following `bootload.lds` snippet:

``` linker-script
OUTPUT_ARCH( "riscv" )

ENTRY( _entry )

SECTIONS
{
  . = 0x1000; /* boot loader lives in boot ROM after the device tree */
  PROVIDE( reset_vector = . );
  .text :
  {
    PROVIDE( _entry = . );
    *(.reset)
...
```

`bootloader.S` will at some point call the `bootloader` function in
`bootloader.c`, let's set a breakpoint there and verify:

``` gdb
b bootloader
```

Remember to first tell renode to start the simulation (using `monitor
start`), then run `continue`:

```gdb
monitor start
c
```

output:

``` asciidoc
(gdb) b bootloader
Breakpoint 1 at 0x1206
(gdb) monitor start
Starting emulation...
(gdb) c
Continuing.

Thread 1 "keystone-unleashed.e51[0]" hit Breakpoint 1, 0x0000000000001206 in bootloader ()
```

The bootrom measures the first N bytes of the DRAM_BASE, signs
measurement with the device root key, stores the signed measurement
onto the DRAM, and then erases the device root key (or make it in
accessible until reset in a different way). This is all done by hart 0
(the e51 monitor core for HiFive Unleashed) while the other cores are
waiting.

After that, the bootrom jumps to the beginning of the DRAM:

``` assembly
// bootloader.S
  li t0, DRAM_BASE
  jr t0
```

Let's load the symbol table from `fw_payload.elf` in order to debug
the Keystone security monitor (based on OpenSBI):

``` gdb
(gdb) symbol-file /work/b/sm.build/platform/generic/firmware/fw_payload.elf
Reading symbols from /work/b/sm.build/platform/generic/firmware/fw_payload.elf...
```

The security monitor's entry point is the `_start` in
`sm/opensbi/firmware/fw_base.S`. Still, only the hart-0 core runs the
initialization, all other harts will be stuck at `wait_coldboot`.

Hart 0 eventually gets to `sbi_hart_switch_mode` and then jumps to the
beginning of the payload (i.e. the Linux kernel) while lowering the
privilege mode to `S` using `mret`:

``` c++
// in sm/opensbi/lib/sbi/sbi_hart.c
void __attribute__((noreturn))
sbi_hart_switch_mode(unsigned long arg0, unsigned long arg1,
     unsigned long next_addr, unsigned long next_mode,
     bool next_virt)
{
   // ...
   register unsigned long a0 asm("a0") = arg0;
   register unsigned long a1 asm("a1") = arg1;
   __asm__ __volatile__("mret" : : "r"(a0), "r"(a1));
   __builtin_unreachable();
}
```

I got lost after this point: the kernel booting process seems to be
stuck at ???.

``` gdb
(gdb) c
Continuing.
^C
Thread 1 "keystone-unleashed.e51[0]" received signal SIGTRAP, Trace/breakpoint trap.
0x0000000080005080 in atomic_read (atom=atom@entry=0x80032060) at /work/sm/opensbi/lib/sbi/riscv_atomic.c:17
17              long ret = atom->counter;
(gdb) info stack
#0  0x0000000080005080 in atomic_read (atom=atom@entry=0x80032060) at /work/sm/opensbi/lib/sbi/riscv_atomic.c:17
#1  0x000000008000b112 in sbi_hsm_hart_wait (hartid=4, scratch=0x80032060) at /work/sm/opensbi/lib/sbi/sbi_hsm.c:145
#2  sbi_hsm_init (scratch=scratch@entry=0x80032000, hartid=hartid@entry=4, cold_boot=cold_boot@entry=0)
    at /work/sm/opensbi/lib/sbi/sbi_hsm.c:180
    #3  0x000000008000093a in init_warmboot (hartid=4, scratch=0x80032000) at /work/sm/opensbi/lib/sbi/sbi_init.c:325
    #4  sbi_init (scratch=0x80032000) at /work/sm/opensbi/lib/sbi/sbi_init.c:427
    #5  0x00000000800004b6 in _start_warm () at /work/sm/opensbi/firmware/fw_base.S:443
    Backtrace stopped: frame did not save the PC
(gdb) info thread
Id   Target Id                              Frame
* 1    Thread 1 "keystone-unleashed.e51[0]"   0x0000000080005080 in atomic_read (atom=atom@entry=0x80032060)
  at /work/sm/opensbi/lib/sbi/riscv_atomic.c:17
  2    Thread 2 "keystone-unleashed.u54_1[1]" 0x0000000080005080 in atomic_read (atom=atom@entry=0x80038060)
  at /work/sm/opensbi/lib/sbi/riscv_atomic.c:17
  3    Thread 3 "keystone-unleashed.u54_2[2]" 0x0000000080005080 in atomic_read (atom=atom@entry=0x80036060)
  at /work/sm/opensbi/lib/sbi/riscv_atomic.c:17
  4    Thread 4 "keystone-unleashed.u54_3[3]" 0x0000000080005080 in atomic_read (atom=atom@entry=0x80034060)
  at /work/sm/opensbi/lib/sbi/riscv_atomic.c:17
  5    Thread 5 "keystone-unleashed.u54_4[4]" 0x0000000080005080 in atomic_read (atom=atom@entry=0x80032060)
  at /work/sm/opensbi/lib/sbi/riscv_atomic.c:17

(gdb) thread 2
[Switching to thread 2 (Thread 2)]
#0  0x0000000080005080 in atomic_read (atom=atom@entry=0x80038060) at /work/sm/opensbi/lib/sbi/riscv_atomic.c:17
17              long ret = atom->counter;
(gdb) info stack
#0  0x0000000080005080 in atomic_read (atom=atom@entry=0x80038060) at /work/sm/opensbi/lib/sbi/riscv_atomic.c:17
#1  0x000000008000b112 in sbi_hsm_hart_wait (hartid=1, scratch=0x80038060) at /work/sm/opensbi/lib/sbi/sbi_hsm.c:145
#2  sbi_hsm_init (scratch=scratch@entry=0x80038000, hartid=hartid@entry=1, cold_boot=cold_boot@entry=0)
    at /work/sm/opensbi/lib/sbi/sbi_hsm.c:180
#3  0x000000008000093a in init_warmboot (hartid=1, scratch=0x80038000) at /work/sm/opensbi/lib/sbi/sbi_init.c:325
#4  sbi_init (scratch=0x80038000) at /work/sm/opensbi/lib/sbi/sbi_init.c:427
#5  0x00000000800004b6 in _start_warm () at /work/sm/opensbi/firmware/fw_base.S:443
Backtrace stopped: frame did not save the PC

(gdb) thread 4
[Switching to thread 4 (Thread 4)]
#0  0x0000000080005080 in atomic_read (atom=atom@entry=0x80034060) at /work/sm/opensbi/lib/sbi/riscv_atomic.c:17
17              long ret = atom->counter;
(gdb) info stack
#0  0x0000000080005080 in atomic_read (atom=atom@entry=0x80034060) at /work/sm/opensbi/lib/sbi/riscv_atomic.c:17
#1  0x000000008000b112 in sbi_hsm_hart_wait (hartid=3, scratch=0x80034060) at /work/sm/opensbi/lib/sbi/sbi_hsm.c:145
#2  sbi_hsm_init (scratch=scratch@entry=0x80034000, hartid=hartid@entry=3, cold_boot=cold_boot@entry=0)
    at /work/sm/opensbi/lib/sbi/sbi_hsm.c:180
#3  0x000000008000093a in init_warmboot (hartid=3, scratch=0x80034000) at /work/sm/opensbi/lib/sbi/sbi_init.c:325
#4  sbi_init (scratch=0x80034000) at /work/sm/opensbi/lib/sbi/sbi_init.c:427
#5  0x00000000800004b6 in _start_warm () at /work/sm/opensbi/firmware/fw_base.S:443
Backtrace stopped: frame did not save the PC
```

Sometimes it shows a different place for the e51 core:

``` gdb
(gdb) c
Continuing.
^C
Thread 1 "keystone-unleashed.e51[0]" received signal SIGTRAP, Trace/breakpoint trap.
[Switching to Thread 1]
0xffffffe0000035c6 in ?? ()
(gdb) info thread
  Id   Target Id                              Frame
  * 1    Thread 1 "keystone-unleashed.e51[0]"   0xffffffe0000035c6 in ?? ()
    2    Thread 2 "keystone-unleashed.u54_1[1]" 0x0000000080005080 in atomic_read (atom=atom@entry=0x80038060)
        at /work/sm/opensbi/lib/sbi/riscv_atomic.c:17
    3    Thread 3 "keystone-unleashed.u54_2[2]" 0x0000000080005080 in atomic_read (atom=atom@entry=0x80036060)
        at /work/sm/opensbi/lib/sbi/riscv_atomic.c:17
    4    Thread 4 "keystone-unleashed.u54_3[3]" 0x0000000080005080 in atomic_read (atom=atom@entry=0x80034060)
        at /work/sm/opensbi/lib/sbi/riscv_atomic.c:17
    5    Thread 5 "keystone-unleashed.u54_4[4]" 0x0000000080005080 in atomic_read (atom=atom@entry=0x80032060)
        at /work/sm/opensbi/lib/sbi/riscv_atomic.c:17
```

`0xffffffe0000035c6` is inside `setup_smp()`:

``` assembly
ffffffe00000353a <setup_smp>:
ffffffe00000353a:       7139                    addi    sp,sp,-64
ffffffe00000353c:       fc06                    sd      ra,56(sp)
...
ffffffe0000035c0:       b77d                    j       ffffffe00000356e <setup_smp+0x34>
ffffffe0000035c2:       00099363                bnez    s3,ffffffe0000035c8 <setup_smp+0x8e>
ffffffe0000035c6:       9002                    ebreak
ffffffe0000035c8:       a5c18993                addi    s3,gp,-1444 # ffffffe00166bc1c <nr_cpu_ids>
ffffffe0000035cc:       0009a603                lw      a2,0(s3)
ffffffe0000035d0:       01267b63                bgeu    a2,s2,ffffffe0000035e6 <setup_smp+0xac>
```

Here is the full output:

``` asciidoc
20:36:42.4533 [INFO] e51: Setting PC value to 0x1000.
20:36:42.4537 [INFO] u54_1: Setting PC value to 0x1000.
20:36:42.4538 [INFO] u54_2: Setting PC value to 0x1000.
20:36:42.4540 [INFO] u54_3: Setting PC value to 0x1000.
20:36:42.4541 [INFO] u54_4: Setting PC value to 0x1000.
20:40:00.0793 [INFO] keystone-unleashed: GDB server with all CPUs started on port :3333
21:05:42.9739 [INFO] keystone-unleashed: Machine started.
21:25:08.7766 [WARNING] e51: Reading from CSR #960 that is not implemented.
21:25:08.8784 [INFO] uart0: [host: 2.91ks (+2.91ks)|virt: 9.75s (+9.75s)]
21:25:08.8802 [INFO] uart0: [host: 2.91ks (+1.71ms)|virt:    9.75s (+0s)] OpenSBI v0.8
21:25:08.8809 [INFO] uart0: [host: 2.91ks (+0.81ms)|virt: 9.75s (+0.1ms)]    ____                    _____ ____ _____
21:25:08.8811 [INFO] uart0: [host: 2.91ks (+0.24ms)|virt:    9.75s (+0s)]   / __ \                  / ____|  _ \_   _|
21:25:08.8816 [INFO] uart0: [host: 2.91ks (+0.51ms)|virt: 9.75s (+0.1ms)]  | |  | |_ __   ___ _ __ | (___ | |_) || |
21:25:08.8818 [INFO] uart0: [host: 2.91ks (+0.25ms)|virt:    9.75s (+0s)]  | |  | | '_ \ / _ \ '_ \ \___ \|  _ < | |
21:25:08.8823 [INFO] uart0: [host: 2.91ks (+0.48ms)|virt: 9.75s (+0.1ms)]  | |__| | |_) |  __/ | | |____) | |_) || |_
21:25:08.8826 [INFO] uart0: [host: 2.91ks (+0.24ms)|virt:    9.75s (+0s)]   \____/| .__/ \___|_| |_|_____/|____/_____|
21:25:08.8827 [INFO] uart0: [host:   2.91ks (+87?s)|virt:    9.75s (+0s)]         | |
21:25:08.8828 [INFO] uart0: [host:   2.91ks (+85?s)|virt:    9.75s (+0s)]         |_|
21:25:08.8829 [INFO] uart0: [host:   2.91ks (+25?s)|virt:    9.75s (+0s)]
21:25:09.3100 [WARNING] plic: Unhandled write to offset 0x200000, value 0x7.
21:25:10.2389 [INFO] uart0: [host:  2.91ks (+1.36s)|virt: 10.1s (+0.35s)] Platform Name             : sifive,hifive-unl
eashed-a00
21:25:10.2404 [INFO] uart0: [host: 2.91ks (+1.53ms)|virt:    10.1s (+0s)] Platform Features         : timer,mfdeleg
21:25:10.2411 [INFO] uart0: [host: 2.91ks (+0.67ms)|virt: 10.1s (+0.1ms)] Platform HART Count       : 5
21:25:10.2419 [INFO] uart0: [host: 2.91ks (+0.76ms)|virt:    10.1s (+0s)] Firmware Base             : 0x80000000
21:25:10.2424 [INFO] uart0: [host:  2.91ks (+0.5ms)|virt: 10.1s (+0.1ms)] Firmware Size             : 236 KB
21:25:10.2427 [INFO] uart0: [host: 2.91ks (+0.39ms)|virt:    10.1s (+0s)] Runtime SBI Version       : 0.2
21:25:10.2428 [INFO] uart0: [host:   2.91ks (+86?s)|virt:    10.1s (+0s)]
21:25:10.2654 [INFO] uart0: [host: 2.91ks (+22.6ms)|virt: 10.11s (+5.4ms)] Domain0 Name              : root
21:25:10.2657 [INFO] uart0: [host: 2.91ks (+0.26ms)|virt:    10.11s (+0s)] Domain0 Boot HART         : 0
21:25:10.2679 [INFO] uart0: [host: 2.91ks (+2.26ms)|virt: 10.11s (+0.1ms)] Domain0 HARTs             : 0*,1*,2*,3*,4*
21:25:10.2697 [INFO] uart0: [host: 2.91ks (+1.81ms)|virt: 10.11s (+0.1ms)] Domain0 Region00          : 0x0000000080000000-0x000000008003ffff ()
21:25:10.2710 [INFO] uart0: [host: 2.91ks (+1.24ms)|virt: 10.11s (+0.1ms)] Domain0 Region01          : 0x0000000000000000-0xffffffffffffffff (R,W,X)
21:25:10.2716 [INFO] uart0: [host: 2.91ks (+0.62ms)|virt: 10.11s (+0.1ms)] Domain0 Next Address      : 0x0000000080200000
21:25:10.2719 [INFO] uart0: [host: 2.91ks (+0.31ms)|virt:    10.11s (+0s)] Domain0 Next Arg1         : 0x0000000082200000
21:25:10.2725 [INFO] uart0: [host: 2.91ks (+0.62ms)|virt: 10.11s (+0.1ms)] Domain0 Next Mode         : S-mode
21:25:10.2729 [INFO] uart0: [host: 2.91ks (+0.33ms)|virt:    10.11s (+0s)] Domain0 SysReset          : yes
21:25:10.2731 [INFO] uart0: [host:  2.91ks (+0.2ms)|virt:    10.11s (+0s)]
21:25:10.2756 [INFO] uart0: [host: 2.91ks (+2.59ms)|virt:    10.11s (+0s)] [SM] Initializing ... hart [0]
21:25:10.2824 [INFO] uart0: [host:  2.91ks (+6.7ms)|virt: 10.11s (+0.1ms)] [SM] Keystone security monitor has been initialized!
21:25:10.3841 [INFO] uart0: [host:   2.91ks (+0.1s)|virt: 10.13s (+24.5ms)] Boot HART ID              : 0
21:25:10.3846 [INFO] uart0: [host: 2.91ks (+0.53ms)|virt:  10.13s (+0.1ms)] Boot HART Domain          : root
21:25:10.3856 [INFO] uart0: [host: 2.91ks (+1.04ms)|virt:     10.13s (+0s)] Boot HART ISA             : rv64imacs
21:25:10.3869 [INFO] uart0: [host: 2.91ks (+1.25ms)|virt:  10.13s (+0.1ms)] Boot HART Features        : scounteren,mcounteren,time
21:25:10.3873 [INFO] uart0: [host: 2.91ks (+0.42ms)|virt:  10.13s (+0.1ms)] Boot HART PMP Count       : 16
21:25:10.3877 [INFO] uart0: [host: 2.91ks (+0.44ms)|virt:     10.13s (+0s)] Boot HART PMP Granularity : 4
21:25:10.3881 [INFO] uart0: [host: 2.91ks (+0.34ms)|virt:     10.13s (+0s)] Boot HART PMP Address Bits: 54
21:25:10.3885 [INFO] uart0: [host: 2.91ks (+0.46ms)|virt:  10.13s (+0.1ms)] Boot HART MHPM Count      : 0
21:25:10.3888 [INFO] uart0: [host: 2.91ks (+0.28ms)|virt:     10.13s (+0s)] Boot HART MHPM Count      : 0
21:25:10.3894 [INFO] uart0: [host: 2.91ks (+0.62ms)|virt:  10.13s (+0.1ms)] Boot HART MIDELEG         : 0x0000000000000222
21:25:10.3898 [INFO] uart0: [host: 2.91ks (+0.37ms)|virt:     10.13s (+0s)] Boot HART MEDELEG         : 0x000000000000b109
```

### 2021-11-14

Here is a new round of debugging after recompiling Linux kernel, what used to be `0xffffffe0000035c6` is now `0xffffffe00000358e`.

```gdb
(gdb) c
Continuing.
^C
Thread 1 "keystone-unleashed.e51[0]" received signal SIGTRAP, Trace/breakpoint trap.            
0xffffffe00000358e in setup_smp ()            
(gdb) info thread                             
  Id   Target Id                              Frame
* 1    Thread 1 "keystone-unleashed.e51[0]"   0xffffffe00000358e in setup_smp ()
  2    Thread 2 "keystone-unleashed.u54_1[1]" 0x0000000080005080 in ?? ()
  3    Thread 3 "keystone-unleashed.u54_2[2]" 0x0000000080005080 in ?? ()
  4    Thread 4 "keystone-unleashed.u54_3[3]" 0x0000000080005080 in ?? ()
  5    Thread 5 "keystone-unleashed.u54_4[4]" 0x0000000080005080 in ?? ()
(gdb) symbol-file b/linux.build/vmlinux
Reading symbols from b/linux.build/vmlinux...    
(No debugging symbols found in b/linux.build/vmlinux)   
(gdb) x/10i $pc-12
   0xffffffe000003582 <setup_smp+72>:    jalr        -6(ra)
   0xffffffe000003586 <setup_smp+76>:    mv  s1,a0
   0xffffffe000003588 <setup_smp+78>:    j   0xffffffe000003536 <vdso_init+234>
   0xffffffe00000358a <setup_smp+80>:    bnez        s3,0xffffffe000003590 <setup_smp+86>
=> 0xffffffe00000358e <setup_smp+84>:   ebreak
   0xffffffe000003590 <setup_smp+86>:    addi        s3,gp,-1476
   0xffffffe000003594 <setup_smp+90>:    lw  a2,0(s3)
   0xffffffe000003598 <setup_smp+94>:    bgeu        a2,s2,0xffffffe0000035ae <setup_smp+116>
   0xffffffe00000359c <setup_smp+98>:    mv  a1,s2
   0xffffffe00000359e <setup_smp+100>:    auipc       a0,0xb38
(gdb) l *(0xffffffe00000358e)
No symbol table is loaded.  Use the "file" command.
```

Interestingly, when I load vmlinux from another GDB session without remote debugging, the symbols loaded successfully:

```gdb
n-elf-gdb b/linux.build/vmlinux
GNU gdb (GDB) 10.1
Copyright (C) 2020 Free Software Foundation, Inc.
License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.   
Type "show copying" and "show warranty" for details.
This GDB was configured as "--host=x86_64-pc-linux-gnu --target=riscv64-unknown-elf".
Type "show configuration" for configuration details.
For bug reporting instructions, please see:<https://www.gnu.org/software/gdb/bugs/>.
Find the GDB manual and other documentation resources online at:
    <http://www.gnu.org/software/gdb/documentation
/>.   

For help, type "help".
Type "apropos word" to search for commands related to "word"...
Reading symbols from b/linux.build/vmlinux...
warning: File "/work/.gdbinit" auto-loading has been declined by your `auto-
load safe-path' set to "$debugdir:$datadir/auto-load".
To enable execution of this file add
        add-auto-load-safe-path /work/.gdbinit
line to your configuration file "/root/.gdbinit".
To completely disable this security protection add
        set auto-load safe-path /
line to your configuration file "/root/.gdbinit".
For more information about this security protection see the
--Type <RET> for more, q to quit, c to continue without paging--
"Auto-loading safe path" section in the GDB manual.  E.g., run from the shel
l:      
        info "(gdb)Auto-loading safe path"
(gdb) l *(0xffffffe00000358e)   
0xffffffe00000358e is in setup_smp (/work/linux/arch/riscv/kernel/smpboot.c:95).
90
91                      cpuid_to_hartid_map(cpuid) = hart;
92                      cpuid++;
93              }       
94              
95              BUG_ON(!found_boot_cpu);
96              
97              if (cpuid > nr_cpu_ids)
98                      pr_warn("Total number of cpus [%d] is greater than nr_cpus option value [%d]\n",
99                              cpuid, nr_cpu_ids);
```

## Misc

See https://renode.readthedocs.io/en/latest/basic/running.html for
relevant documentations.
