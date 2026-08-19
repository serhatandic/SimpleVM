"""Unprivileged desktop-session clipboard and display helper."""

import json
import os
import re
import selectors
import shutil
import subprocess
import time

from .detection import detect_desktop, parse_os_release
from .ipc import connect_to_root
from .protocol import MAX_CLIPBOARD_SIZE, ProtocolError, read_frame, write_frame

_MONITOR_NAME = re.compile(r"^[A-Za-z0-9_.-]{1,128}$")


class SessionHelper:
    def __init__(self, environ=None, which=shutil.which):
        self.environ = dict(os.environ if environ is None else environ)
        self.desktop, self.session_type = detect_desktop(self.environ)
        self.wl_copy = which("wl-copy")
        self.wl_paste = which("wl-paste")
        self.hyprctl = which("hyprctl")

    def capabilities(self):
        capabilities = []
        if (
            self.session_type == "wayland"
            and self.environ.get("WAYLAND_DISPLAY")
            and self.wl_copy
            and self.wl_paste
        ):
            capabilities.extend(["clipboardRead", "clipboardWrite"])
        if (
            self.desktop == "hyprland"
            and self.session_type == "wayland"
            and self.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
            and self.hyprctl
        ):
            capabilities.append("displayResize")
        return capabilities

    def registration(self):
        release = parse_os_release()
        return {
            "type": "register",
            "uid": os.getuid(),
            "desktopEnvironment": self.desktop,
            "sessionType": self.session_type,
            "capabilities": self.capabilities(),
            "distroID": release.get("ID", "unknown"),
            "distroVersion": release.get("VERSION_ID", "unknown"),
        }

    def handle(self, request):
        if not isinstance(request, dict) or not isinstance(request.get("type"), str):
            return _failure("malformedRequest", "invalid session request")
        kind = request["type"]
        if kind == "readClipboard" and set(request) == {"type"}:
            if "clipboardRead" not in self.capabilities():
                return _failure("unavailable", "clipboard read is unavailable")
            try:
                output = _capture_limited(
                    [self.wl_paste, "--no-newline", "--type", "text"],
                    self.environ,
                    MAX_CLIPBOARD_SIZE,
                )
                text = output.decode("utf-8")
            except (OSError, subprocess.SubprocessError, UnicodeDecodeError) as exc:
                return _failure("clipboardReadFailed", str(exc))
            return {"type": "clipboard", "text": text}
        if kind == "writeClipboard" and set(request) == {"type", "text"}:
            text = request.get("text")
            if not isinstance(text, str):
                return _failure("malformedRequest", "clipboard text must be UTF-8")
            data = text.encode("utf-8")
            if len(data) > MAX_CLIPBOARD_SIZE:
                return _failure("clipboardTooLarge", "clipboard exceeds 1 MiB")
            if "clipboardWrite" not in self.capabilities():
                return _failure("unavailable", "clipboard write is unavailable")
            try:
                completed = subprocess.run(
                    [self.wl_copy, "--type", "text/plain;charset=utf-8"],
                    input=data,
                    shell=False,
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE,
                    timeout=3,
                    env=self.environ,
                )
            except (OSError, subprocess.SubprocessError) as exc:
                return _failure("clipboardWriteFailed", str(exc))
            if completed.returncode:
                return _failure("clipboardWriteFailed", "wl-copy failed")
            return {"type": "accepted", "operation": kind}
        if kind == "resizeDisplay" and set(request) == {"type", "width", "height"}:
            width, height = request.get("width"), request.get("height")
            if not valid_dimensions(width, height):
                return _failure("invalidDimensions", "display dimensions are invalid")
            if "displayResize" not in self.capabilities():
                return _failure("unavailable", "display resize is unavailable")
            return self._resize_hyprland(width, height)
        return _failure("notAllowed", "session request is not allowed")

    def _resize_hyprland(self, width, height):
        try:
            raw = _capture_limited(
                [self.hyprctl, "-j", "monitors"], self.environ, 256 * 1024
            )
            monitors = json.loads(raw.decode("utf-8"))
            if not isinstance(monitors, list) or not monitors:
                raise ValueError("Hyprland returned no monitors")
            monitor = next(
                (item for item in monitors if item.get("focused") is True), monitors[0]
            )
            name = monitor.get("name")
            if not isinstance(name, str) or not _MONITOR_NAME.fullmatch(name):
                raise ValueError("Hyprland returned an unsafe monitor name")
            completed = subprocess.run(
                [
                    self.hyprctl,
                    "keyword",
                    "monitor",
                    f"{name},{width}x{height},auto,1",
                ],
                shell=False,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                timeout=5,
                env=self.environ,
            )
        except (
            OSError,
            subprocess.SubprocessError,
            UnicodeDecodeError,
            json.JSONDecodeError,
            ValueError,
        ) as exc:
            return _failure("displayResizeFailed", str(exc))
        if completed.returncode:
            return _failure("displayResizeFailed", "hyprctl failed")
        return {
            "type": "accepted",
            "operation": "resizeDisplay",
            "width": width,
            "height": height,
        }


def valid_dimensions(width, height):
    return (
        isinstance(width, int)
        and not isinstance(width, bool)
        and isinstance(height, int)
        and not isinstance(height, bool)
        and 640 <= width <= 16384
        and 480 <= height <= 16384
    )


def _capture_limited(argv, environ, maximum, timeout=3):
    process = subprocess.Popen(
        argv,
        shell=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=environ,
    )
    output = bytearray()
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(argv, timeout)
            events = selector.select(remaining)
            if not events:
                raise subprocess.TimeoutExpired(argv, timeout)
            chunk = os.read(process.stdout.fileno(), min(65536, maximum + 1 - len(output)))
            if not chunk:
                break
            output.extend(chunk)
            if len(output) > maximum:
                raise OSError("command output exceeds size limit")
        return_code = process.wait(timeout=max(0.01, deadline - time.monotonic()))
        if return_code:
            raise subprocess.CalledProcessError(return_code, argv)
        return bytes(output)
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
            process.wait()


def _failure(code, message):
    return {"type": "failure", "code": code, "message": message[:512]}


def main():
    helper = SessionHelper()
    while True:
        connection = None
        try:
            connection = connect_to_root()
            write_frame(connection, helper.registration())
            while True:
                request = read_frame(connection)
                write_frame(connection, helper.handle(request))
        except (OSError, EOFError, ProtocolError, PermissionError):
            time.sleep(2)
        finally:
            if connection is not None:
                connection.close()


if __name__ == "__main__":
    main()
