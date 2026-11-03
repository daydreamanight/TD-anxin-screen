"""v2 codec only: no serial device access or automatic retry."""
from .codec import (AckCode, CommandOp, Command, Response, ResultCode, FailureCode,
                    CancelReason, FrameError, CommandStream, ResponseStream,
                    crc16_ccitt_false, encode_command, decode_command,
                    encode_response, decode_response)
