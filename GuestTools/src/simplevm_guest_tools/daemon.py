"""Root daemon for QEMU virtio-serial and Apple VZ AF_VSOCK transports."""

import errno
import logging
import os
import socket
import threading
import time

from . import AGENT_VERSION, PROTOCOL_VERSION
from .detection import ip_addresses, system_identity
from .ipc import SessionBroker
from .operations import mount_shared_directory, power, shared_mount_status
from .protocol import (
    MAX_CLIPBOARD_SIZE,
    ProtocolError,
    decode_request,
    read_frame,
    response_message,
    write_frame,
)

VIRTIO_PORT = "/dev/virtio-ports/com.simplevm.agent.0"
VSOCK_PORT = 1021
LOG = logging.getLogger("simplevm-guest-tools")


class Agent:
    def __init__(self, broker=None):
        self.broker = broker if broker is not None else SessionBroker()

    def status(self):
        session = self.broker.snapshot()
        identity = system_identity()
        capabilities = [
            "gracefulShutdown",
            "gracefulReboot",
            "mountSharedDirectory",
        ]
        desktop = "other"
        session_type = "other"
        if session:
            desktop = session["desktopEnvironment"]
            session_type = session["sessionType"]
            capabilities.extend(session["capabilities"])
            identity["distroID"] = session["distroID"]
            identity["distroVersion"] = session["distroVersion"]
        return {
            "type": "status",
            "protocolVersion": PROTOCOL_VERSION,
            "agentVersion": AGENT_VERSION,
            **identity,
            "ipAddresses": ip_addresses(),
            "desktopEnvironment": desktop,
            "sessionType": session_type,
            "capabilities": capabilities,
            "sharedMountStatus": shared_mount_status(),
        }

    def dispatch(self, request):
        kind = request["type"]
        if kind == "status":
            return self.status()
        if kind in ("shutdown", "reboot"):
            action = "poweroff" if kind == "shutdown" else "reboot"
            ok, message = power(action)
            if ok:
                return {"type": "accepted", "operation": kind}
            return _failure("powerOperationFailed", message)
        if kind == "mountSharedDirectory":
            state = mount_shared_directory()
            if state.get("state") == "error" or (
                state.get("mounted") and state.get("state") == "occupied"
            ):
                return _failure(
                    "mountFailed", state.get("error", "mount point is occupied"), state
                )
            return {
                "type": "accepted",
                "operation": kind,
                "sharedMountStatus": state,
            }
        if kind in ("readClipboard", "writeClipboard", "resizeDisplay"):
            payload = {"type": kind}
            for key in ("text", "width", "height"):
                if key in request:
                    payload[key] = request[key]
            try:
                response = self.broker.call(payload)
            except ConnectionError as exc:
                return _failure("sessionUnavailable", str(exc))
            if not isinstance(response, dict):
                return _failure("invalidSessionResponse", "session helper response is invalid")
            if (
                response.get("type") == "clipboard"
                and isinstance(response.get("text"), str)
                and len(response["text"].encode("utf-8")) <= MAX_CLIPBOARD_SIZE
            ):
                return response
            if response.get("type") in ("accepted", "failure"):
                return response
            return _failure("invalidSessionResponse", "session helper response is invalid")
        return _failure("notAllowed", "operation is not allowed")

    def serve_stream(self, stream):
        while True:
            try:
                message = read_frame(stream)
                request = decode_request(message)
                response = self.dispatch(request)
                write_frame(stream, response_message(request, response))
            except (EOFError, OSError, ProtocolError):
                return


def _failure(code, message, state=None):
    result = {"type": "failure", "code": code, "message": str(message)[:512]}
    if state is not None:
        result["sharedMountStatus"] = state
    return result


def _virtio_loop(agent):
    while True:
        try:
            descriptor = os.open(VIRTIO_PORT, os.O_RDWR | os.O_CLOEXEC)
            with os.fdopen(descriptor, "r+b", buffering=0) as stream:
                LOG.info("using QEMU virtio-serial transport at %s", VIRTIO_PORT)
                agent.serve_stream(stream)
        except OSError as exc:
            LOG.debug("virtio-serial unavailable: %s", exc)
            time.sleep(2)
            continue
        # The host opens one chardev connection per request. Avoid a busy loop
        # while still making the next request available promptly.
        time.sleep(0.05)


def _vsock_loop(agent):
    if not hasattr(socket, "AF_VSOCK") or not hasattr(socket, "VMADDR_CID_ANY"):
        LOG.warning("AF_VSOCK is unavailable; Apple VZ transport disabled")
        return
    while True:
        listener = None
        try:
            listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            listener.bind((socket.VMADDR_CID_ANY, VSOCK_PORT))
            listener.listen(8)
            LOG.info("listening for Apple VZ connections on AF_VSOCK port %d", VSOCK_PORT)
            while True:
                connection, _ = listener.accept()
                threading.Thread(
                    target=_serve_socket, args=(agent, connection), daemon=True
                ).start()
        except OSError as exc:
            if exc.errno == errno.EACCES:
                LOG.error(
                    "permission denied binding AF_VSOCK port %d; "
                    "the service requires CAP_NET_BIND_SERVICE",
                    VSOCK_PORT,
                )
                return
            LOG.warning("AF_VSOCK port %d unavailable: %s", VSOCK_PORT, exc)
            time.sleep(5)
        finally:
            if listener is not None:
                listener.close()


def _serve_socket(agent, connection):
    with connection:
        agent.serve_stream(connection)


def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    broker = SessionBroker()
    broker.start()
    agent = Agent(broker)
    threading.Thread(target=_virtio_loop, args=(agent,), daemon=True).start()
    threading.Thread(target=_vsock_loop, args=(agent,), daemon=True).start()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
