"""Explicit interactive serial CLI. Default invocation never opens a port."""
from __future__ import annotations
import argparse
import json
import sys
from .client import ControlClient, ClientError, CommandOp

class SerialTransport:
    def __init__(self,port):
        import serial
        self.port=serial.Serial(port=None,baudrate=115200,timeout=0,write_timeout=1)
        self.port.dtr=False;self.port.rts=False;self.port.port=port
        try:
            self.port.open()
            self.port.reset_input_buffer()
            self.port.reset_output_buffer()
        except Exception:
            self.port.close()
            raise
    def write(self,data):return self.port.write(data)
    def read(self,size):return self.port.read(size)
    def close(self):self.port.close()

def show(client):
    for event in client.events():print(json.dumps(event,ensure_ascii=False))

def main(argv=None):
    p=argparse.ArgumentParser(description='安芯讯屏串口控制；默认不连接。需要新的v2控制镜像。')
    p.add_argument('--port',help='显式指定串口，例如 COM7')
    p.add_argument('--connect',action='store_true',help='明确打开指定串口并发送HELLO')
    args=p.parse_args(argv)
    if not args.connect:
        print('未连接。使用 --port COMx --connect 后进入交互控制。')
        return 0
    if not args.port:p.error('--connect 必须同时显式指定 --port')
    c=ControlClient()
    try:c.connect(SerialTransport(args.port))
    except Exception as exc:print(f'连接失败：{exc}',file=sys.stderr);return 1
    print('命令：poll / next / prev / goto 1..5 / auto 0|1 / query / retry SEQ / status / exit')
    print('先poll直到SESSION_READY。ACK ACCEPTED仅表示接受；RESULT PRESENTED才表示FPGA完整帧输出见证。')
    try:
        while c.connected:
            show(c)
            try:parts=input('control> ').strip().split()
            except EOFError:break
            if not parts:continue
            try:
                cmd=parts[0].lower()
                if cmd in ('exit','quit'):break
                if cmd=='poll':c.poll()
                elif cmd=='status':
                    c.poll();print(json.dumps({'status':c.status(),'requests':c.transactions()},ensure_ascii=False,indent=2))
                elif cmd=='retry' and len(parts)==2:c.retry(int(parts[1],0))
                elif cmd in ('next','prev','query') and len(parts)==1:
                    c.poll();c.request({'next':CommandOp.NEXT,'prev':CommandOp.PREV,'query':CommandOp.QUERY_STATUS}[cmd])
                elif cmd in ('goto','auto') and len(parts)==2:
                    c.poll();c.request(CommandOp.GOTO if cmd=='goto' else CommandOp.SET_AUTO,int(parts[1],0))
                else:print('命令或参数不匹配。')
            except (ClientError,ValueError,TypeError) as exc:print(f'操作未完成：{exc}')
    except KeyboardInterrupt:pass
    finally:c.disconnect();show(c)
    return 0

if __name__=='__main__':raise SystemExit(main())
