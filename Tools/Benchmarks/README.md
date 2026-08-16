# QEMU TCG A/B benchmark plan (Omarchy x86_64 on Apple Silicon)

Host measured for this plan: Apple M2 (4P + 4E), 16 GB, macOS 26.6.1,
QEMU 11.1.0 from `/opt/homebrew/opt/qemu`, SimpleVM library in
`~/Library/Application Support/SimpleVM`.

Guest: `omarchy-4.0.0`, x86_64, 4 vCPU / 4 GiB in the library spec, 64 GiB raw
disk (7.2 GB allocated), Limine bootloader, **LUKS-encrypted root** — the boot
stops at `A password is required to access the root volume` until a human types
the passphrase.

## 0. Non-destructive contract

`tcgbench.py` never starts, stops, or mutates a SimpleVM machine:

| Guarantee | Mechanism |
|---|---|
| Guest disk never written | `qemu-img create -f qcow2 -F raw -b disk.raw overlay.qcow2`; QEMU opens the backing file read-only, every write lands in the overlay, which is deleted after each run |
| EFI variables never written | `efi-vars.fd` is copied into the run directory; the machine's own copy is untouched |
| No collisions with SimpleVM | own VNC port from 5950+, own loopback TCP QMP and serial ports (SimpleVM uses 5900+ and UNIX sockets) |
| No concurrent access | refuses to start if `library.json` records the machine as running, or if any non-bench `qemu-system` process references the same `disk.raw` (`--allow-concurrent` overrides deliberately) |
| No passphrase, ever | `boot-to-luks` stops at the prompt and issues QMP `quit`; keys are injected only in the separate `input-latency` profile, at the bootloader menu, before LUKS |
| Bounded disk use | overlays stay ~100 MB and are deleted per run — important, only ~19 GB free |

Verified on this machine: after a full `boot-to-luks` run, `disk.raw` and
`QEMU/efi-vars.fd` mtimes were unchanged and no QEMU process was left behind.

## 1. Baseline under test

`QEMUConfigurationBuilder.make()` (Packages/SimpleVMCore/.../QEMUConfiguration.swift):

```
-machine q35,hpet=off -accel tcg,tb-size=1024 -cpu max -smp min(cpu,2) -m 4096
-display none -vnc 127.0.0.1:N -device virtio-vga,xres=1280,yres=800
-drive if=none,id=system-disk,...,cache=writeback,aio=threads,discard=unmap,detect-zeroes=unmap
```

Measured fact that shapes the whole matrix: **MTTCG is not active on this host**.
`query-cpus-fast` reports one shared `thread-id` for every vCPU with
`thread=multi`, `thread=single`, and the default — x86 (TSO) on aarch64 (weak
ordering) falls back to round-robin TCG, so all vCPUs time-slice a single host
thread. Consequences: extra vCPUs cannot add throughput, only round-robin
overhead, and single-thread P-core residency dominates host-side behaviour.

Reference numbers from a validation run (baseline, n=1): firmware serial at
1.42 s, Limine handoff at 1.70 s, LUKS prompt at 23.17 s, 20.3 s of QEMU user
CPU, 1.47 GB RSS, 0.41 VNC updates/s during boot.

## 2. Configuration axes (one patch per config, isolated)

| Axis | Configs | Hypothesis |
|---|---|---|
| CPU model | `cpu-nehalem`, `cpu-qemu64`, `cpu-max-noavx` vs `baseline` (`-cpu max`) | `max` advertises AVX/AVX2, so glibc/compositor code paths hit helper-heavy vector emulation. Expect the largest single win here |
| vCPU count | `smp1`, `smp4` | with round-robin TCG, fewer vCPUs means less switching; boot parallelism may still favour 2 |
| Thread mode | `thread-single`, `thread-multi` | confirms the RR fallback empirically |
| TB cache | `tb256`, `tb2048` | translation cache pressure during boot vs steady state |
| JIT mapping | `splitwx-on`, `splitwx-off` | W^X strategy on Apple Silicon changes codegen cost |
| Display | `vga-std`, `vga-virtio-gpu`, `vga-bochs` | dirty tracking and rect shape drive VNC update rate and display-path CPU |
| Block | `blk-plain`, `blk-cache-none` | `discard=unmap,detect-zeroes=unmap` costs per-write scanning; `cache=none` changes macOS page-cache behaviour |
| Guest clock | `rtc-clock-vm` | lets guest time dilate instead of stalling under emulation |
| Memory | `mem2g` | 4 GiB VM plus an Apple VZ guest on a 16 GB host |
| Host QoS | `qos-utility`, `qos-background` | quantifies P-core vs E-core placement of the single TCG thread — the cheapest possible fix if it matters |

Run each config against `baseline` in one session, `-n 5`, and read medians (the
report prints median, stdev and `% vs base`).

