import io
import json
import struct
import unittest

from simplevm_guest_tools.protocol import (
    MAX_CLIPBOARD_SIZE,
    MAX_FRAME_SIZE,
    ProtocolError,
    decode_request,
    encode_frame,
    read_frame,
    response_message,
)


class ProtocolTests(unittest.TestCase):
    def test_new_frame_round_trip(self):
        message = {
            "protocolVersion": 2,
            "requestID": "abc",
            "request": {"type": "status"},
        }
        self.assertEqual(read_frame(io.BytesIO(encode_frame(message))), message)
        request = decode_request(message)
        self.assertEqual(request["type"], "status")
        self.assertEqual(
            response_message(request, {"type": "accepted"}),
            {
                "protocolVersion": 2,
                "requestID": "abc",
                "response": {"type": "accepted"},
            },
        )

    def test_legacy_swift_requests(self):
        cases = [
            ({"hello": {"protocolVersion": 1}}, "status"),
            ({"status": {}}, "status"),
            ({"shutdown": {}}, "shutdown"),
            ({"reboot": {}}, "reboot"),
        ]
        for wire, expected in cases:
            with self.subTest(wire=wire):
                request = decode_request(wire)
                self.assertTrue(request["legacy"])
                self.assertEqual(request["type"], expected)
                self.assertEqual(
                    response_message(request, {"type": "accepted"}),
                    {"accepted": {}},
                )

    def test_malformed_and_oversized_frames_fail(self):
        malformed = struct.pack(">I", 2) + b"[]"
        with self.assertRaises(ProtocolError):
            read_frame(io.BytesIO(malformed))
        oversized = struct.pack(">I", MAX_FRAME_SIZE + 1)
        with self.assertRaises(ProtocolError):
            read_frame(io.BytesIO(oversized))
        bad_utf8 = struct.pack(">I", 1) + b"\xff"
        with self.assertRaises(ProtocolError):
            read_frame(io.BytesIO(bad_utf8))
        duplicate = b'{"status":{},"status":{}}'
        with self.assertRaises(ProtocolError):
            read_frame(io.BytesIO(struct.pack(">I", len(duplicate)) + duplicate))

    def test_clipboard_limit_is_utf8_bytes(self):
        exact = "x" * MAX_CLIPBOARD_SIZE
        request = decode_request(
            {
                "protocolVersion": 2,
                "requestID": "clip",
                "request": {"type": "writeClipboard", "text": exact},
            }
        )
        self.assertEqual(request["text"], exact)
        with self.assertRaises(ProtocolError):
            decode_request(
                {
                    "protocolVersion": 2,
                    "requestID": "clip",
                    "request": {"type": "writeClipboard", "text": exact + "x"},
                }
            )
        with self.assertRaises(ProtocolError):
            decode_request(
                {
                    "protocolVersion": 2,
                    "requestID": "clip",
                    "request": {
                        "type": "writeClipboard",
                        "text": "\u00e9" * (MAX_CLIPBOARD_SIZE // 2 + 1),
                    },
                }
            )

    def test_allowlist_rejects_extra_and_unknown_fields(self):
        dangerous = [
            {"type": "runCommand", "command": "id"},
            {"type": "mountSharedDirectory", "source": "/dev/sda"},
            {"type": "mountSharedDirectory", "path": "/root"},
            {"type": "shutdown", "command": "anything"},
            {"type": "readClipboard", "path": "/etc/shadow"},
        ]
        for body in dangerous:
            with self.subTest(body=body), self.assertRaises(ProtocolError):
                decode_request(
                    {
                        "protocolVersion": 2,
                        "requestID": "reject",
                        "request": body,
                    }
                )

    def test_resize_validation(self):
        for width, height in ((640, 480), (16384, 16384)):
            request = decode_request(
                {
                    "protocolVersion": 2,
                    "requestID": "resize",
                    "request": {
                        "type": "resizeDisplay",
                        "width": width,
                        "height": height,
                    },
                }
            )
            self.assertEqual((request["width"], request["height"]), (width, height))
        for width, height in ((639, 480), (640, 479), (16385, 480), (True, 800)):
            with self.subTest(width=width, height=height), self.assertRaises(
                ProtocolError
            ):
                decode_request(
                    {
                        "protocolVersion": 2,
                        "requestID": "resize",
                        "request": {
                            "type": "resizeDisplay",
                            "width": width,
                            "height": height,
                        },
                    }
                )


if __name__ == "__main__":
    unittest.main()
