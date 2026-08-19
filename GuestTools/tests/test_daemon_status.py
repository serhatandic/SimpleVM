import socket
import threading
import unittest
from unittest import mock

from simplevm_guest_tools.daemon import Agent
from simplevm_guest_tools.protocol import read_frame, write_frame


class FakeBroker:
    def snapshot(self):
        return {
            "desktopEnvironment": "hyprland",
            "sessionType": "wayland",
            "capabilities": [
                "clipboardRead",
                "clipboardWrite",
                "displayResize",
            ],
            "distroID": "arch",
            "distroVersion": "rolling",
        }


class StatusTests(unittest.TestCase):
    def test_status_has_required_fields_and_capabilities(self):
        mount_status = {
            "mounted": False,
            "state": "notMounted",
            "mountPoint": "/mnt/simplevm-share",
            "tag": "share",
            "filesystem": "virtiofs",
        }
        identity = {
            "hostname": "guest",
            "operatingSystem": "Linux",
            "distroID": "unused",
            "distroVersion": "unused",
        }
        with mock.patch(
            "simplevm_guest_tools.daemon.system_identity", return_value=identity
        ), mock.patch(
            "simplevm_guest_tools.daemon.ip_addresses",
            return_value=["192.0.2.2"],
        ), mock.patch(
            "simplevm_guest_tools.daemon.shared_mount_status",
            return_value=mount_status,
        ):
            status = Agent(FakeBroker()).status()
        required = {
            "type",
            "protocolVersion",
            "agentVersion",
            "hostname",
            "ipAddresses",
            "operatingSystem",
            "distroID",
            "distroVersion",
            "desktopEnvironment",
            "sessionType",
            "capabilities",
            "sharedMountStatus",
        }
        self.assertEqual(set(status), required)
        self.assertEqual(status["protocolVersion"], 2)
        self.assertEqual(status["desktopEnvironment"], "hyprland")
        self.assertEqual(
            set(status["capabilities"]),
            {
                "gracefulShutdown",
                "gracefulReboot",
                "mountSharedDirectory",
                "clipboardRead",
                "clipboardWrite",
                "displayResize",
            },
        )

    def test_status_round_trip_over_live_stream(self):
        host, guest = socket.socketpair()
        agent = Agent(FakeBroker())
        worker = threading.Thread(
            target=agent.serve_stream, args=(guest,), daemon=True
        )
        worker.start()
        try:
            write_frame(
                host,
                {
                    "protocolVersion": 2,
                    "requestID": "status-live-1",
                    "request": {"type": "status"},
                },
            )
            response = read_frame(host)
            self.assertEqual(response["protocolVersion"], 2)
            self.assertEqual(response["requestID"], "status-live-1")
            self.assertEqual(response["response"]["type"], "status")
        finally:
            host.close()
            guest.close()
            worker.join(timeout=1)


if __name__ == "__main__":
    unittest.main()
