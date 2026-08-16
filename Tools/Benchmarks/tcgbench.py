#!/usr/bin/env python3
"""Non-destructive A/B benchmark harness for SimpleVM's QEMU TCG configuration.

The harness never touches a SimpleVM-managed VM. It launches its own throwaway
qemu-system-x86_64 processes against a qcow2 overlay whose backing file is the
guest disk (opened read-only by QEMU), a private copy of the EFI variable store,
and its own VNC/QMP/serial endpoints inside Tools/Benchmarks/.bench.

Metrics captured per run, entirely host-side:
  * spawn -> serial attach, spawn -> QMP ready, spawn -> first pixels
  * host-timestamped serial milestones (firmware output, bootloader handoff,
    LUKS passphrase prompt, login prompt)
  * VNC framebuffer update rate / bytes / inter-update gaps
  * optional input -> framebuffer-change latency (key injected over RFB)
  * QEMU process CPU time and peak RSS (getrusage of the reaped child)

Usage:
  ./tcgbench.py configs
  ./tcgbench.py doctor
  ./tcgbench.py run --profile firmware-smoke --configs baseline -n 1
  ./tcgbench.py run --profile boot-to-luks --configs baseline,cpu-nehalem -n 5
  ./tcgbench.py run --profile input-latency --configs baseline,vga-std
  ./tcgbench.py report .bench/results/<run-id>
"""

import argparse
import csv
import json
import os
import re
import shutil
import socket
import statistics
import struct
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH_ROOT = os.path.join(HERE, ".bench")
DEFAULT_QEMU_PREFIX = os.environ.get("SIMPLEVM_QEMU_PREFIX", "/opt/homebrew/opt/qemu")
DEFAULT_LIBRARY = os.path.expanduser("~/Library/Application Support/SimpleVM")

# Guest consoles colour their output; strip escapes before matching milestones.
ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[()][A-Za-z0-9]")

# Milestones are matched against the host-timestamped serial byte stream.
MILESTONES = [
    ("firmware_serial", re.compile(r"\S")),
    ("bootloader_loading", re.compile(r"BdsDxe: loading Boot")),
    ("bootloader_starting", re.compile(r"BdsDxe: starting Boot")),
    ("no_boot_device", re.compile(r"BdsDxe: failed to load Boot|No bootable option")),
    ("luks_prompt", re.compile(r"A password is required to access the root volume")),
    ("systemd_init", re.compile(r"Reached target Basic System")),
    ("login_prompt", re.compile(r"login:")),
]

# Baseline mirrors QEMUConfigurationBuilder.make() in SimpleVMCore.
BASELINE = {
    "machine": "q35,hpet=off",
    "accel": "tcg,tb-size=1024",
    "cpu": "max",
    "smp": "2",
    "memory_mib": "4096",
    "display_device": "virtio-vga,xres=1280,yres=800",
    "blockdev_opts": "cache=writeback,aio=threads,discard=unmap,detect-zeroes=unmap",
    "rtc": None,
    "task_qos": None,
    "extra": [],
}

# Each entry is a single-axis patch on top of BASELINE so effects stay isolated.
CONFIGS = {
    "baseline": {},
    # CPU model: `-cpu max` exposes AVX/AVX2, which TCG emulates through helper
    # calls; older models keep the guest on cheaper SSE paths.
    "cpu-nehalem": {"cpu": "Nehalem"},
    "cpu-qemu64": {"cpu": "qemu64"},
    "cpu-max-noavx": {"cpu": "max,-avx,-avx2,-avx512f,-avx512bw,-avx512vl"},
    # vCPU count: x86-on-aarch64 TCG falls back to round-robin on one host
    # thread, so extra vCPUs mostly add switch overhead. Measure, don't assume.
    "smp1": {"smp": "1"},
    "smp4": {"smp": "4"},
    "thread-single": {"accel": "tcg,tb-size=1024,thread=single"},
    "thread-multi": {"accel": "tcg,tb-size=1024,thread=multi"},
    # Translation block cache size and JIT mapping strategy.
    "tb256": {"accel": "tcg,tb-size=256"},
    "tb2048": {"accel": "tcg,tb-size=2048"},
    "splitwx-off": {"accel": "tcg,tb-size=1024,split-wx=off"},
    "splitwx-on": {"accel": "tcg,tb-size=1024,split-wx=on"},
    # Display device: dirty tracking and VNC rect shape differ substantially.
    "vga-std": {"display_device": "VGA"},
    "vga-virtio-gpu": {"display_device": "virtio-gpu-pci,xres=1280,yres=800"},
    "vga-bochs": {"display_device": "bochs-display"},
    # Block layer.
    "blk-plain": {"blockdev_opts": "cache=writeback,aio=threads"},
    "blk-cache-none": {
        "blockdev_opts": "cache=none,aio=threads,discard=unmap,detect-zeroes=unmap"
    },
    # Guest clock: clock=vm lets guest time dilate instead of stalling.
    "rtc-clock-vm": {"rtc": "base=utc,clock=vm"},
    # Memory pressure on a 16 GB host that also hosts an Apple VZ guest.
    "mem2g": {"memory_mib": "2048"},
    # Host scheduling: the QoS clamp decides P-core vs E-core placement.
    "qos-background": {"task_qos": "background"},
    "qos-utility": {"task_qos": "utility"},
}

