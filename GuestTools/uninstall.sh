#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "SimpleVM Guest Tools removal requires root; requesting sudo."
    exec sudo "$0" "$@"
fi

systemctl disable --now simplevm-guest-tools.service 2>/dev/null || true
systemctl --global disable simplevm-guest-tools-session.service 2>/dev/null || true
rm -f /etc/systemd/system/simplevm-guest-tools.service
rm -f /etc/systemd/user/simplevm-guest-tools-session.service
rm -f /usr/sbin/simplevm-guest-tools-daemon
rm -f /usr/bin/simplevm-guest-tools-session
rm -rf /usr/lib/simplevm-guest-tools
rm -f /run/simplevm-guest-tools/session.sock
rmdir /run/simplevm-guest-tools 2>/dev/null || true
systemctl daemon-reload

if id simplevm-agent >/dev/null 2>&1; then
    userdel simplevm-agent
fi
if getent group simplevm-agent >/dev/null 2>&1; then
    groupdel simplevm-agent
fi

echo "SimpleVM Guest Tools removed. /mnt/simplevm-share was left intact."
