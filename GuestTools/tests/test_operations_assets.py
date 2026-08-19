import json
import os
import subprocess
import unittest
from unittest import mock

from simplevm_guest_tools import operations


class OperationTests(unittest.TestCase):
    def test_fixed_mount_validation(self):
        self.assertTrue(
            operations.validate_mount_request({"type": "mountSharedDirectory"})
        )
        self.assertFalse(
            operations.validate_mount_request(
                {"type": "mountSharedDirectory", "source": "evil"}
            )
        )

    def test_mount_uses_only_fixed_arguments(self):
        before = {
            "mounted": False,
            "state": "notMounted",
            "mountPoint": operations.MOUNT_POINT,
            "tag": operations.MOUNT_TAG,
            "filesystem": operations.MOUNT_FILESYSTEM,
        }
        after = dict(before, mounted=True, state="mounted")
        run = mock.Mock(
            return_value=subprocess.CompletedProcess([], returncode=0, stderr="")
        )
        with mock.patch(
            "simplevm_guest_tools.operations.shared_mount_status",
            side_effect=[before, after],
        ):
            result = operations.mount_shared_directory(
                run=run, makedirs=mock.Mock()
            )
        self.assertEqual(result["state"], "mounted")
        self.assertEqual(
            run.call_args.args[0],
            [
                "/usr/bin/mount",
                "-t",
                "virtiofs",
                "share",
                "/mnt/simplevm-share",
            ],
        )
        self.assertFalse(run.call_args.kwargs["shell"])

    def test_power_allowlist(self):
        with self.assertRaises(ValueError):
            operations.power("halt")


class AssetTests(unittest.TestCase):
    def test_installer_assets_and_manifest(self):
        root = os.path.dirname(os.path.dirname(__file__))
        required = [
            "install.sh",
            "uninstall.sh",
            "README.md",
            "SECURITY.md",
            "VERSION",
            "manifest.json",
            "bin/simplevm-guest-tools-daemon",
            "bin/simplevm-guest-tools-session",
            "systemd/simplevm-guest-tools.service",
            "systemd/simplevm-guest-tools-session.service",
        ]
        for relative_path in required:
            with self.subTest(path=relative_path):
                self.assertTrue(os.path.isfile(os.path.join(root, relative_path)))
        with open(os.path.join(root, "manifest.json"), encoding="utf-8") as handle:
            manifest = json.load(handle)
        self.assertEqual(manifest["protocolVersion"], 2)
        self.assertIn("vsock:1021", manifest["transports"])
        with open(
            os.path.join(root, "systemd/simplevm-guest-tools.service"),
            encoding="utf-8",
        ) as handle:
            root_unit = handle.read()
        self.assertIn("CAP_NET_BIND_SERVICE", root_unit)
        self.assertNotIn("PrivateTmp=yes", root_unit)

    def test_scripts_are_executable(self):
        root = os.path.dirname(os.path.dirname(__file__))
        for relative_path in (
            "install.sh",
            "uninstall.sh",
            "self-test.sh",
            "bin/simplevm-guest-tools-daemon",
            "bin/simplevm-guest-tools-session",
        ):
            self.assertTrue(
                os.access(os.path.join(root, relative_path), os.X_OK),
                relative_path,
            )


if __name__ == "__main__":
    unittest.main()
