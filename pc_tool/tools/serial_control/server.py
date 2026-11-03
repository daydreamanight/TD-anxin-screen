"""Opt-in loopback control UI. Startup and GET requests never open a COM port."""
from __future__ import annotations
import argparse
from collections import deque
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import ipaddress
import json
from pathlib import Path
import secrets
import threading
import time
from .client import ControlClient,ClientError,CommandOp
from .cli import SerialTransport
from protocol_v2 import FrameError,decode_command,decode_response
from decoder import decode_payload

ROOT=Path(__file__).resolve().parent

class WireTap:
    """Record the exact command frames written and v2 response lines read; the client is unaffected."""
    def __init__(self,inner,log):self.inner=inner;self.log=log;self.pending=bytearray()
    def write(self,data):
        written=self.inner.write(data);self.log.command(bytes(data));return written
    def read(self,size):
        data=self.inner.read(size)
        if data:
            self.pending+=data
            while (end:=self.pending.find(b'\n'))>=0:
                line=bytes(self.pending[:end+1]);del self.pending[:end+1]
                if line.startswith(b'AX 02'):self.log.response(line)
                elif line.startswith(b'AX 01'):self.log.diagnostic(line)
            if len(self.pending)>4096:del self.pending[:-64]
        return data
    def close(self):self.inner.close()

class WireLog:
    def __init__(self):
        self.rows=deque(maxlen=400);self.next_id=1;self.lock=threading.Lock();self.live=None
    def diagnostic(self,line):
        try:r=decode_payload(line[3:35].decode('ascii'))
        except ValueError:return
        with self.lock:
            if r.get('kind')=='pixel':
                self.live={**(self.live or {}),'page':r['page']+1,'auto':r['auto_mode'],
                           'loading':r['state']!=7,'edit':r['edit_mode']}
            elif r.get('kind')=='scene_control':
                self.live={**(self.live or {}),'locked':r['emergency_active'],
                           'waiting':r['emergency_pending'],'failed':r['emergency_unavailable']}
    def reset_live(self):
        with self.lock:self.live=None
    def _add(self,direction,raw,parsed):
        with self.lock:
            self.rows.append({'id':self.next_id,'time':time.strftime('%H:%M:%S'),'dir':direction,'raw':raw,'parsed':parsed})
            self.next_id+=1
    def command(self,frame):
        try:
            c=decode_command(frame);parsed={'kind':'CMD','op':c.op.name,'seq':c.seq,'arg':c.arg}
        except FrameError:parsed=None
        self._add('TX',frame.hex(' ').upper(),parsed)
    def response(self,line):
        try:
            r=decode_response(line)
            parsed={'kind':'ACK' if r.record_type==11 else 'RESULT','code':r.code.name,'seq':r.seq,'op':r.op,'value':r.value}
        except FrameError:parsed=None
        self._add('RX',line.rstrip(b'\r\n').decode('ascii','replace'),parsed)
    def snapshot(self):
        with self.lock:return list(self.rows)

def enumerate_ports():
    try:
        from serial.tools import list_ports
    except ImportError:return []
    return [{'port':p.device,'description':p.description} for p in list_ports.comports()]