PROFILES = {
    # No guest disk at all: validates the harness against firmware only.
    "firmware-smoke": {
        "attach_disk": False,
        "stop_milestone": "no_boot_device",
        "timeout": 90,
    },
    # Boots the real guest through firmware + Limine and stops at the LUKS
    # prompt. Nothing is ever typed; the overlay is discarded afterwards.
    "boot-to-luks": {
        "attach_disk": True,
        "stop_milestone": "luks_prompt",
        "timeout": 600,
    },
    # Injects keys at the bootloader menu and measures key -> pixel latency.
    # Run separately: a keypress cancels the Limine countdown.
    "input-latency": {
        "attach_disk": True,
        "settle_after": "bootloader_loading",
        "settle_seconds": 4.0,
        "input_latency": True,
        "timeout": 300,
    },
    # Boots installer media (live environment, no LUKS) so guest-side CPU and
    # compositor work needs no passphrase and no user data.
    "live-iso": {
        "attach_iso": True,
        "stop_milestone": "login_prompt",
        "timeout": 1200,
    },
}


def log(message):
    sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), message))
    sys.stderr.flush()


# --------------------------------------------------------------------------
# Safety
# --------------------------------------------------------------------------


def running_qemu_commands():
    try:
        output = subprocess.run(
            ["ps", "-Ao", "pid=,command="], check=True, capture_output=True, text=True
        ).stdout
    except (subprocess.CalledProcessError, OSError):
        return []
    return [line.strip() for line in output.splitlines() if "qemu-system" in line]


def assert_safe_to_run(disk_path, allow_concurrent=False):
    """Refuse to run while another QEMU already owns the same guest disk."""
    conflicts = [
        line
        for line in running_qemu_commands()
        if disk_path and disk_path in line and BENCH_ROOT not in line
    ]
    if conflicts and not allow_concurrent:
        raise SystemExit(
            "Refusing to run: a QEMU process is already using %s:\n  %s"
            % (disk_path, "\n  ".join(conflicts))
        )


def library_machine(library_dir, name_or_id):
    path = os.path.join(library_dir, "library.json")
    with open(path, "r") as handle:
        library = json.load(handle)
    for machine in library.get("machines", []):
        if name_or_id in (machine.get("name"), machine.get("id")):
            return library, machine
    raise SystemExit(
        "Machine %r not found in %s (have: %s)"
        % (
            name_or_id,
            path,
            ", ".join(m.get("name", "?") for m in library.get("machines", [])),
        )
    )


def library_image_path(library, image_id, library_dir):
    for image in library.get("images", []):
        if image.get("id") != image_id:
            continue
        relative = image.get("availability", {}).get("available", {}).get("relativePath")
        if relative:
            return os.path.join(library_dir, relative)
    return None


# --------------------------------------------------------------------------
# QMP / serial / RFB clients
# --------------------------------------------------------------------------


