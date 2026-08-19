# Security notes

The host API is an exact allowlist. It has no command execution request and
accepts no host-provided executable, shell text, mount source, mount option, or
path. Privileged subprocesses use fixed argument arrays with `shell=False`.
The only mount is virtiofs tag `share` at `/mnt/simplevm-share`; power actions
are `systemctl poweroff` and `systemctl reboot`.

Frames are UTF-8 JSON prefixed by a four-byte big-endian length. The 2 MiB
frame limit is checked before allocation. Clipboard UTF-8 is limited to exactly
1 MiB. Unknown, malformed, and oversized host frames close the connection.
Display dimensions are integers in 640..16384 by 480..16384.

The root daemon never reads desktop-user files. The unprivileged helper derives
session details from its environment and `/etc/os-release`. Internal IPC uses a
fixed runtime socket, restrictive filesystem permissions, and peer credentials.
The root unit intentionally avoids a private mount namespace so the fixed
shared-directory mount is visible to the rest of the guest.