class ControlApp:
    def __init__(self,*,transport_factory=SerialTransport,port_provider=enumerate_ports,
                 client=None,autopoll=True):
        self.client=client or ControlClient()
        self.factory=transport_factory;self.port_provider=port_provider
        self.lock=threading.RLock();self.token=secrets.token_urlsafe(32)
        self.stop=threading.Event();self.worker=None
        self.events=deque(maxlen=160);self.event_id=0;self.port=None;self.error=''
        self.device=None;self.device_time=None;self.wire=WireLog();self.tap=None
        if autopoll:
            self.worker=threading.Thread(target=self._worker,daemon=True,name='anxin-control-poll')
            self.worker.start()

    def _collect(self):
        for event in self.client.events():
            self.event_id+=1
            self.events.append({'id':self.event_id,'time':time.strftime('%H:%M:%S'),**event})
            if event['event']=='RESULT' and event['code']=='STATUS':
                v=event['value'];self.device={'auto':bool(v&1),'locked':bool(v&2),'loading':bool(v&4),
                    'current_page':(v>>8)&255,'target_page':(v>>16)&255}
                self.device_time=time.monotonic()

    def poll(self):
        with self.lock:
            try:self.client.poll()
            except ClientError as exc:self.error=str(exc)
            self._collect()

    def _worker(self):
        while not self.stop.wait(.05):self.poll()

    def ports(self):
        with self.lock:
            ports=self.port_provider()
            return {'ports':[{'port':p['port'],'description':p.get('description','')}
                             for p in ports if isinstance(p.get('port'),str)]}

    def connect(self,port):
        with self.lock:
            if self.client.connected:raise ClientError('请先断开当前连接')
            if not isinstance(port,str) or len(port)>64 or port not in {p['port'] for p in self.ports()['ports']}:
                raise ValueError('只能连接刚枚举出的明确串口')
            self.error='';self.device=None;self.device_time=None;self.wire.reset_live()
            transport=WireTap(self.factory(port),self.wire)
            try:self.client.connect(transport)
            except Exception:
                try:transport.close()
                except Exception:pass
                raise
            self.port=port;self.tap=transport;self._collect()

    def disconnect(self):
        with self.lock:self.client.disconnect();self.wire.reset_live();self._collect()

    def command(self,name,arg):
        mapping={'query':CommandOp.QUERY_STATUS,'goto':CommandOp.GOTO,
                 'auto':CommandOp.SET_AUTO,'next':CommandOp.NEXT,'prev':CommandOp.PREV}
        if name not in mapping or type(arg) is not int:raise ValueError('命令或参数无效')
        with self.lock:
            seq=self.client.request(mapping[name],arg);self._collect();return seq

    def send_raw(self,text):
        if not isinstance(text,str):raise ValueError('数据必须为HEX文本')
        data=bytes.fromhex(text)
        if not 1<=len(data)<=64:raise ValueError('一次发送1..64字节')
        with self.lock:
            if not self.client.connected:raise ClientError('请先连接串口')
            self.tap.write(data)

    def retry(self,seq):
        if type(seq) is not int or not 0<=seq<=65535:raise ValueError('SEQ必须为0..65535整数')
        with self.lock:self.client.retry(seq);self._collect()

    def snapshot(self):
        with self.lock:
            self._collect()
            return {'client':self.client.status(),'port':self.port,'error':self.error,
                    'transactions':self.client.transactions(),'archive':self.client.archive(),
                    'events':list(self.events),'wire':self.wire.snapshot(),'live':self.wire.live if self.client.connected else None,'device':self.device,
                    'device_age_s':None if self.device_time is None else round(time.monotonic()-self.device_time,1),
                    'csrf_token':self.token}

    def close(self):
        self.stop.set()
        if self.worker:self.worker.join(timeout=1)
        self.disconnect()