class QMPClient(object):
    """QMP over loopback TCP: UNIX socket paths blow the 104 byte limit here."""

    def __init__(self, port):
        self.port = port
        self.sock = None

    def connect(self, timeout=30.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                sock = socket.create_connection(("127.0.0.1", self.port), 5.0)
                sock.settimeout(10.0)
                self.sock = sock
                self._readline()
                self.execute("qmp_capabilities")
                return time.time()
            except OSError:
                self.sock = None
                time.sleep(0.02)
        raise RuntimeError("QMP port never became available: %d" % self.port)

    def _readline(self):
        buffer = b""
        while not buffer.endswith(b"\n"):
            chunk = self.sock.recv(1)
            if not chunk:
                raise RuntimeError("QMP closed")
            buffer += chunk
        return json.loads(buffer.decode("utf-8"))

    def execute(self, command, arguments=None):
        if self.sock is None:
            raise RuntimeError("QMP is not connected")
        payload = {"execute": command}
        if arguments:
            payload["arguments"] = arguments
        self.sock.sendall((json.dumps(payload) + "\r\n").encode("utf-8"))
        while True:
            message = self._readline()
            if "event" in message:
                continue
            return message

    def vcpu_thread_ids(self):
        try:
            entries = self.execute("query-cpus-fast").get("return", [])
        except (OSError, RuntimeError, ValueError):
            return []
        return sorted({entry.get("thread-id") for entry in entries})

    def quit(self):
        try:
            self.execute("quit")
        except (OSError, RuntimeError, ValueError):
            pass

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None


class SerialReader(threading.Thread):
    """Reads the QEMU serial chardev and host-timestamps every milestone."""

    daemon = True

    def __init__(self, port, raw_path):
        threading.Thread.__init__(self)
        self.port = port
        self.raw_path = raw_path
        self.sock = None
        self.t0 = None
        self.milestones = {}
        self.seen = set()
        self.buffer = ""
        self.stop_event = threading.Event()
        self.error = None

    def connect(self, timeout=60.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                sock = socket.create_connection(("127.0.0.1", self.port), 5.0)
                sock.settimeout(0.5)
                self.sock = sock
                self.t0 = time.time()
                return self.t0
            except OSError:
                time.sleep(0.02)
        raise RuntimeError("serial chardev never accepted a connection")

    def run(self):
        handle = open(self.raw_path, "wb")
        try:
            while not self.stop_event.is_set():
                try:
                    chunk = self.sock.recv(4096)
                except socket.timeout:
                    continue
                except OSError:
                    break
                if not chunk:
                    break
                now = time.time()
                handle.write(chunk)
                handle.flush()
                self.buffer += ANSI_ESCAPE.sub("", chunk.decode("utf-8", "replace"))
                self._match(now)
                if len(self.buffer) > 65536:
                    self.buffer = self.buffer[-8192:]
        except Exception as error:  # diagnostics only
            self.error = str(error)
        finally:
            handle.close()

    def _match(self, now):
        for name, pattern in MILESTONES:
            if name in self.seen:
                continue
            if pattern.search(self.buffer):
                self.seen.add(name)
                self.milestones[name] = now - self.t0

    def wait_for(self, name, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if name in self.milestones:
                return True
            if not self.is_alive():
                return name in self.milestones
            time.sleep(0.05)
        return name in self.milestones

    def stop(self):
        self.stop_event.set()
        if self.sock:
            try:
                self.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                self.sock.close()
            except OSError:
                pass


class RFBProbe(threading.Thread):
    """Minimal RFB 3.8 client that measures framebuffer update behaviour."""

    daemon = True

    def __init__(self, port):
        threading.Thread.__init__(self)
        self.port = port
        self.sock = None
        self.width = 0
        self.height = 0
        self.connected_at = None
        self.first_update_at = None
        self.update_times = []
        self.update_bytes = 0
        self.rect_count = 0
        self.stop_event = threading.Event()
        self.error = None
        self._update_event = threading.Event()
        self._lock = threading.Lock()

    def connect(self, timeout=90.0):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            try:
                sock = socket.create_connection(("127.0.0.1", self.port), 5.0)
                sock.settimeout(5.0)
                self.sock = sock
                self._handshake()
                self.connected_at = time.time()
                return self.connected_at
            except OSError as error:
                last = error
                if self.sock:
                    try:
                        self.sock.close()
                    except OSError:
                        pass
                    self.sock = None
                time.sleep(0.05)
        raise RuntimeError("VNC never accepted a connection: %s" % last)

    def _recv(self, count):
        data = b""
        while len(data) < count:
            chunk = self.sock.recv(count - len(data))
            if not chunk:
                raise OSError("VNC closed")
            data += chunk
        return data

    def _handshake(self):
        version = self._recv(12)
        if not version.startswith(b"RFB 003."):
            raise OSError("unsupported RFB version %r" % version)
        self.sock.sendall(b"RFB 003.008\n")
        count = self._recv(1)[0]
        if count == 0:
            length = struct.unpack(">I", self._recv(4))[0]
            raise OSError("VNC refused: %s" % self._recv(length))
        if 1 not in self._recv(count):
            raise OSError("VNC requires authentication")
        self.sock.sendall(bytes([1]))
        if struct.unpack(">I", self._recv(4))[0] != 0:
            raise OSError("VNC security handshake failed")
        self.sock.sendall(bytes([1]))  # shared session
        header = self._recv(24)
        self.width, self.height = struct.unpack(">HH", header[0:4])
        self._recv(struct.unpack(">I", header[20:24])[0])
        # 32bpp little-endian true colour, matching SimpleVNCClient.
        self.sock.sendall(
            struct.pack(
                ">BBBBBBBBHHHBBBBBB",
                0, 0, 0, 0,
                32, 24, 0, 1,
                255, 255, 255,
                16, 8, 0,
                0, 0, 0,
            )
        )
        # raw, copyrect, desktop-size only, so no unexpected encoding appears.
        self.sock.sendall(struct.pack(">BBH", 2, 0, 3) + struct.pack(">iii", 0, 1, -223))
        self._request(incremental=False)

    def _request(self, incremental):
        self.sock.sendall(
            struct.pack(
                ">BBHHHH", 3, 1 if incremental else 0, 0, 0, self.width, self.height
            )
        )

    def run(self):
        try:
            while not self.stop_event.is_set():
                try:
                    message_type = self._recv(1)[0]
                except socket.timeout:
                    continue
                if message_type == 0:
                    self._read_update()
                elif message_type == 1:
                    header = self._recv(5)
                    self._recv(struct.unpack(">H", header[3:5])[0] * 6)
                elif message_type == 2:
                    continue
                elif message_type == 3:
                    header = self._recv(7)
                    self._recv(struct.unpack(">I", header[3:7])[0])
                else:
                    raise OSError("unexpected RFB message %d" % message_type)
        except Exception as error:
            if not self.stop_event.is_set():
                self.error = str(error)

    def _read_update(self):
        header = self._recv(3)
        rectangles = struct.unpack(">H", header[1:3])[0]
        payload = 0
        changed = False
        for _ in range(rectangles):
            rectangle = self._recv(12)
            _, _, width, height = struct.unpack(">HHHH", rectangle[0:8])
            encoding = struct.unpack(">i", rectangle[8:12])[0]
            if encoding == -223:
                self.width, self.height = width, height
                self._request(incremental=False)
                continue
            if encoding == 1:
                self._recv(4)
                payload += 4
                changed = changed or width * height > 0
                continue
            if encoding != 0:
                raise OSError("unexpected encoding %d" % encoding)
            size = width * height * 4
            self._recv(size)
            payload += size
            changed = changed or size > 0
        now = time.time()
        with self._lock:
            self.rect_count += rectangles
            self.update_bytes += payload
            if changed:
                self.update_times.append(now)
                if self.first_update_at is None:
                    self.first_update_at = now
                self._update_event.set()
        self._request(incremental=True)

    def send_key(self, keysym, down):
        self.sock.sendall(struct.pack(">BBHI", 4, 1 if down else 0, 0, keysym))

    def measure_key_latency(self, keysym=0xFF54, samples=12, warmup=2, gap=0.4):
        """Returns key -> first changed framebuffer update latencies in ms."""
        results = []
        for index in range(samples + warmup):
            time.sleep(gap)
            self._update_event.clear()
            sent = time.time()
            try:
                self.send_key(keysym, True)
                self.send_key(keysym, False)
            except OSError:
                break
            if self._update_event.wait(3.0) and index >= warmup:
                results.append((time.time() - sent) * 1000.0)
        return results

    def statistics(self):
        with self._lock:
            times = list(self.update_times)
        if len(times) < 2:
            return {"updates": len(times), "updates_per_second": None}
        span = times[-1] - times[0]
        gaps = [(b - a) * 1000.0 for a, b in zip(times, times[1:])]
        return {
            "updates": len(times),
            "updates_per_second": (len(times) - 1) / span if span > 0 else None,
            "gap_ms_median": statistics.median(gaps),
            "gap_ms_p90": sorted(gaps)[max(0, int(len(gaps) * 0.9) - 1)],
            "bytes": self.update_bytes,
            "rects": self.rect_count,
        }

    def stop(self):
        self.stop_event.set()
        if self.sock:
            try:
                self.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                self.sock.close()
            except OSError:
                pass


# --------------------------------------------------------------------------
# Run mechanics
# --------------------------------------------------------------------------


def free_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def free_vnc_port(start=5950):
    for port in range(start, start + 50):
        sock = socket.socket()
        try:
            sock.bind(("127.0.0.1", port))
            return port
        except OSError:
            continue
        finally:
            sock.close()
    raise RuntimeError("no free VNC port")


def resolve_options(config_name):
    options = dict(BASELINE)
    options.update(CONFIGS[config_name])
    return options


def build_command(options, paths, profile, ports, qemu_prefix):
    binary = os.path.join(qemu_prefix, "bin", "qemu-system-x86_64")
    share = os.path.join(qemu_prefix, "share", "qemu")
    command = []
    if options.get("task_qos"):
        command += ["/usr/sbin/taskpolicy", "-c", options["task_qos"]]
    command += [
        binary,
        "-name", "tcgbench",
        "-machine", options["machine"],
        "-accel", options["accel"],
        "-cpu", options["cpu"],
        "-smp", options["smp"],
        "-m", options["memory_mib"],
        "-nodefaults",
        "-display", "none",
        "-vnc", "127.0.0.1:%d" % (ports["vnc"] - 5900),
        "-qmp", "tcp:127.0.0.1:%d,server=on,wait=off" % ports["qmp"],
        "-serial", "tcp:127.0.0.1:%d,server=on,wait=on" % ports["serial"],
        "-drive",
        "if=pflash,format=raw,unit=0,readonly=on,file=%s"
        % os.path.join(share, "edk2-x86_64-code.fd"),
        "-drive", "if=pflash,format=raw,unit=1,file=%s" % paths["vars"],
        "-device", options["display_device"],
        "-device", "virtio-rng-pci",
        "-device", "qemu-xhci",
        "-device", "usb-kbd",
        "-device", "usb-tablet",
        "-netdev", "user,id=net0",
        "-device", "virtio-net-pci,netdev=net0",
    ]
    if options.get("rtc"):
        command += ["-rtc", options["rtc"]]
    if profile.get("attach_disk") and paths.get("overlay"):
        command += [
            "-drive",
            "if=none,id=system-disk,file=%s,format=qcow2,%s"
            % (paths["overlay"], options["blockdev_opts"]),
            "-device", "virtio-blk-pci,drive=system-disk,bootindex=0",
        ]
    if profile.get("attach_iso") and paths.get("iso"):
        command += [
            "-drive",
            "if=none,id=installer,file=%s,media=cdrom,readonly=on" % paths["iso"],
            "-device", "ide-cd,drive=installer,bootindex=1",
        ]
    return command + list(options.get("extra", []))


def prepare_paths(run_dir, machine_dir, profile, qemu_prefix, iso_path):
    os.makedirs(run_dir, exist_ok=True)
    share = os.path.join(qemu_prefix, "share", "qemu")
    vars_path = os.path.join(run_dir, "efi-vars.fd")
    source_vars = os.path.join(machine_dir or "", "QEMU", "efi-vars.fd")
    template = os.path.join(share, "edk2-i386-vars.fd")
    # Copy (never mutate) the guest's own EFI variable store when present so the
    # boot path matches production; otherwise start from QEMU's template.
    shutil.copyfile(source_vars if os.path.exists(source_vars) else template, vars_path)
    paths = {"vars": vars_path, "serial_raw": os.path.join(run_dir, "serial.bin")}
    if profile.get("attach_disk"):
        base = os.path.join(machine_dir, "disk.raw")
        if not os.path.exists(base):
            raise SystemExit("guest disk not found: %s" % base)
        overlay = os.path.join(run_dir, "overlay.qcow2")
        subprocess.run(
            [
                os.path.join(qemu_prefix, "bin", "qemu-img"),
                "create", "-q", "-f", "qcow2", "-F", "raw", "-b", base, overlay,
            ],
            check=True,
        )
        paths["overlay"] = overlay
    if profile.get("attach_iso"):
        if not iso_path or not os.path.exists(iso_path):
            raise SystemExit("installer ISO not found for the live-iso profile")
        paths["iso"] = iso_path
    return paths


def reap(process, timeout=15.0):
    """Reap the child directly so getrusage numbers survive."""
    deadline = time.time() + timeout
    killed = False
    while True:
        try:
            pid, status, usage = os.wait4(process.pid, os.WNOHANG)
        except ChildProcessError:
            return None
        if pid:
            process.returncode = status
            return {
                "qemu_cpu_user_s": usage.ru_utime,
                "qemu_cpu_system_s": usage.ru_stime,
                "qemu_max_rss_mb": usage.ru_maxrss / (1024.0 * 1024.0),
                "exit_status": status,
            }
        if time.time() > deadline and not killed:
            process.kill()
            killed = True
            deadline = time.time() + 10
        time.sleep(0.05)


def execute_run(config_name, profile, run_dir, machine_dir, qemu_prefix, iso_path,
                dry_run=False):
    options = resolve_options(config_name)
    paths = prepare_paths(run_dir, machine_dir, profile, qemu_prefix, iso_path)
    ports = {"vnc": free_vnc_port(), "serial": free_port(), "qmp": free_port()}
    command = build_command(options, paths, profile, ports, qemu_prefix)
    record = {
        "config": config_name,
        "options": {key: value for key, value in options.items() if key != "extra"},
        "command": command,
        "started_at": time.time(),
    }
    if dry_run:
        return record

    serial = SerialReader(ports["serial"], paths["serial_raw"])
    probe = RFBProbe(ports["vnc"])
    qmp = QMPClient(ports["qmp"])
    stderr_handle = open(os.path.join(run_dir, "qemu-stderr.log"), "wb")
    spawned = time.time()
    process = subprocess.Popen(command, stdout=stderr_handle, stderr=subprocess.STDOUT)
    try:
        record["t_serial_attach"] = serial.connect() - spawned
        serial.start()
        record["t_qmp_ready"] = qmp.connect() - spawned
        thread_ids = qmp.vcpu_thread_ids()
        record["vcpu_thread_ids"] = thread_ids
        record["mttcg_active"] = len([t for t in thread_ids if t]) > 1
        record["t_vnc_accept"] = probe.connect() - spawned
        probe.start()

        if profile.get("input_latency"):
            if profile.get("settle_after"):
                serial.wait_for(profile["settle_after"], profile["timeout"])
            time.sleep(profile.get("settle_seconds", 3.0))
            record["key_latency_ms"] = probe.measure_key_latency()
        elif profile.get("stop_milestone"):
            record["reached_stop_milestone"] = serial.wait_for(
                profile["stop_milestone"], profile["timeout"]
            )
            time.sleep(1.0)  # let the final screen paint before sampling
        else:
            time.sleep(min(profile["timeout"], 30))

        record["t_vnc_first_update"] = (
            probe.first_update_at - spawned if probe.first_update_at else None
        )
        record["framebuffer"] = probe.statistics()
        record["milestones"] = dict(serial.milestones)
        record["serial_t0_offset"] = serial.t0 - spawned
    finally:
        probe.stop()
        serial.stop()
        qmp.quit()
        qmp.close()
        usage = reap(process)
        if usage:
            record.update(usage)
        stderr_handle.close()
        record["wall_seconds"] = time.time() - spawned
        record["probe_error"] = probe.error
        record["serial_error"] = serial.error
        # The overlay only ever held throwaway writes; the backing disk is
        # untouched. Drop it immediately to keep the footprint small.
        if paths.get("overlay") and os.path.exists(paths["overlay"]):
            record["overlay_bytes"] = os.path.getsize(paths["overlay"])
            os.remove(paths["overlay"])
    return record


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

METRIC_KEYS = [
    ("t_serial_attach", "spawn->serial s"),
    ("t_qmp_ready", "spawn->qmp s"),
    ("t_vnc_first_update", "spawn->first pixels s"),
    ("qemu_cpu_user_s", "qemu cpu user s"),
    ("qemu_max_rss_mb", "qemu rss mb"),
    ("wall_seconds", "wall s"),
]


def record_metrics(record):
    metrics = {}
    for key, label in METRIC_KEYS:
        if record.get(key) is not None:
            metrics[label] = record[key]
    for name, value in (record.get("milestones") or {}).items():
        metrics["serial:" + name] = value
    framebuffer = record.get("framebuffer") or {}
    for key in ("updates_per_second", "gap_ms_median", "gap_ms_p90", "bytes"):
        if framebuffer.get(key) is not None:
            metrics["fb:" + key] = framebuffer[key]
    latencies = record.get("key_latency_ms")
    if latencies:
        metrics["input:key_to_pixel_ms_median"] = statistics.median(latencies)
        metrics["input:key_to_pixel_ms_p90"] = sorted(latencies)[
            max(0, int(len(latencies) * 0.9) - 1)
        ]
    return metrics


def write_csv(records, path):
    rows = []
    columns = set()
    for record in records:
        metrics = record_metrics(record)
        columns.update(metrics)
        row = {"config": record["config"], "iteration": record.get("iteration")}
        row.update(metrics)
        rows.append(row)
    with open(path, "w", newline="") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=["config", "iteration"] + sorted(columns)
        )
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def render_report(records):
    by_config = {}
    for record in records:
        by_config.setdefault(record["config"], []).append(record_metrics(record))
    names = sorted(
        {name for samples in by_config.values() for sample in samples for name in sample}
    )
    baseline = by_config.get("baseline")
    lines = []
    for config_name, samples in by_config.items():
        lines.append("\n== %s (n=%d) ==" % (config_name, len(samples)))
        lines.append("%-34s %12s %10s %9s" % ("metric", "median", "stdev", "vs base"))
        for name in names:
            values = [sample[name] for sample in samples if name in sample]
            if not values:
                continue
            median = statistics.median(values)
            stdev = statistics.stdev(values) if len(values) > 1 else 0.0
            delta = ""
            if baseline and config_name != "baseline":
                base = [s[name] for s in baseline if name in s]
                if base and statistics.median(base):
                    delta = "%+.1f%%" % ((median / statistics.median(base) - 1) * 100)
            lines.append("%-34s %12.3f %10.3f %9s" % (name, median, stdev, delta))
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------


def command_configs(args):
    print("Configs (single-axis patches on the SimpleVM baseline):")
    for name, patch in CONFIGS.items():
        summary = ", ".join("%s=%s" % item for item in patch.items()) or "(reference)"
        print("  %-16s %s" % (name, summary))
    print("\nProfiles:")
    for name, profile in PROFILES.items():
        print(
            "  %-16s disk=%s iso=%s stop=%s timeout=%ss"
            % (
                name,
                bool(profile.get("attach_disk")),
                bool(profile.get("attach_iso")),
                profile.get("stop_milestone") or "-",
                profile["timeout"],
            )
        )
    return 0


def command_doctor(args):
    binary = os.path.join(args.qemu_prefix, "bin", "qemu-system-x86_64")
    firmware = os.path.join(args.qemu_prefix, "share", "qemu", "edk2-x86_64-code.fd")
    print("qemu-system-x86_64 : %s" % (binary if os.access(binary, os.X_OK) else "MISSING"))
    print("firmware           : %s" % ("ok" if os.path.exists(firmware) else "MISSING"))
    print(
        "taskpolicy         : %s"
        % ("ok" if os.path.exists("/usr/sbin/taskpolicy") else "missing")
    )
    try:
        library, machine = library_machine(args.library, args.machine)
        machine_dir = os.path.join(
            args.library, os.path.dirname(machine["disk"]["relativePath"])
        )
        disk = os.path.join(machine_dir, "disk.raw")
        print("machine            : %s (%s)" % (machine["name"], machine["id"]))
        print("recorded state     : %s" % ",".join(machine.get("runtimeState", {})))
        if os.path.exists(disk):
            print(
                "disk               : %s (%.1f GB allocated)"
                % (disk, os.stat(disk).st_blocks * 512 / 1e9)
            )
        print(
            "installer iso      : %s"
            % library_image_path(library, machine.get("sourceImageID"), args.library)
        )
    except SystemExit as error:
        print("machine            : %s" % error)
    print("running qemu       : %s" % (running_qemu_commands() or "none"))
    root = BENCH_ROOT if os.path.exists(BENCH_ROOT) else HERE
    print("free disk          : %.1f GB" % (shutil.disk_usage(root).free / 1e9))
    return 0


def command_run(args):
    profile = PROFILES[args.profile]
    machine_dir = None
    iso_path = None
    disk_path = ""
    if profile.get("attach_disk") or profile.get("attach_iso"):
        library, machine = library_machine(args.library, args.machine)
        machine_dir = os.path.join(
            args.library, os.path.dirname(machine["disk"]["relativePath"])
        )
        disk_path = os.path.join(machine_dir, "disk.raw")
        iso_path = library_image_path(library, machine.get("sourceImageID"), args.library)
        if "running" in machine.get("runtimeState", {}) and not args.allow_concurrent:
            raise SystemExit(
                "Refusing to run: SimpleVM records machine %r as running."
                % machine["name"]
            )
    assert_safe_to_run(disk_path, args.allow_concurrent)

    configs = [name.strip() for name in args.configs.split(",") if name.strip()]
    unknown = [name for name in configs if name not in CONFIGS]
    if unknown:
        raise SystemExit("unknown configs: %s" % ", ".join(unknown))

    run_id = time.strftime("%Y%m%dT%H%M%S") + "-" + args.profile
    results_dir = os.path.join(BENCH_ROOT, "results", run_id)
    os.makedirs(results_dir, exist_ok=True)
    records = []
    total = len(configs) * args.iterations
    index = 0
    for config_name in configs:
        for iteration in range(args.iterations):
            index += 1
            log("[%d/%d] %s iteration %d" % (index, total, config_name, iteration + 1))
            run_dir = os.path.join(
                BENCH_ROOT, "runs", "%s-%s-%d" % (run_id, config_name, iteration)
            )
            try:
                record = execute_run(
                    config_name,
                    profile,
                    run_dir,
                    machine_dir,
                    args.qemu_prefix,
                    iso_path,
                    dry_run=args.dry_run,
                )
            finally:
                if not args.keep_run_dirs and not args.dry_run:
                    shutil.rmtree(run_dir, ignore_errors=True)
            record["iteration"] = iteration
            record["profile"] = args.profile
            record["run_id"] = run_id
            records.append(record)
            with open(os.path.join(results_dir, "records.json"), "w") as handle:
                json.dump(records, handle, indent=2, default=str)
            if args.dry_run:
                print(" ".join(record["command"]))
                continue
            log(
                "  milestones=%s fb_updates_per_s=%s"
                % (
                    record.get("milestones"),
                    record.get("framebuffer", {}).get("updates_per_second"),
                )
            )
            if args.cooldown:
                time.sleep(args.cooldown)
    if not args.dry_run:
        write_csv(records, os.path.join(results_dir, "summary.csv"))
        print(render_report(records))
        print("\nresults: %s" % results_dir)
    return 0


def command_report(args):
    with open(os.path.join(args.results, "records.json")) as handle:
        print(render_report(json.load(handle)))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--qemu-prefix", default=DEFAULT_QEMU_PREFIX)
    parser.add_argument("--library", default=DEFAULT_LIBRARY)
    subparsers = parser.add_subparsers(dest="command", required=True)

    configs = subparsers.add_parser("configs", help="list configs and profiles")
    configs.set_defaults(func=command_configs)

    doctor = subparsers.add_parser("doctor", help="check host prerequisites")
    doctor.add_argument("--machine", default="omarchy-4.0.0")
    doctor.set_defaults(func=command_doctor)

    run = subparsers.add_parser("run", help="execute an A/B matrix")
    run.add_argument("--profile", choices=sorted(PROFILES), default="boot-to-luks")
    run.add_argument("--configs", default="baseline")
    run.add_argument("-n", "--iterations", type=int, default=3)
    run.add_argument("--machine", default="omarchy-4.0.0")
    run.add_argument("--cooldown", type=float, default=5.0)
    run.add_argument("--dry-run", action="store_true")
    run.add_argument("--keep-run-dirs", action="store_true")
    run.add_argument("--allow-concurrent", action="store_true")
    run.set_defaults(func=command_run)

    report = subparsers.add_parser("report", help="re-render a stored result set")
    report.add_argument("results")
    report.set_defaults(func=command_report)

    args = parser.parse_args(argv)
    os.makedirs(BENCH_ROOT, exist_ok=True)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
