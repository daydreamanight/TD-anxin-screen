"""Loopback HTTP tests with injected fake COM list and fake transport."""
import http.client
import json
from pathlib import Path
import sys
import threading
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from serial_control.server import ControlApp,make_server
from protocol_v2 import decode_command,encode_response

class Fake:
    def __init__(self):self.writes=[];self.data=bytearray();self.closed=False
    def write(self,data):self.writes.append(bytes(data));return len(data)
    def read(self,n):out=bytes(self.data[:n]);del self.data[:n];return out
    def close(self):self.closed=True

class Tests(unittest.TestCase):
    def setUp(self):
        self.fake=Fake();self.opens=[]
        def factory(port):self.opens.append(port);return self.fake
        self.app=ControlApp(transport_factory=factory,port_provider=lambda:[{'port':'COM_TEST','description':'fake <board>'}],autopoll=False)
        self.server=make_server(0,self.app);self.port=self.server.server_port
        self.thread=threading.Thread(target=lambda:self.server.serve_forever(poll_interval=.01),daemon=True);self.thread.start()
    def tearDown(self):self.server.shutdown();self.server.server_close();self.app.close();self.thread.join(1)
    def req(self,path='/api/state',method='GET',data=None,headers=None,raw=None):
        h={'Host':f'127.0.0.1:{self.port}'}
        body=None
        if method=='POST':
            h.update({'Content-Type':'application/json','X-Control-Token':self.app.token})
            body=json.dumps(data or {}) if raw is None else raw
        h.update(headers or {})
        c=http.client.HTTPConnection('127.0.0.1',self.port,timeout=2)
        c.request(method,path,body=body,headers=h);r=c.getresponse();b=r.read();out=(r.status,b,dict(r.getheaders()));c.close();return out
    def post(self,path,data,**kw):return self.req(path,'POST',data,**kw)
    def connect(self):
        self.assertEqual(self.post('/api/connect',{'port':'COM_TEST'})[0],200)
        self.session=decode_command(self.fake.writes[0]).session
    def ready(self):
        self.connect()
        self.fake.data.extend(encode_response(11,0,0,0,session=self.session)+encode_response(12,0,0,7,session=self.session))
        self.app.poll()

    def test_start_get_and_assets_never_open(self):
        for path in ('/','/app.js','/style.css','/api/state','/api/ports'):
            status,body,headers=self.req(path);self.assertEqual(status,200)
            self.assertIn("frame-ancestors 'none'",headers['Content-Security-Policy'])
        self.assertEqual(self.opens,[]);self.assertEqual(self.fake.writes,[])
        self.assertFalse(json.loads(self.req()[1])['client']['connected'])

    def test_host_origin_fetch_site_guards(self):
        for h in ({'Host':'evil.test'},{'Origin':'https://evil.test'},{'Sec-Fetch-Site':'cross-site'}):
            self.assertEqual(self.req(headers=h)[0],403)
            self.assertEqual(self.post('/api/connect',{'port':'COM_TEST'},headers=h)[0],403)
        self.assertEqual(self.opens,[])

    def test_csrf_and_content_type(self):
        self.assertEqual(self.post('/api/connect',{'port':'COM_TEST'},headers={'X-Control-Token':''})[0],403)
        self.assertEqual(self.post('/api/connect',{'port':'COM_TEST'},headers={'Content-Type':'text/plain'})[0],415)
        self.assertEqual(self.opens,[])

    def test_request_bounds_and_json_shape(self):
        for raw in ('x'*1025,'[]','null','{','{"port":"COM_TEST","extra":1}'):
            self.assertEqual(self.post('/api/connect',{},raw=raw)[0],400)
        self.assertEqual(self.post('/api/connect',{},headers={'Transfer-Encoding':'chunked'})[0],400)
        self.assertEqual(self.opens,[])

    def test_only_enumerated_port_allowed(self):
        for p in ('COM_OTHER','../COM_TEST',True,1,''):
            self.assertEqual(self.post('/api/connect',{'port':p})[0],400)
        self.assertEqual(self.opens,[])
        self.connect();self.assertEqual(self.opens,['COM_TEST'])
        self.assertEqual(self.post('/api/connect',{'port':'COM_TEST'})[0],400)

    def test_session_gate_and_explicit_navigation(self):
        self.connect()
        self.assertEqual(self.post('/api/command',{'op':'next','arg':0})[0],400)
        self.fake.data.extend(encode_response(11,0,0,0,session=self.session));self.app.poll()
        self.assertEqual(self.post('/api/command',{'op':'next','arg':0})[0],400)
        self.fake.data.extend(encode_response(12,0,0,7,session=self.session));self.app.poll()
        self.assertEqual(self.post('/api/command',{'op':'next','arg':0})[0],200)
        self.assertEqual(len(self.fake.writes),2)
        self.assertEqual(decode_command(self.fake.writes[1]).op,0x16)

    def test_ack_terminal_disconnect_unknown_and_explicit_retry(self):
        self.ready();self.post('/api/command',{'op':'prev','arg':0});original=self.fake.writes[-1]
        self.assertEqual(self.post('/api/retry',{'seq':1})[0],200);self.assertEqual(self.fake.writes[-1],original)
        self.fake.data.extend(encode_response(11,1,0x17,0,session=self.session));self.app.poll()
        row=self.app.snapshot()['transactions'][-1]
        self.assertEqual(row['state'],'ACCEPTED');self.assertIsNone(row['result'])
        self.assertEqual(self.post('/api/disconnect',{})[0],200)
        self.assertEqual(self.app.snapshot()['transactions'][-1]['state'],'UNKNOWN')
        self.assertEqual(self.post('/api/retry',{'seq':1})[0],400)

    def test_query_snapshot_has_no_automatic_writes(self):
        self.ready();self.post('/api/command',{'op':'query','arg':0})
        self.fake.data.extend(encode_response(11,1,1,0,session=self.session)+encode_response(12,1,1,3,session=self.session,value=0x050305));self.app.poll()
        for _ in range(10):self.req();self.app.poll()
        self.assertEqual(len(self.fake.writes),2)
        self.assertEqual(self.app.snapshot()['device'],{'auto':True,'locked':False,'loading':True,'current_page':3,'target_page':5})

    def test_no_other_write_operations(self):
        self.ready()
        for data in ({'op':'write','arg':0},{'op':'goto','arg':True},{'op':'goto','arg':6},{'op':'auto','arg':2},{'op':'next','arg':1},{'op':'next','arg':0,'raw':'00'}):
            self.assertEqual(self.post('/api/command',data)[0],400)
        self.assertEqual(self.post('/api/raw',{'bytes':'0000'})[0],400)
        self.assertEqual(len(self.fake.writes),1)

    def test_raw_send_requires_connection_and_valid_hex(self):
        self.assertEqual(self.post('/api/raw',{'hex':'AA 55'})[0],400)
        self.connect()
        for bad in ('ZZ','','00'*65):self.assertEqual(self.post('/api/raw',{'hex':bad})[0],400)
        self.assertEqual(self.post('/api/raw',{'hex':'AA 55'})[0],200)
        self.assertEqual(self.fake.writes[-1],bytes.fromhex('AA55'))

    def test_wire_log_records_exact_frames_and_only_v2_responses(self):
        self.connect()
        hello=self.fake.writes[0]
        ack=encode_response(11,0,0,0,session=self.session)
        self.fake.data+=b'AX '+b'01'+b'0'*30+bytes((13,10))+ack
        self.app.poll()
        rows=json.loads(self.req()[1])['wire']
        self.assertEqual(rows[0]['raw'],hello.hex(' ').upper())
        self.assertEqual(rows[0]['parsed']['op'],'HELLO')
        self.assertEqual([r['dir'] for r in rows],['TX','RX'])
        self.assertEqual(rows[1]['raw'].encode()+bytes((13,10)),ack)
        self.assertEqual(rows[1]['parsed'],{'kind':'ACK','code':'ACCEPTED','seq':0,'op':0,'value':0})

    def test_live_state_follows_periodic_diagnostics(self):
        self.connect()
        def line(value):return b'AX '+f'{value:032X}'.encode()+bytes((13,10))
        pixel=(1<<120)|(2<<112)|(7<<104)|(3<<24)|(4<<20)|(1<<11)
        scene=(1<<120)|(7<<112)|(7<<104)|(1<<1)
        self.fake.data+=line(pixel)+line(scene)
        self.app.poll()
        state=json.loads(self.req()[1])
        self.assertEqual(state['live'],{'page':4,'auto':True,'loading':False,'edit':True,
                                        'locked':True,'waiting':False,'failed':False})
        self.assertEqual(len(state['wire']),1)  # diagnostics stay out of the record
        self.post('/api/disconnect',{})
        self.assertIsNone(json.loads(self.req()[1])['live'])

    def test_no_arbitrary_static_path(self):
        self.assertEqual(self.req('/../client.py')[0],404)
        self.assertEqual(self.req('/client.py')[0],404)

if __name__=='__main__':unittest.main(verbosity=2)
