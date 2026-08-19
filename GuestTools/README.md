# SimpleVM Guest Tools for Linux

This bundle implements protocol version 2 with Python 3 standard-library code.
It targets modern systemd Debian/Ubuntu and Arch/Omarchy guests.

## Architecture

`simplevm-guest-tools.service` is the root agent. It concurrently retries the
QEMU virtio-serial port `/dev/virtio-ports/com.simplevm.agent.0` and an
AF_VSOCK listener on port 1021 for Apple Virtualization. Failure of either
transport does not stop the other. A user systemd service handles only desktop
clipboard and narrowly gated Hyprland display resizing.

The processes communicate over `/run/simplevm-guest-tools/session.sock`. The
socket is group restricted; Linux `SO_PEERCRED` checks require an unprivileged
user on the session side and UID 0 on the daemon side.

## Install

Run `./install.sh`. It requests sudo itself, creates the `simplevm-agent`
account/group, installs and enables both units, and starts the system service.
Use `--with-wayland-clipboard` to install `wl-clipboard`, or
`--with-x11-agent` to install `spice-vdagent`.

Wayland clipboard support uses `wl-copy` and `wl-paste`. X11/GNOME does not
advertise SimpleVM clipboard support; a separately configured spice channel
may use spice-vdagent. Vanilla spice-vdagent does not solve Hyprland Wayland
clipboard or display resizing. Hyprland resize is advertised only when a live
Hyprland session and `hyprctl` are available.

Run `./uninstall.sh` to remove the code and units. The shared mount directory
is intentionally preserved. Run `./self-test.sh` for safe local tests.
For additional desktop users, add each user to `simplevm-agent` and have that
user sign out and in before starting the user unit.
