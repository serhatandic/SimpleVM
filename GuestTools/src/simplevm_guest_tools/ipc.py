"""Authenticated IPC between the root daemon and one desktop session helper."""

import os
import socket
import struct
import threading

from .protocol import ProtocolError, read_frame, write_frame

RUNTIME_DIRECTORY = "/run/simplevm-guest-tools"
SOCKET_PATH = RUNTIME_DIRECTORY + "/session.sock"
_CREDENTIALS = struct.Struct("3i")


def peer_credentials(connection):
    if not hasattr(socket, "SO_PEERCRED"):
        raise OSError("SO_PEERCRED is unavailable")
    raw = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, _CREDENTIALS.size)
    return _CREDENTIALS.unpack(raw)


class SessionBroker:
    def __init__(self, socket_path=SOCKET_PATH):
        self.socket_path = socket_path
        self._listener = None
        self._connection = None
        self._session = None
        self._lock = threading.Lock()
        self._stop = threading.Event()

    def start(self):
        os.makedirs(os.path.dirname(self.socket_path), mode=0o750, exist_ok=True)
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.socket_path)
        os.chmod(self.socket_path, 0o660)
        listener.listen(4)
        listener.settimeout(1)
        self._listener = listener
        threading.Thread(target=self._accept_loop, daemon=True).start()

    def stop(self):
        self._stop.set()
        if self._listener:
            self._listener.close()
        with self._lock:
            self._close_connection()
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass

    def _accept_loop(self):
        while not self._stop.is_set():
            try:
                connection, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            try:
                _, uid, _ = peer_credentials(connection)
                if uid == 0:
                    raise PermissionError("session helper must be unprivileged")
                connection.settimeout(5)
                registration = read_frame(connection)
                self._validate_registration(registration, uid)
                connection.settimeout(None)
                with self._lock:
                    self._close_connection()
                    self._connection = connection
                    self._session = registration
            except (OSError, EOFError, ProtocolError, PermissionError, ValueError):
                connection.close()

    @staticmethod
    def _validate_registration(registration, uid):
        required = {
            "type",
            "uid",
            "desktopEnvironment",
            "sessionType",
            "capabilities",
            "distroID",
            "distroVersion",
        }
        if set(registration) != required or registration.get("type") != "register":
            raise ValueError("invalid session registration")
        if registration["uid"] != uid:
            raise ValueError("registration UID does not match peer")
        if registration["desktopEnvironment"] not in ("gnome", "hyprland", "other"):
            raise ValueError("invalid desktop")
        if registration["sessionType"] not in ("wayland", "x11", "other"):
            raise ValueError("invalid session type")
        allowed = {"clipboardRead", "clipboardWrite", "displayResize"}
        capabilities = registration["capabilities"]
        if (
            not isinstance(capabilities, list)
            or len(capabilities) != len(set(capabilities))
            or not set(capabilities) <= allowed
        ):
            raise ValueError("invalid session capabilities")
        for key in ("distroID", "distroVersion"):
            if (
                not isinstance(registration[key], str)
                or len(registration[key].encode("utf-8")) > 128
            ):
                raise ValueError("invalid distro data")

    def snapshot(self):
        with self._lock:
            if self._connection is None:
                return None
            return dict(self._session)

    def call(self, request):
        with self._lock:
            if self._connection is None:
                raise ConnectionError("no desktop session helper is connected")
            try:
                self._connection.settimeout(8)
                write_frame(self._connection, request)
                response = read_frame(self._connection)
                self._connection.settimeout(None)
                return response
            except (OSError, EOFError, ProtocolError) as exc:
                self._close_connection()
                raise ConnectionError("desktop session helper disconnected") from exc

    def _close_connection(self):
        if self._connection is not None:
            try:
                self._connection.close()
            except OSError:
                pass
        self._connection = None
        self._session = None


def connect_to_root(socket_path=SOCKET_PATH):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(5)
    connection.connect(socket_path)
    _, uid, _ = peer_credentials(connection)
    if uid != 0:
        connection.close()
        raise PermissionError("session IPC peer is not root")
    connection.settimeout(None)
    return connection