class Handler(BaseHTTPRequestHandler):
    def setup(self):super().setup();self.connection.settimeout(3)
    def log_message(self,*_):pass
    def local(self):
        allowed={f'127.0.0.1:{self.server.server_port}',f'localhost:{self.server.server_port}'}
        return (ipaddress.ip_address(self.client_address[0]).is_loopback
                and len(self.headers.get_all('Host',[]))==1
                and len(self.headers.get_all('Origin',[]))<=1
                and self.headers.get('Host') in allowed
                and (not self.headers.get('Origin') or self.headers['Origin'] in {'http://'+s for s in allowed})
                and self.headers.get('Sec-Fetch-Site')!='cross-site')
    def send(self,value,status=200,mime='application/json; charset=utf-8'):
        if status>=400 and self.command=='POST' and not getattr(self,'body_read',False):
            lengths=self.headers.get_all('Content-Length',[])
            try:
                n=int(lengths[0]) if len(lengths)==1 else -1
                if 0<=n<=4096:self.rfile.read(n)
            except (ValueError,OSError):pass
            self.body_read=True
        body=value if isinstance(value,bytes) else json.dumps(value,ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        for name,val in [('Content-Type',mime),('Content-Length',str(len(body))),('Cache-Control','no-store'),
                         ('X-Content-Type-Options','nosniff'),('Referrer-Policy','no-referrer'),
                         ('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; frame-ancestors 'none'; connect-src 'self'; base-uri 'none'; form-action 'self'")]:
            self.send_header(name,val)
        self.end_headers();self.wfile.write(body)
    def do_GET(self):
        if not self.local():return self.send({'error':'仅接受本机同源请求'},403)
        app=self.server.app
        if self.path=='/api/state':return self.send(app.snapshot())
        if self.path=='/api/ports':return self.send(app.ports())
        files={'/':('index.html','text/html; charset=utf-8'),
               '/app.js':('app.js','text/javascript; charset=utf-8'),
               '/style.css':('style.css','text/css; charset=utf-8')}
        if self.path in files:
            name,mime=files[self.path];return self.send((ROOT/'static'/name).read_bytes(),mime=mime)
        return self.send({'error':'未知资源'},404)
    def do_POST(self):
        app=self.server.app
        if (not self.local() or len(self.headers.get_all('X-Control-Token',[]))!=1
            or not secrets.compare_digest(self.headers.get('X-Control-Token','').encode('utf-8'),app.token.encode('utf-8'))):
            return self.send({'error':'请求校验失败'},403)
        if self.headers.get('Transfer-Encoding'):return self.send({'error':'不接受分块请求'},400)
        if self.headers.get('Content-Type')!='application/json':return self.send({'error':'仅接受JSON'},415)
        try:
            lengths=self.headers.get_all('Content-Length',[])
            if len(lengths)!=1:raise ValueError('必须提供唯一请求长度')
            n=int(lengths[0])
            if not 0<n<=1024:raise ValueError('请求大小必须为1..1024字节')
            raw=self.rfile.read(n)
            self.body_read=True
            if len(raw)!=n:raise ValueError('请求未完整接收')
            data=json.loads(raw)
            if not isinstance(data,dict):raise ValueError('请求必须为对象')
            seq=None
            if self.path=='/api/connect' and set(data)=={'port'}:app.connect(data['port'])
            elif self.path=='/api/disconnect' and not data:app.disconnect()
            elif self.path=='/api/command' and set(data)=={'op','arg'}:seq=app.command(data['op'],data['arg'])
            elif self.path=='/api/retry' and set(data)=={'seq'}:app.retry(data['seq'])
            elif self.path=='/api/raw' and set(data)=={'hex'}:app.send_raw(data['hex'])
            else:raise ValueError('未知操作或参数')
            return self.send({'ok':True,'seq':seq})
        except (ValueError,TypeError,ClientError,OSError) as exc:
            return self.send({'error':str(exc)},400)

def make_server(port=8770,app=None):
    server=ThreadingHTTPServer(('127.0.0.1',port),Handler)
    server.daemon_threads=True;server.app=app or ControlApp()
    return server

def main(argv=None):
    p=argparse.ArgumentParser(description='安芯讯屏独立串口控制台；启动不连接硬件')
    p.add_argument('--port',type=int,default=8770)
    p.add_argument('--open-browser',action='store_true')
    args=p.parse_args(argv);server=make_server(args.port)
    url=f'http://127.0.0.1:{server.server_port}/'
    print(f'控制台：{url}；尚未连接任何串口。',flush=True)
    if args.open_browser:
        import webbrowser
        webbrowser.open(url)
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:server.shutdown();server.server_close();server.app.close()

if __name__=='__main__':main()
