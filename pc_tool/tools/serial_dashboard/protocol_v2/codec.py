"""Pure v2 codec, separate from the hardware transport.

Session lifetime/SEQ handling belongs to the device transaction manager. A valid
frame alone does not mean acceptance or a complete video frame.
"""
from __future__ import annotations
from dataclasses import dataclass
from enum import IntEnum

VERSION = 2
COMMAND_SIZE = 16
RESPONSE_SIZE = 37

class CommandOp(IntEnum):
    HELLO = 0x00
    QUERY_STATUS = 0x01
    GOTO = 0x10
    SET_AUTO = 0x11
    NEXT = 0x16
    PREV = 0x17

class AckCode(IntEnum):
    ACCEPTED = 0
    BUSY = 1
    BAD_ARGUMENT = 2
    UNSUPPORTED = 3
    SEQ_CONFLICT = 4
    LOCKED = 5
    BAD_SESSION = 6
    STALE = 7
    UNAVAILABLE = 8

class ResultCode(IntEnum):
    PRESENTED = 1
    APPLIED = 2
    STATUS = 3
    FAILED = 4
    SUPERSEDED = 5
    CANCELLED = 6
    SESSION_READY = 7

class FailureCode(IntEnum):
    LOAD = 1
    PREFETCH = 2
    OUTPUT = 3
    UNAVAILABLE = 4

class CancelReason(IntEnum):
    LOCAL_OVERRIDE = 1
    EMERGENCY = 2

class FrameError(ValueError):
    def __init__(self, reason: str, message: str):
        self.reason = reason
        super().__init__(message)

@dataclass(frozen=True, slots=True)
class Command:
    seq: int
    op: CommandOp
    arg: int
    session: int

@dataclass(frozen=True, slots=True)
class Response:
    record_type: int
    seq: int
    op: int
    code: AckCode | ResultCode
    session: int
    value: int

def _bytes(data):
    if not isinstance(data, (bytes, bytearray, memoryview)):
        raise TypeError("bytes, bytearray or memoryview required")
    return bytes(data)

def _uint(value, bits, field):
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{field} requires an integer, not bool")
    if not 0 <= value < 1 << bits:
        raise FrameError(field, f"{field} must fit uint{bits}")
    return value

def crc16_ccitt_false(data):
    crc = 0xffff
    for octet in _bytes(data):
        crc ^= octet << 8
        for _ in range(8):
            crc = ((crc << 1) ^ (0x1021 if crc & 0x8000 else 0)) & 0xffff
    return crc

def _command(seq, op, arg, session):
    for v, n, k in ((seq, 16, "sequence"), (op, 8, "opcode"),
                    (arg, 32, "argument"), (session, 32, "session")):
        _uint(v, n, k)
    try:
        op = CommandOp(op)
    except ValueError as exc:
        raise FrameError("opcode", "unsupported command") from exc
    if not session:
        raise FrameError("session", "zero is not an established session token")
    if (op == CommandOp.HELLO) != (seq == 0):
        raise FrameError("sequence", "HELLO requires SEQ=0; other commands require SEQ=1..65535")
    legal = 1 <= arg <= 5 if op == CommandOp.GOTO else arg <= 1 if op == CommandOp.SET_AUTO else arg == 0
    if not legal:
        raise FrameError("argument", "bad command argument or reserved bits")
    return Command(seq, op, arg, session)

def encode_command(seq, op, arg=0, *, session):
    c = _command(seq, op, arg, session)
    body = (b"\xa5\x5a" + bytes((VERSION, c.op)) + c.seq.to_bytes(2, "little")
            + c.arg.to_bytes(4, "little") + c.session.to_bytes(4, "little"))
    return body + crc16_ccitt_false(body[2:]).to_bytes(2, "little")

def decode_command(data):
    raw = _bytes(data)
    if len(raw) != COMMAND_SIZE:
        raise FrameError("length", "command must contain 16 bytes")
    if raw[:2] != b"\xa5\x5a":
        raise FrameError("sof", "bad command synchronization")
    if crc16_ccitt_false(raw[2:14]) != int.from_bytes(raw[14:], "little"):
        raise FrameError("crc", "command CRC mismatch")
    if raw[2] != VERSION:
        raise FrameError("version", "command is not v2")
    return _command(int.from_bytes(raw[4:6], "little"), raw[3],
                    int.from_bytes(raw[6:10], "little"), int.from_bytes(raw[10:14], "little"))

def _payload(data):
    raw = _bytes(data)
    if len(raw) != RESPONSE_SIZE:
        raise FrameError("length", "response must contain 37 bytes")
    if raw[:3] != b"AX " or raw[-2:] != b"\r\n":
        raise FrameError("envelope", "bad AX envelope")
    if any(c not in b"0123456789ABCDEF" for c in raw[3:35]):
        raise FrameError("hex", "uppercase hexadecimal required")
    return bytes.fromhex(raw[3:35].decode("ascii"))

