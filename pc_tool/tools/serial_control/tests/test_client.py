"""No pyserial imports or real COM operations. Fake bytes/clock only."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from serial_control import ControlClient,ClientError
from serial_control.client import CommandOp,AckCode,ResultCode
from protocol_v2 import encode_response,decode_command

S=0x89abcdef;T=0x12345678
class Clock:
    now=0.0
    def __call__(self):return self.now
    def advance(self,n):self.now+=n

class Fake:
    def __init__(self):self.writes=[];self.incoming=bytearray();self.closed=False;self.partial=False;self.failread=False
    def write(self,data):
        self.writes.append(bytes(data))
        return 7 if self.partial else len(data)
    def read(self,n):
        if self.failread:raise OSError('fake disconnect')
        out=bytes(self.incoming[:n]);del self.incoming[:n];return out
    def close(self):self.closed=True
    def response(self,kind,seq,op,code,session=S,value=0):
        self.incoming.extend(encode_response(kind,seq,op,code,session=session,value=value))

class Tests(unittest.TestCase):
    def setUp(self):self.clock=Clock();self.f=Fake();self.c=ControlClient(clock=self.clock)
    def ready(self):
        self.c.connect(self.f,session=S)
        self.f.response(11,0,0,0);self.f.response(12,0,0,7);self.c.poll()
        self.assertTrue(self.c.ready)
    def ack(self,seq,op=0x16,code=0):self.f.response(11,seq,op,code);self.c.poll()
    def result(self,seq,op=0x16,code=1,value=3):self.f.response(12,seq,op,code,value=value);self.c.poll()
    def row(self,seq):return next(t for t in self.c.transactions() if t['seq']==seq)

    def test_default_and_import_do_not_connect(self):
        self.assertFalse(self.c.connected);self.assertEqual(self.f.writes,[])
        self.c.poll();self.c.check_timeouts();self.assertEqual(self.f.writes,[])

    def test_hello_requires_result_before_control(self):
        self.c.connect(self.f,session=S)
        self.assertEqual(decode_command(self.f.writes[0]).op,CommandOp.HELLO)
        self.f.response(11,0,0,0);self.c.poll()
        self.assertFalse(self.c.ready)
        with self.assertRaises(ClientError):self.c.request(0x16)
        self.f.response(12,0,0,7);self.c.poll();self.assertTrue(self.c.ready)

    def test_ack_is_not_presented(self):
        self.ready();seq=self.c.request(0x16);self.ack(seq)
        self.assertEqual(self.row(seq)['state'],'ACCEPTED');self.assertIsNone(self.row(seq)['result'])
        self.result(seq);self.assertEqual(self.row(seq)['result'],'PRESENTED')

    def test_only_one_waiting_ack(self):
        self.ready();self.c.request(0x16)
        with self.assertRaises(ClientError):self.c.request(0x17)
        self.assertEqual(len(self.f.writes),2)

    def test_accepted_allows_next_before_terminal(self):
        self.ready();a=self.c.request(0x16);self.ack(a)
        b=self.c.request(0x17);self.ack(b,0x17)
        self.result(a,code=5,value=b);self.result(b,op=0x17,value=2)
        self.assertEqual((self.row(a)['result'],self.row(b)['result']),('SUPERSEDED','PRESENTED'))

    def test_ack_loss_retry_identical_bytes(self):
        self.ready();seq=self.c.request(0x16);raw=self.f.writes[-1]
        self.clock.advance(2);self.c.poll()
        self.assertEqual(self.row(seq)['state'],'UNKNOWN')
        self.assertEqual(len(self.f.writes),2)
        with self.assertRaises(ClientError):self.c.request(0x16)
        self.c.retry(seq);self.assertEqual(self.f.writes[-1],raw)
        self.ack(seq);self.result(seq)
        self.assertEqual(self.row(seq)['attempts'],2)

    def test_terminal_without_ack_does_not_invent_ack(self):
        self.ready();seq=self.c.request(0x16);self.result(seq)
        self.assertEqual(self.row(seq)['state'],'COMPLETED');self.assertIsNone(self.row(seq)['ack'])
        self.assertIsNone(self.c.status()['awaiting_ack'])

    def test_result_timeout_retains_unknown_accepted(self):
        self.ready();seq=self.c.request(0x16);self.ack(seq)
        self.clock.advance(16);self.c.poll()
        self.assertEqual(self.row(seq)['state'],'UNKNOWN_ACCEPTED')
        self.assertEqual(len(self.f.writes),2)
        self.c.retry(seq);self.ack(seq);self.result(seq)
        self.assertEqual(self.row(seq)['result'],'PRESENTED')

    def test_completed_replay_does_not_repeat_result(self):
        self.ready();seq=self.c.request(0x16);self.ack(seq);self.result(seq)
        self.c.events();raw=self.f.writes[-1];self.c.retry(seq)
        self.assertEqual(self.f.writes[-1],raw)
        self.result(seq) # retry ACK was lost
        self.assertIsNone(self.c.status()['awaiting_ack'])
        self.assertEqual([e['event'] for e in self.c.events()],['SENT','REPLAY_RESULT'])

    def test_explicit_rejected_retry_can_later_accept(self):
        self.ready();seq=self.c.request(0x16);self.ack(seq,code=5)
        self.assertEqual(self.row(seq)['state'],'REJECTED')
        raw=self.f.writes[-1];self.c.retry(seq);self.assertEqual(self.f.writes[-1],raw)
        self.ack(seq);self.result(seq)
        self.assertEqual(self.row(seq)['result'],'PRESENTED')

    def test_rejected_old_seq_cannot_retry_after_new_acceptance(self):
        self.ready();a=self.c.request(0x16);self.ack(a,code=1)
        b=self.c.request(0x16);self.ack(b)
        with self.assertRaises(ClientError):self.c.retry(a)

    def test_hello_busy_can_be_explicitly_retried(self):
        self.c.connect(self.f,session=S);raw=self.f.writes[-1]
        self.f.response(11,0,0,1);self.c.poll();self.c.retry(0)
        self.assertEqual(self.f.writes[-1],raw)
        self.f.response(11,0,0,0);self.f.response(12,0,0,7);self.c.poll()
        self.assertTrue(self.c.ready)

    def test_four_unresolved_limit(self):
        self.ready()
        for _ in range(4):seq=self.c.request(0x16);self.ack(seq)
        with self.assertRaises(ClientError):self.c.request(1)
        self.result(1,code=6,value=2)
        seq=self.c.request(1);self.ack(seq,1);self.result(seq,1,3,0x050305)
        self.assertEqual(self.row(seq)['result'],'STATUS')

    def test_disconnect_preserves_unknown_and_new_session_does_not_replay(self):
        self.ready();seq=self.c.request(0x16);self.ack(seq);self.c.disconnect()
        self.assertTrue(self.f.closed);self.assertEqual(self.row(seq)['state'],'UNKNOWN')
        with self.assertRaises(ClientError):self.c.retry(seq)
        nf=Fake();self.c.connect(nf,session=T)
        self.assertEqual(len(nf.writes),1);self.assertEqual(decode_command(nf.writes[0]).op,CommandOp.HELLO)
        self.assertTrue(any(t['seq']==seq and t['state']=='UNKNOWN' for t in self.c.archive()))

    def test_detected_reset_and_bad_session(self):
        self.ready();seq=self.c.request(0x16);self.c.notify_reset()
        self.assertFalse(self.c.connected);self.assertEqual(self.row(seq)['state'],'UNKNOWN')
        self.f=Fake();self.c.connect(self.f,session=T)
        self.f.response(11,0,0,6,session=T);self.c.poll()
        self.assertFalse(self.c.connected)

    def test_recent_session_reuse_rejected(self):
        self.ready();self.c.disconnect()
        with self.assertRaises(ClientError):self.c.connect(Fake(),session=S)

    def test_old_session_untracked_wrong_opcode(self):
        self.ready();seq=self.c.request(0x16)
        self.f.response(11,seq,0x16,0,session=T);self.f.response(11,99,0x16,0);self.c.poll()
        self.assertEqual(self.row(seq)['state'],'WAIT_ACK')
        self.f.response(11,seq,0x17,0);self.c.poll()
        self.assertFalse(self.c.ready);self.assertEqual(self.row(seq)['state'],'UNKNOWN')

    def test_conflicting_terminal_marks_fault(self):
        self.ready();seq=self.c.request(0x16);self.result(seq,value=3)
        self.result(seq,value=4);self.assertFalse(self.c.ready)
        self.assertEqual(self.row(seq)['value'],3)

    def test_transport_write_partial_unknown(self):
        self.ready();self.f.partial=True
        with self.assertRaises(ClientError):self.c.request(0x16)
        self.assertFalse(self.c.connected);self.assertEqual(self.row(1)['state'],'UNKNOWN')

    def test_transport_read_error_unknown(self):
        self.ready();seq=self.c.request(0x16);self.f.failread=True
        with self.assertRaises(ClientError):self.c.poll()
        self.assertEqual(self.row(seq)['state'],'UNKNOWN')

    def test_no_sequence_wrap(self):
        self.ready();self.c._next_seq=65535
        seq=self.c.request(0x16);self.ack(seq);self.result(seq)
        with self.assertRaises(ClientError):self.c.request(0x16)

    def test_device_history_eviction_keeps_known_result(self):
        self.ready();seq=self.c.request(0x16);self.ack(seq);self.result(seq)
        self.c.retry(seq);self.ack(seq,code=7)
        self.assertEqual(self.row(seq)['result'],'PRESENTED')
        self.assertTrue(self.c.ready);self.assertIsNone(self.c.status()['awaiting_ack'])

    def test_device_stale_does_not_claim_never_executed(self):
        self.ready();seq=self.c.request(0x16);self.ack(seq)
        self.c.retry(seq);self.ack(seq,code=7)
        self.assertEqual(self.row(seq)['state'],'UNKNOWN_ACCEPTED')
        self.assertIsNone(self.row(seq)['result'])

    def test_bounded_history_and_events(self):
        self.c=ControlClient(clock=self.clock,max_history=8);self.ready()
        for i in range(200):
            seq=self.c.request(0x16);self.ack(seq);self.result(seq,value=i%5+1)
            self.assertLessEqual(len(self.c.transactions()),8)
            self.assertLessEqual(len(self.c.archive()),8)
        self.assertGreater(self.c.status()['event_overflow'],0)
        self.assertEqual(len(self.c.events()),256)

    def test_bytewise_noise_crc_and_legacy(self):
        self.ready();seq=self.c.request(0x16)
        self.f.incoming.extend(b'noiseAX '+b'0100'+b'0'*28+b'\r\n')
        bad=bytearray(encode_response(11,seq,0x16,0,session=S));bad[15]=ord('F') if bad[15]!=ord('F') else ord('E')
        self.f.incoming.extend(bad);self.f.response(11,seq,0x16,0)
        while self.f.incoming:self.c.poll(max_bytes=1)
        self.assertEqual(self.row(seq)['state'],'ACCEPTED')
        self.assertEqual(self.c.status()['legacy_records'],1)

    def test_default_cli_never_constructs_transport(self):
        from serial_control.cli import main
        with patch('serial_control.cli.SerialTransport',side_effect=AssertionError('opened')):
            self.assertEqual(main([]),0)

if __name__=='__main__':unittest.main(verbosity=2)
