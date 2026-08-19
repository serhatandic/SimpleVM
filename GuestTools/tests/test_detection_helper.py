import os
import subprocess
import tempfile
import unittest
from unittest import mock

from simplevm_guest_tools.detection import detect_desktop, parse_os_release
from simplevm_guest_tools.protocol import MAX_CLIPBOARD_SIZE
from simplevm_guest_tools.user_helper import SessionHelper, valid_dimensions


class DetectionTests(unittest.TestCase):
    def test_distro_detection_from_safe_file(self):
        tests_directory = os.path.dirname(__file__)
        with tempfile.TemporaryDirectory(dir=tests_directory) as directory:
            path = os.path.join(directory, "os-release")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write('ID=arch\nVERSION_ID="rolling"\nNAME=Arch Linux\n')
            values = parse_os_release(path)
        self.assertEqual(values["ID"], "arch")
        self.assertEqual(values["VERSION_ID"], "rolling")

    def test_desktop_and_session_detection(self):
        self.assertEqual(
            detect_desktop(
                {
                    "XDG_CURRENT_DESKTOP": "Hyprland",
                    "XDG_SESSION_TYPE": "wayland",
                    "HYPRLAND_INSTANCE_SIGNATURE": "test",
                }
            ),
            ("hyprland", "wayland"),
        )
        self.assertEqual(
            detect_desktop(
                {"XDG_CURRENT_DESKTOP": "GNOME", "XDG_SESSION_TYPE": "x11"}
            ),
            ("gnome", "x11"),
        )
        self.assertEqual(detect_desktop({}), ("other", "other"))


class SessionHelperTests(unittest.TestCase):
    @staticmethod
    def helper():
        commands = {
            "wl-copy": "/usr/bin/wl-copy",
            "wl-paste": "/usr/bin/wl-paste",
            "hyprctl": "/usr/bin/hyprctl",
        }
        return SessionHelper(
            {
                "XDG_CURRENT_DESKTOP": "Hyprland",
                "XDG_SESSION_TYPE": "wayland",
                "WAYLAND_DISPLAY": "wayland-1",
                "HYPRLAND_INSTANCE_SIGNATURE": "instance",
            },
            which=commands.get,
        )

    def test_capability_gating(self):
        self.assertEqual(
            self.helper().capabilities(),
            ["clipboardRead", "clipboardWrite", "displayResize"],
        )
        x11 = SessionHelper(
            {"XDG_CURRENT_DESKTOP": "GNOME", "XDG_SESSION_TYPE": "x11"},
            which=lambda name: "/usr/bin/" + name,
        )
        self.assertEqual(x11.capabilities(), [])

    def test_clipboard_exact_limit_and_rejection(self):
        helper = self.helper()
        completed = subprocess.CompletedProcess([], 0, b"", b"")
        with mock.patch("simplevm_guest_tools.user_helper.subprocess.run") as run:
            run.return_value = completed
            response = helper.handle(
                {"type": "writeClipboard", "text": "x" * MAX_CLIPBOARD_SIZE}
            )
            self.assertEqual(response["type"], "accepted")
            self.assertFalse(run.call_args.kwargs["shell"])
        response = helper.handle(
            {"type": "writeClipboard", "text": "x" * (MAX_CLIPBOARD_SIZE + 1)}
        )
        self.assertEqual(response["code"], "clipboardTooLarge")

    def test_resize_dimensions(self):
        self.assertTrue(valid_dimensions(640, 480))
        self.assertTrue(valid_dimensions(16384, 16384))
        self.assertFalse(valid_dimensions(639, 480))
        self.assertFalse(valid_dimensions(640, 16385))
        self.assertFalse(valid_dimensions(True, 800))

    def test_helper_rejects_non_allowlisted_fields(self):
        helper = self.helper()
        response = helper.handle(
            {"type": "resizeDisplay", "width": 800, "height": 600, "command": "x"}
        )
        self.assertEqual(response["code"], "notAllowed")


if __name__ == "__main__":
    unittest.main()