def _response(kind, seq, op, code, session, value):
    for v, n, k in ((seq, 16, "sequence"), (op, 8, "opcode"), (code, 8, "code"),
                    (session, 32, "session"), (value, 32, "value")):
        _uint(v, n, k)
    if kind not in (11, 12):
        raise FrameError("type", "v2 only defines AX type 11 and 12")
    try:
        code = AckCode(code) if kind == 11 else ResultCode(code)
    except ValueError as exc:
        raise FrameError("code", "undefined response code") from exc
    if kind == 11:
        if value:
            raise FrameError("value", "ACK value must be zero")
        if code == AckCode.ACCEPTED:
            try:
                operation = CommandOp(op)
            except ValueError as exc:
                raise FrameError("opcode", "ACCEPTED requires a supported opcode") from exc
            if not session or ((operation == CommandOp.HELLO) != (seq == 0)):
                raise FrameError("sequence", "invalid accepted identity")
    else:
        try:
            operation = CommandOp(op)
        except ValueError as exc:
            raise FrameError("opcode", "RESULT requires a supported opcode") from exc
        nav = operation in (CommandOp.GOTO, CommandOp.NEXT, CommandOp.PREV)
        valid = False
        if code == ResultCode.SESSION_READY:
            valid = operation == CommandOp.HELLO and seq == 0 and value == 0
        elif code == ResultCode.PRESENTED:
            valid = nav and 1 <= value <= 5
        elif code == ResultCode.APPLIED:
            valid = operation == CommandOp.SET_AUTO and value <= 1
        elif code == ResultCode.STATUS:
            valid = (operation == CommandOp.QUERY_STATUS and not value & 0xff0000f8
                     and ((value >> 8) & 255) <= 5 and ((value >> 16) & 255) <= 5)
        elif code == ResultCode.FAILED:
            valid = nav and value in set(FailureCode)
        elif code == ResultCode.SUPERSEDED:
            valid = nav and seq < value <= 65535
        elif code == ResultCode.CANCELLED:
            valid = nav and value in set(CancelReason)
        if not valid or not session or (operation != CommandOp.HELLO and not seq):
            raise FrameError("value", "invalid RESULT identity/command/value")
    return Response(kind, seq, op, code, session, value)

def encode_response(record_type, seq, op, code, *, session, value=0):
    r = _response(record_type, seq, op, code, session, value)
    body = (bytes((VERSION, r.record_type)) + r.seq.to_bytes(2, "big") + bytes((r.op, r.code))
            + r.session.to_bytes(4, "big") + r.value.to_bytes(4, "big"))
    return b"AX " + (body + crc16_ccitt_false(body).to_bytes(2, "big")).hex().upper().encode() + b"\r\n"

def decode_response(data):
    p = _payload(data)
    if p[0] != VERSION:
        raise FrameError("version", "response is not v2")
    if crc16_ccitt_false(p[:14]) != int.from_bytes(p[14:], "big"):
        raise FrameError("crc", "response CRC mismatch")
    return _response(p[1], int.from_bytes(p[2:4], "big"), p[4], p[5],
                     int.from_bytes(p[6:10], "big"), int.from_bytes(p[10:14], "big"))

class _Stream:
    def __init__(self):
        self._pending = bytearray()
        self.discarded_bytes = self.invalid_candidates = self.expired_bytes = 0

    @property
    def pending_bytes(self):
        return len(self._pending)

    def feed(self, data):
        result = []
        for octet in _bytes(data):
            self._pending.append(octet)
            while self._pending:
                if not self.prefix.startswith(bytes(self._pending[:len(self.prefix)])):
                    del self._pending[0]
                    self.discarded_bytes += 1
                elif len(self._pending) < self.size:
                    break
                else:
                    try:
                        record = self._decode(bytes(self._pending))
                    except FrameError:
                        del self._pending[0]
                        self.invalid_candidates += 1
                        self.discarded_bytes += 1
                    else:
                        self._pending.clear()
                        if record is not None:
                            result.append(record)
        return result

    def expire_partial(self):
        n = len(self._pending)
        self._pending.clear()
        self.expired_bytes += n
        return n

class CommandStream(_Stream):
    prefix, size = b"\xa5\x5a", COMMAND_SIZE
    _decode = staticmethod(decode_command)

class ResponseStream(_Stream):
    prefix, size = b"AX ", RESPONSE_SIZE

    def __init__(self):
        super().__init__()
        self.legacy_records = self.unsupported_records = 0

    def _decode(self, raw):
        p = _payload(raw)
        if p[0] == 1 and p[1] <= 10:
            self.legacy_records += 1
            return None
        if p[0] != VERSION or p[1] not in (11, 12):
            self.unsupported_records += 1
            return None
        return decode_response(raw)
