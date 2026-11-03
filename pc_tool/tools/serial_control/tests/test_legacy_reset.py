"""Synthetic byte streams only; no COM opens or automatic reconnect/retry."""
from pathlib import Path
import sys,unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from serial_control import ControlClient,ClientError
from protocol_v2 import encode_response
from test_client import Clock,Fake,S,T

def observer(count,uptime=1,*,kind=0,reserved=0):
    value=(1<<120)|(kind<<112)|(uptime<<80)|(count<<64)|(0xf<<52)|reserved
    return b'AX '+f'{value:032X}'.encode()+b'\r\n'

class LegacyResetTests(unittest.TestCase):
    def setUp(self):self.clock=Clock();self.f=Fake();self.c=ControlClient(clock=self.clock)
    def ready(self):
        self.c.connect(self.f,session=S)
        self.f.response(11,0,0,0);self.f.response(12,0,0,7);self.c.poll()
    def feed(self,data):self.f.incoming.extend(data);self.c.poll()
    def row(self,seq):return next(t for t in self.c.transactions() if t['seq']==seq)
    def baseline(self,count=0):self.feed(observer(count))

    def test_first_nonzero_is_only_baseline(self):
        self.ready();self.baseline(42)
        self.assertTrue(self.c.ready);self.assertEqual(self.c.status()['legacy_reset_count'],42)
    def test_repeated_count_does_not_disconnect_or_write(self):
        self.ready();self.baseline(2);writes=list(self.f.writes)
        for uptime in [2,2,3,0xffffffff,0]:self.feed(observer(2,uptime))
        self.assertTrue(self.c.ready);self.assertEqual(self.f.writes,writes)
    def test_changed_count_wait_ack_unknown_no_retransmit(self):
        self.ready();self.baseline();seq=self.c.request(0x16);writes=list(self.f.writes)
        self.feed(observer(1));self.assertFalse(self.c.connected);self.assertTrue(self.f.closed)
        self.assertEqual(self.row(seq)['state'],'UNKNOWN');self.assertEqual(self.f.writes,writes)
        with self.assertRaises(ClientError):self.c.retry(seq)
    def test_changed_count_accepted_unknown(self):
        self.ready();self.baseline();seq=self.c.request(0x16)
        self.f.response(11,seq,0x16,0);self.c.poll();self.feed(observer(1))
        self.assertEqual(self.row(seq)['state'],'UNKNOWN');self.assertIsNone(self.row(seq)['result'])
    def test_result_before_notice_in_same_poll_remains_known(self):
        self.ready();self.baseline();seq=self.c.request(0x16)
        self.feed(encode_response(12,seq,0x16,1,session=S,value=3)+observer(1))
        self.assertFalse(self.c.connected);self.assertEqual(self.row(seq)['result'],'PRESENTED')
    def test_notice_before_result_in_same_poll_keeps_unknown(self):
        self.ready();self.baseline();seq=self.c.request(0x16)
        self.feed(observer(1)+encode_response(12,seq,0x16,1,session=S,value=3))
        self.assertFalse(self.c.connected);self.assertIsNone(self.row(seq)['result'])
    def test_counter_wrap_detected_bytewise(self):
        self.ready();self.baseline(0xffff);seq=self.c.request(0x17)
        self.f.incoming.extend(observer(0))
        while self.f.incoming and self.c.connected:self.c.poll(max_bytes=1)
        self.assertFalse(self.c.connected);self.assertEqual(self.row(seq)['state'],'UNKNOWN')
    def test_count_decrease_also_invalidates(self):
        self.ready();self.baseline(12);self.feed(observer(0))
        self.assertFalse(self.c.connected)
    def test_new_connection_starts_fresh_baseline(self):
        self.ready();self.baseline(12);self.c.disconnect()
        self.f=Fake();self.c.connect(self.f,session=T)
        self.f.response(11,0,0,0,session=T);self.f.response(12,0,0,7,session=T)
        self.feed(observer(0));self.assertTrue(self.c.ready)
        self.assertEqual(self.c.status()['legacy_reset_count'],0)
    def test_other_legacy_types_do_not_update_reset_count(self):
        self.ready();self.baseline()
        for kind in range(1,11):self.feed(observer(55,kind=kind))
        self.assertTrue(self.c.ready);self.assertEqual(self.c.status()['legacy_reset_count'],0)
    def test_invalid_shell_and_reserved_bits_do_not_invalidate(self):
        self.ready();self.baseline()
        self.feed(observer(1,reserved=1)+observer(1).lower()+observer(1)[:-1])
        self.assertTrue(self.c.ready);self.assertEqual(self.c.status()['legacy_reset_count'],0)
    def test_same_counter_reconfiguration_is_not_inferred(self):
        self.ready();self.baseline();self.feed(observer(0,0))
        self.assertTrue(self.c.ready)
    def test_notice_during_hello_does_not_enable_control(self):
        self.c.connect(self.f,session=S);self.baseline()
        self.feed(observer(1)+encode_response(12,0,0,7,session=S,value=0))
        self.assertFalse(self.c.connected);self.assertFalse(self.c.ready)
    def test_completed_transaction_preserved_on_later_notice(self):
        self.ready();self.baseline();seq=self.c.request(0x16)
        self.f.response(12,seq,0x16,1,value=3);self.c.poll();self.feed(observer(1))
        self.assertEqual(self.row(seq)['state'],'COMPLETED');self.assertEqual(self.row(seq)['value'],3)

if __name__=='__main__':unittest.main(verbosity=2)
