"""Codec tests, with CRC checked against Python's binascii routine."""
import binascii
import random
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from protocol_v2 import *

S = 0x89abcdef

def raw_command(seq=1, op=0x16, arg=0, session=S, version=2):
    body = b'\xa5\x5a' + bytes((version, op)) + seq.to_bytes(2,'little') + arg.to_bytes(4,'little') + session.to_bytes(4,'little')
    return body + binascii.crc_hqx(body[2:], 0xffff).to_bytes(2,'little')

def raw_response(kind=11, seq=1, op=0x16, code=0, session=S, value=0, version=2):
    body = bytes((version,kind)) + seq.to_bytes(2,'big') + bytes((op,code)) + session.to_bytes(4,'big') + value.to_bytes(4,'big')
    return b'AX ' + (body + binascii.crc_hqx(body,0xffff).to_bytes(2,'big')).hex().upper().encode() + b'\r\n'

class CodecTests(unittest.TestCase):
    def test_crc_reference(self):
        self.assertEqual(crc16_ccitt_false(b'123456789'),0x29b1)
        rng=random.Random(20261016)
        for n in range(257):
            b=rng.randbytes(n)
            self.assertEqual(crc16_ccitt_false(b),binascii.crc_hqx(b,0xffff))

    def test_command_fields_and_endian(self):
        for seq in (1,255,256,0xa55a,65535):
            for op, args in ((1,[0]),(0x10,range(1,6)),(0x11,[0,1]),(0x16,[0]),(0x17,[0])):
                for arg in args:
                    b=encode_command(seq,op,arg,session=S)
                    self.assertEqual(b,raw_command(seq,op,arg))
                    self.assertEqual(decode_command(b),Command(seq,CommandOp(op),arg,S))
        self.assertEqual(encode_command(0,0,session=S),raw_command(0,0))

    def test_command_golden(self):
        expected=bytes.fromhex('A55A0216341200000000EFCDAB896A46')
        self.assertEqual(encode_command(0x1234,0x16,session=S),expected)
        self.assertEqual(raw_command(0x1234),expected)

    def test_session_and_sequence_rules(self):
        for args in ((0,0x16,0,S),(1,0,0,S),(0,0,0,0),(1,1,0,0)):
            with self.assertRaises(FrameError):decode_command(raw_command(*args))

    def test_argument_and_unknown(self):
        for op,arg in ((0x10,0),(0x10,6),(0x10,0x100),(0x11,2),(1,1),(0x16,1),(0xff,0)):
            with self.assertRaises(FrameError):decode_command(raw_command(op=op,arg=arg))

    def test_integer_types_and_bounds(self):
        for seq,op,arg,session in ((True,1,0,S),(1,False,0,S),(1,1,False,S),(1,1,0,True)):
            with self.assertRaises(TypeError):encode_command(seq,op,arg,session=session)
        for seq,op,arg,session in ((-1,1,0,S),(65536,1,0,S),(1,256,0,S),(1,1,1<<32,S),(1,1,0,1<<32)):
            with self.assertRaises(FrameError):encode_command(seq,op,arg,session=session)

    def test_every_command_bit(self):
        b=raw_command(0x1234)
        for bit in range(128):
            altered=bytearray(b);altered[bit//8]^=1<<(bit%8)
            with self.assertRaises(FrameError):decode_command(altered)

    def test_command_lengths_version(self):
        for n in range(16):
            with self.assertRaises(FrameError):decode_command(raw_command()[:n])
        for b in (raw_command()+b'0',raw_command(version=1)):
            with self.assertRaises(FrameError):decode_command(b)

    def test_command_stream_chunking_noise_nested(self):
        valid=[raw_command(1),raw_command(2,0x10,5),raw_command(3,0x17)]
        wire=b'noise\xa5\xa5\x5a\x02\xff'+b''.join(valid)+b'\xa5'
        for chunk in (1,2,7,16,99):
            s=CommandStream();out=[]
            for at in range(0,len(wire),chunk):
                out+=s.feed(wire[at:at+chunk]);self.assertLess(s.pending_bytes,16)
            self.assertEqual([r.seq for r in out],[1,2,3])
            self.assertEqual(s.expire_partial(),1)

    def test_command_stream_timeout(self):
        s=CommandStream();b=raw_command()
        self.assertEqual(s.feed(b[:8]),[]);self.assertEqual(s.expire_partial(),8)
        self.assertEqual(s.feed(b[8:]),[])
        self.assertEqual(s.feed(b),[decode_command(b)])

    def test_ack_codes_and_reject_identity(self):
        for code in AckCode:
            b=encode_response(11,1,0x16,code,session=S)
            self.assertEqual(b,raw_response(code=code))
            self.assertEqual(decode_response(b).code,code)
        self.assertEqual(decode_response(raw_response(seq=0,op=255,code=6,session=0)).code,6)

    def test_all_result_semantics(self):
        cases=[(0,0,7,0),(1,0x16,1,5),(2,0x11,2,1),(3,1,3,0x050305),
               (4,0x10,4,1),(4,0x10,4,2),(4,0x10,4,3),(4,0x10,4,4),
               (5,0x16,5,6),(6,0x17,6,1),(6,0x17,6,2)]
        for seq,op,code,value in cases:
            b=encode_response(12,seq,op,code,session=S,value=value)
            self.assertEqual(b,raw_response(12,seq,op,code,S,value))
            self.assertEqual(decode_response(b).value,value)

    def test_bad_result_semantics(self):
        for op,code,val in ((1,1,1),(0x16,1,0),(0x16,1,6),(0x11,2,2),
                            (1,3,8),(1,3,0x060000),(1,3,0x1000000),
                            (0x16,4,5),(0x16,5,1),(0x16,6,0),(0x16,6,3),(0,7,1)):
            with self.assertRaises(FrameError):decode_response(raw_response(12,1,op,code,S,val))

    def test_response_crc_bits_envelope(self):
        p=bytearray.fromhex(raw_response()[3:35].decode())
        for bit in range(128):
            b=bytearray(p);b[bit//8]^=1<<(bit%8)
            with self.assertRaises(FrameError):decode_response(b'AX '+b.hex().upper().encode()+b'\r\n')
        for b in (raw_response()[:-1],raw_response()+b'0',raw_response().lower(),raw_response(version=1)):
            with self.assertRaises(FrameError):decode_response(b)

    def test_legacy_and_mixed_response_stream(self):
        old=b'AX '+bytes([1,7]+[0]*14).hex().upper().encode()+b'\r\n'
        v1response=raw_response(version=1)
        new=raw_response()
        s=ResponseStream();result=[]
        for b in b'noise'+old+v1response+new:
            result+=s.feed(bytes([b]));self.assertLess(s.pending_bytes,37)
        self.assertEqual(result,[decode_response(new)])
        self.assertEqual((s.legacy_records,s.unsupported_records),(1,1))

    def test_bounded_noise(self):
        s=CommandStream();rng=random.Random(42)
        for _ in range(1000):
            s.feed(rng.randbytes(100));self.assertLess(s.pending_bytes,16)

if __name__=='__main__':unittest.main(verbosity=2)
