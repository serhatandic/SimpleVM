"""Length-prefixed host protocol and strict request validation."""

import json
import struct

from . import PROTOCOL_VERSION

MAX_FRAME_SIZE = 2 * 1024 * 1024
MAX_CLIPBOARD_SIZE = 1024 * 1024
_HEADER = struct.Struct(">I")
_SIMPLE_TYPES = {
    "status",
    "shutdown",
    "reboot",
    "mountSharedDirectory",
    "readClipboard",
}
_ALL_TYPES = _SIMPLE_TYPES | {"writeClipboard", "resizeDisplay"}
_LEGACY_TYPES = {"hello", "status", "shutdown", "reboot"}


class ProtocolError(ValueError):
    """A frame or request that must not be processed."""


def encode_frame(message):
    try:
        payload = json.dumps(
            message, ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise ProtocolError("message is not JSON encodable") from exc
    if len(payload) > MAX_FRAME_SIZE:
        raise ProtocolError("frame exceeds 2 MiB")
    return _HEADER.pack(len(payload)) + payload


def read_frame(stream):
    header = _read_exact(stream, _HEADER.size)
    length = _HEADER.unpack(header)[0]
    if length == 0 or length > MAX_FRAME_SIZE:
        raise ProtocolError("invalid frame length")
    raw = _read_exact(stream, length)
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_strict_object,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, ValueError) as exc:
        raise ProtocolError("frame is not UTF-8 JSON") from exc
    if not isinstance(value, dict):
        raise ProtocolError("top-level JSON value must be an object")
    return value


def _strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON object key")
        result[key] = value
    return result


def _reject_constant(value):
    raise ValueError("non-finite JSON number")


def write_frame(stream, message):
    data = encode_frame(message)
    if hasattr(stream, "sendall"):
        stream.sendall(data)
    else:
        stream.write(data)
        if hasattr(stream, "flush"):
            stream.flush()


def _read_exact(stream, count):
    chunks = []
    remaining = count
    while remaining:
        if hasattr(stream, "recv"):
            chunk = stream.recv(remaining)
        else:
            chunk = stream.read(remaining)
        if not chunk:
            raise EOFError("transport closed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def decode_request(message):
    """Return a normalized request with ``legacy`` and ``request_id`` fields."""
    if set(message) == {"protocolVersion", "requestID", "request"}:
        if (
            type(message["protocolVersion"]) is not int
            or message["protocolVersion"] != PROTOCOL_VERSION
        ):
            raise ProtocolError("unsupported protocol version")
        request_id = message["requestID"]
        if (
            not isinstance(request_id, str)
            or not request_id
            or len(request_id.encode("utf-8")) > 256
        ):
            raise ProtocolError("invalid requestID")
        request = message["request"]
        normalized = _validate_new_request(request)
        normalized.update({"legacy": False, "request_id": request_id})
        return normalized

    if len(message) == 1:
        kind, body = next(iter(message.items()))
        if kind in _LEGACY_TYPES and isinstance(body, dict):
            if kind == "hello":
                if set(body) != {"protocolVersion"}:
                    raise ProtocolError("malformed legacy hello")
                if (
                    type(body["protocolVersion"]) is not int
                    or body["protocolVersion"] != 1
                ):
                    raise ProtocolError("unsupported legacy protocol version")
                kind = "status"
            elif body:
                raise ProtocolError("legacy request body must be empty")
            return {"type": kind, "legacy": True, "request_id": None}

    raise ProtocolError("unrecognized request envelope")


def _validate_new_request(request):
    if not isinstance(request, dict) or not isinstance(request.get("type"), str):
        raise ProtocolError("request must contain a string type")
    kind = request["type"]
    if kind not in _ALL_TYPES:
        raise ProtocolError("request type is not allowed")
    if kind in _SIMPLE_TYPES:
        if set(request) != {"type"}:
            raise ProtocolError("unexpected fields for request type")
        return {"type": kind}
    if kind == "writeClipboard":
        if set(request) != {"type", "text"} or not isinstance(
            request.get("text"), str
        ):
            raise ProtocolError("writeClipboard requires text only")
        if len(request["text"].encode("utf-8")) > MAX_CLIPBOARD_SIZE:
            raise ProtocolError("clipboard exceeds 1 MiB")
        return {"type": kind, "text": request["text"]}
    if set(request) != {"type", "width", "height"}:
        raise ProtocolError("resizeDisplay requires width and height only")
    width = request["width"]
    height = request["height"]
    if (
        isinstance(width, bool)
        or isinstance(height, bool)
        or not isinstance(width, int)
        or not isinstance(height, int)
        or not 640 <= width <= 16384
        or not 480 <= height <= 16384
    ):
        raise ProtocolError("display dimensions are outside the allowed range")
    return {"type": kind, "width": width, "height": height}


def response_message(request, response):
    if request["legacy"]:
        kind = response.get("type")
        body = {key: value for key, value in response.items() if key != "type"}
        return {kind: body}
    return {
        "protocolVersion": PROTOCOL_VERSION,
        "requestID": request["request_id"],
        "response": response,
    }