## 3. Metrics and where they come from

| Metric | How it is captured | Unlock needed? |
|---|---|---|
| Time to firmware alive | first serial byte, host timestamp | no |
| Time to bootloader handoff | `BdsDxe: loading/starting Boot…` | no |
| Time to LUKS prompt | `A password is required to access the root volume` | no |
| Emulation cost of that boot | `getrusage` of the reaped QEMU child (`qemu cpu user s`), peak RSS | no |
| Framebuffer update rate | RFB probe: updates/s, rects, bytes, median/p90 inter-update gap | no (boot animation) |
| Framebuffer latency (input→pixel) | RFB `KeyEvent` at the Limine menu → first changed update | no |
| VM start overhead | spawn→serial, spawn→QMP, spawn→first pixels | no |
| CPU throughput, real workload | benchmark inside a guest shell | **yes** — or use `live-iso` |
| Compositor (Hyprland) responsiveness | key/pointer → pixel latency, sustained update rate on the desktop | **yes** (or live ISO desktop) |
| Guest frame pacing, disk I/O in the installed system | `hyprctl`, `fio`, `sysbench` in the guest | **yes** |

### Host-side only (no passphrase)

Everything in the first block. Time-to-LUKS is a strong emulation-throughput
proxy: it contains firmware POST, Limine, kernel decompression and initramfs —
all translated x86, no guest cooperation. Pair it with `qemu cpu user s` to
separate "faster emulation" from "less host CPU burned".

```sh
./tcgbench.py run --profile boot-to-luks \
    --configs baseline,cpu-nehalem,cpu-max-noavx,smp1,smp4,tb2048,vga-std,qos-utility -n 5
```

### Needs the user to unlock (or the live-ISO workaround)

CPU throughput of the *installed* system and anything about Hyprland needs a
running desktop. Two options:

1. **Unlock once, then drive it.** The user types the passphrase and logs in;
   the harness (or `vncdotool`) injects keys over VNC and measures key→pixel
   latency and update rate on the desktop. Keep this an attended step.
2. **`live-iso` profile — no passphrase at all.** The library already holds
   `omarchy-4.0.0.iso`. Booting it read-only with no disk attached gives the
   same kernel and compositor stack in a live session, so CPU benchmarks
   (`openssl speed`, `7z b`, `sysbench cpu`, kernel `tar xJ`) and Hyprland
   latency can be measured per TCG config without touching encrypted data.
   Recommended default for the guest-side half of the matrix.

## 4. Procedure

```sh
cd Tools/Benchmarks
./tcgbench.py doctor                                                # host + library sanity
./tcgbench.py run --profile firmware-smoke --configs baseline -n 1  # plumbing check, no guest disk
./tcgbench.py run --profile boot-to-luks --configs baseline,cpu-nehalem -n 5
./tcgbench.py run --profile input-latency --configs baseline,vga-std,vga-virtio-gpu -n 3
./tcgbench.py report .bench/results/<run-id>
```

Controls that matter on a laptop: AC power, Low Power Mode off, keep the Apple
VZ guest either stopped or identical across arms, discard the first iteration
(page-cache warm-up), keep `--cooldown` ≥ 5 s for comparable thermal state, and
never mix results from different sessions. Every run stores its exact argv, raw
serial capture, JSON record and a `summary.csv` under `.bench/results/<run-id>/`.

## 5. Smallest automation additions to SimpleVM

The harness is standalone and needs **no app changes**. If a winning
configuration should ship and stay verified from inside the app, three small
additions suffice:

1. **Config override hook** (~10 lines in `QEMUConfigurationBuilder.make`):
   honour `SIMPLEVM_QEMU_ACCEL`, `SIMPLEVM_QEMU_CPU`, `SIMPLEVM_QEMU_EXTRA_ARGS`
   so an arm can be run through the real app without a rebuild, and harness
   findings can be confirmed on the production code path.
2. **Timestamped boot milestones** (~15 lines in `QEMUMachineRuntime`): the
   serial monitor already scans for the LUKS string; also record
   firmware/bootloader/LUKS/login timestamps into `runtime.log`, which today
   logs phases without durations. Every real boot then becomes a data point.
3. **App Nap / QoS guard** (~5 lines in `QEMUMachineRuntime.start`): wrap the
   run in `ProcessInfo.processInfo.beginActivity(options: [.userInitiated,
   .idleSystemSleepDisabled])` so a backgrounded SimpleVM window cannot demote
   the single round-robin TCG thread to E-cores. Size the effect first with the
   `qos-*` configs.

Existing tools worth reusing instead of writing more code: `qemu-img` for
overlays, QEMU's own `-serial tcp` and QMP for instrumentation, `vncdotool`
(`pip install vncdotool`) for scripted guest input after unlock, and
`/usr/sbin/taskpolicy` for QoS clamping.
