"""Safe Linux and desktop environment detection."""

import os
import socket


def parse_os_release(path="/etc/os-release"):
    values = {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for raw_line in handle:
                line = raw_line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                if not key.replace("_", "").isalnum():
                    continue
                if len(value) >= 2 and value[0] == value[-1] == '"':
                    value = value[1:-1].replace('\\"', '"').replace("\\\\", "\\")
                values[key] = value
    except (OSError, UnicodeError):
        pass
    return values


def detect_desktop(environ=None):
    env = os.environ if environ is None else environ
    desktop_text = " ".join(
        [
            env.get("XDG_CURRENT_DESKTOP", ""),
            env.get("XDG_SESSION_DESKTOP", ""),
            env.get("DESKTOP_SESSION", ""),
        ]
    ).lower()
    if env.get("HYPRLAND_INSTANCE_SIGNATURE") or "hyprland" in desktop_text:
        desktop = "hyprland"
    elif "gnome" in desktop_text:
        desktop = "gnome"
    else:
        desktop = "other"

    session_text = env.get("XDG_SESSION_TYPE", "").lower()
    if session_text == "wayland" or env.get("WAYLAND_DISPLAY"):
        session_type = "wayland"
    elif session_text == "x11" or env.get("DISPLAY"):
        session_type = "x11"
    else:
        session_type = "other"
    return desktop, session_type


def system_identity(os_release_path="/etc/os-release"):
    release = parse_os_release(os_release_path)
    return {
        "hostname": socket.gethostname(),
        "operatingSystem": "Linux",
        "distroID": release.get("ID", "unknown"),
        "distroVersion": release.get("VERSION_ID", "unknown"),
    }


def ip_addresses():
    addresses = set()
    try:
        for result in socket.getaddrinfo(
            socket.gethostname(), None, socket.AF_UNSPEC, socket.SOCK_STREAM
        ):
            address = result[4][0].split("%", 1)[0]
            if address and not address.startswith("127.") and address != "::1":
                addresses.add(address)
    except socket.gaierror:
        pass
    return sorted(addresses)
