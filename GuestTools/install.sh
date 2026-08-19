#!/bin/sh
set -eu

SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INSTALL_USER=${SIMPLEVM_INSTALL_USER:-${SUDO_USER:-}}
INSTALL_WAYLAND=0
INSTALL_X11=0

usage() {
    echo "Usage: $0 [--with-wayland-clipboard] [--with-x11-agent]"
}

for argument in "$@"; do
    case "$argument" in
        --with-wayland-clipboard) INSTALL_WAYLAND=1 ;;
        --with-x11-agent) INSTALL_X11=1 ;;
        --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "SimpleVM Guest Tools requires root installation; requesting sudo."
    exec sudo env SIMPLEVM_INSTALL_USER="${USER:-}" "$0" "$@"
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "Error: systemd is required." >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "Python 3 is missing; installing it with the system package manager."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y python3
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --needed --noconfirm python
    else
        echo "Error: Python 3 is required and apt-get/pacman was not found." >&2
        exit 1
    fi
fi

install_optional_packages() {
    packages=
    [ "$INSTALL_WAYLAND" -eq 1 ] && packages="$packages wl-clipboard"
    [ "$INSTALL_X11" -eq 1 ] && packages="$packages spice-vdagent"
    [ -z "$packages" ] && return
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        # shellcheck disable=SC2086
        apt-get install -y $packages
    elif command -v pacman >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        pacman -S --needed --noconfirm $packages
    else
        echo "Error: optional packages requested, but apt-get/pacman was not found." >&2
        exit 1
    fi
}

install_optional_packages

if ! getent group simplevm-agent >/dev/null 2>&1; then
    groupadd --system simplevm-agent
fi
if ! id simplevm-agent >/dev/null 2>&1; then
    useradd --system --gid simplevm-agent --home-dir /nonexistent \
        --shell /usr/sbin/nologin simplevm-agent
fi
if [ -n "$INSTALL_USER" ] && [ "$INSTALL_USER" != root ] && id "$INSTALL_USER" >/dev/null 2>&1; then
    usermod -a -G simplevm-agent "$INSTALL_USER"
fi

install -d -m 0755 /usr/lib/simplevm-guest-tools
rm -rf /usr/lib/simplevm-guest-tools/simplevm_guest_tools
install -d -m 0755 /usr/lib/simplevm-guest-tools/simplevm_guest_tools
for module in "$SOURCE_DIR"/src/simplevm_guest_tools/*.py; do
    install -m 0644 "$module" /usr/lib/simplevm-guest-tools/simplevm_guest_tools/
done
install -m 0755 "$SOURCE_DIR/bin/simplevm-guest-tools-daemon" \
    /usr/sbin/simplevm-guest-tools-daemon
install -m 0755 "$SOURCE_DIR/bin/simplevm-guest-tools-session" \
    /usr/bin/simplevm-guest-tools-session
install -m 0644 "$SOURCE_DIR/systemd/simplevm-guest-tools.service" \
    /etc/systemd/system/simplevm-guest-tools.service
install -m 0644 "$SOURCE_DIR/systemd/simplevm-guest-tools-session.service" \
    /etc/systemd/user/simplevm-guest-tools-session.service
install -d -m 0755 /mnt/simplevm-share

systemctl daemon-reload
systemctl --global enable simplevm-guest-tools-session.service
systemctl --global is-enabled --quiet simplevm-guest-tools-session.service
systemctl enable --now simplevm-guest-tools.service
systemctl is-enabled --quiet simplevm-guest-tools.service
systemctl is-active --quiet simplevm-guest-tools.service

echo "SimpleVM Guest Tools 2.0.0 installation and system service setup completed."
echo "The user helper is globally enabled and starts with the next desktop login."
if [ -n "$INSTALL_USER" ] && [ "$INSTALL_USER" != root ]; then
    echo "$INSTALL_USER must sign out and in once for simplevm-agent group access."
fi
echo "Wayland clipboard requires wl-clipboard."
echo "Vanilla spice-vdagent can help X11 guests; it does not provide"
echo "SimpleVM clipboard or resizing for a Hyprland Wayland session."
