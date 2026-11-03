"""Bounded explicit transaction client; transport and clock are injected.

No automatic retransmission, no inference of PRESENTED from ACK or page status,
and no attempt to recover a pre-reset NEXT using a fresh sequence number.
"""
from __future__ import annotations
from collections import OrderedDict, deque
from dataclasses import dataclass
from pathlib import Path
import secrets
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'serial_dashboard'))
from protocol_v2 import (AckCode, CommandOp, FrameError, ResponseStream,
                         ResultCode, encode_command)

class ClientError(RuntimeError):
    pass

@dataclass(frozen=True)
class _LegacyObserver:
    reset_count: int
    uptime_seconds: int

class _ControlResponseStream(ResponseStream):
    """Keep observer notices in wire order with v2 responses."""
    def _decode(self, raw):
        response=super()._decode(raw)  # validates the complete 37-byte AX shell
        if response is not None:return response
        payload=int(raw[3:35],16)
        if payload>>112==0x0100 and payload&((1<<50)-1)==0:
            return _LegacyObserver((payload>>64)&0xffff,(payload>>80)&0xffffffff)
        return None

@dataclass
class _Transaction:
    seq: int
    op: CommandOp
    arg: int
    session: int
    frame: bytes
    created: float
    last_sent: float
    state: str = 'WAIT_ACK'
    ack: int | None = None
    result_code: int | None = None
    result_value: int | None = None
    attempts: int = 1
    terminal_since: float | None = None

    def snapshot(self):
        return {'seq': self.seq, 'op': self.op.name, 'arg': self.arg,
                'session': f'{self.session:08X}', 'state': self.state,
                'ack': None if self.ack is None else AckCode(self.ack).name,
                'result': None if self.result_code is None else ResultCode(self.result_code).name,
                'value': self.result_value, 'attempts': self.attempts}

class ControlClient:
    """Single-threaded client with at most four unresolved commands.

    ``transport.write(bytes)`` returns the exact number written; ``read(n)`` must
    be nonblocking. ``close()`` releases the explicit connection. Only connect,
    request, and retry call write; poll/check_timeouts never write.
    """
    def __init__(self, *, clock=time.monotonic, ack_timeout=1.0,
                 result_timeout=15.0, max_pending=4, max_history=64):
        if not 1 <= max_pending <= 4 or max_history < max_pending + 1:
            raise ValueError('pending must be 1..4; history must include HELLO')
        if ack_timeout <= 0 or result_timeout <= 0:
            raise ValueError('positive timeouts required')
        self.clock=clock
        self.ack_timeout=ack_timeout
        self.result_timeout=result_timeout
        self.max_pending=max_pending
        self.max_history=max_history
        self._transport=None
        self._session=0
        self._recent_sessions=deque(maxlen=64)
        self._ready=False
        self._next_seq=1
        self._await_ack=None
        self._last_accepted=0
        self._records=OrderedDict()
        self._archive=deque(maxlen=max_history)
        self._events=deque(maxlen=256)
        self._parser=_ControlResponseStream()
        self._legacy_reset_count=None
        self._legacy_uptime_seconds=None
        self._invalid_seen=0
        self._dropped_events=0

    def _event(self, kind, **fields):
        if len(self._events)==self._events.maxlen:
            self._dropped_events+=1
        self._events.append({'event':kind,**fields})

    @property
    def connected(self): return self._transport is not None
    @property
    def ready(self): return self.connected and self._ready

    def status(self):
        return {'connected':self.connected, 'session_ready':self.ready,
                'session':f'{self._session:08X}' if self._session else None,
                'awaiting_ack':self._await_ack, 'next_seq':self._next_seq,
                'unresolved':self._unresolved(), 'retained':len(self._records),
                'event_overflow':self._dropped_events,
                'legacy_records':self._parser.legacy_records,
                'legacy_reset_count':self._legacy_reset_count,
                'legacy_uptime_seconds':self._legacy_uptime_seconds}

    def transactions(self): return [t.snapshot() for t in self._records.values()]
    def archive(self): return list(self._archive)
    def events(self):
        events=list(self._events);self._events.clear();return events

    def _unresolved(self):
        return sum(t.seq!=0 and t.result_code is None and t.state!='REJECTED'
                   for t in self._records.values())

    def connect(self, transport, *, session=None):
        """Send HELLO on an already explicitly opened, flushed connection."""
        if self.connected:
            raise ClientError('disconnect the current connection first')
        if session is None:
            session=secrets.randbits(32)
            while not session or session in self._recent_sessions:
                session=secrets.randbits(32)
        if isinstance(session,bool) or not isinstance(session,int) or not 0<session<1<<32:
            raise ValueError('session must be a nonzero uint32')
        if session in self._recent_sessions:
            raise ClientError('do not reuse a recently disconnected session')
        for t in self._records.values(): self._archive.append(t.snapshot())
        self._records.clear()
        self._parser=_ControlResponseStream();self._invalid_seen=0
        self._legacy_reset_count=None;self._legacy_uptime_seconds=None
        self._session=session;self._recent_sessions.append(session)
        self._transport=transport;self._ready=False;self._next_seq=1
        self._await_ack=None;self._last_accepted=0
        now=self.clock()
        t=_Transaction(0,CommandOp.HELLO,0,session,encode_command(0,0,session=session),now,now)
        self._records[0]=t;self._await_ack=0
        self._send(t)
        self._event('CONNECTING',session=f'{session:08X}')

    def disconnect(self, reason='USER_DISCONNECT'):
        old=self._transport;self._transport=None;self._ready=False;self._await_ack=None
        self._parser.expire_partial()
        for t in self._records.values():
            if t.result_code is None and t.state!='REJECTED': t.state='UNKNOWN'
        if old is not None:
            try: old.close()
            except Exception as exc: self._event('CLOSE_ERROR',detail=str(exc))
        self._event('DISCONNECTED',reason=reason,unresolved=self._unresolved())

    def notify_reset(self):
        """Called by a verified reset observer; never automatically reconnect."""
        self.disconnect('DEVICE_RESET_NOTICE')

    def _legacy_observer(self,observer):
        previous=self._legacy_reset_count
        self._legacy_reset_count=observer.reset_count
        self._legacy_uptime_seconds=observer.uptime_seconds
        if previous is None:
            self._event('LEGACY_RESET_BASELINE',reset_count=observer.reset_count)
        elif observer.reset_count!=previous:
            self._event('LEGACY_RESET_COUNTER_CHANGED',previous=previous,
                        current=observer.reset_count,uptime_seconds=observer.uptime_seconds)
            self.disconnect('LEGACY_RESET_COUNTER_CHANGED')

    def _send(self,t):
        try:
            written=self._transport.write(t.frame)
            if written!=len(t.frame):
                raise OSError(f'partial write {written}/{len(t.frame)}; outcome unknown')
        except Exception as exc:
            self.disconnect('TRANSPORT_WRITE_ERROR')
            raise ClientError(str(exc)) from exc
        t.last_sent=self.clock()
        self._event('SENT',seq=t.seq,op=t.op.name,attempt=t.attempts)

    def _trim(self):
        while len(self._records)>=self.max_history:
            for seq,t in self._records.items():
                if seq!=0 and (t.result_code is not None or t.state=='REJECTED'):
                    self._archive.append(t.snapshot());del self._records[seq];break
            else: raise ClientError('history contains unresolved transactions')

    def request(self,op,arg=0):
        if not self.ready:
            raise ClientError('wait for SESSION_READY before requesting control')
        if self._await_ack is not None:
            raise ClientError('one request is still awaiting ACK; explicitly retry or disconnect')
        if self._unresolved()>=self.max_pending:
            raise ClientError('four unresolved requests retained; wait for results')
        if self._next_seq>65535:
            raise ClientError('sequence exhausted; finish requests then establish a new session')
        seq=self._next_seq
        frame=encode_command(seq,op,arg,session=self._session)
        self._trim();now=self.clock()
        t=_Transaction(seq,CommandOp(op),arg,self._session,frame,now,now)
        self._records[seq]=t;self._next_seq+=1;self._await_ack=seq
        self._send(t)
        return seq

    def retry(self,seq):
        """Explicitly resend the exact retained frame, never allocate a new SEQ."""
        if not self.connected:
            raise ClientError('cannot retry across disconnect or reset')
        if seq not in self._records:
            raise ClientError('request is outside retained client history')
        t=self._records[seq]
        if t.session!=self._session:
            raise ClientError('cannot replay a prior session')
        if self._await_ack is not None and self._await_ack!=seq:
            raise ClientError('another request is awaiting ACK')
        if seq and not self._ready:
            raise ClientError('session is not established')
        if t.state=='REJECTED':
            if seq and seq<=self._last_accepted:
                raise ClientError('a newer sequence was accepted; old rejected request is now stale')
            if self._unresolved()>=self.max_pending:
                raise ClientError('unresolved request limit reached')
            t.ack=None;t.state='WAIT_ACK';t.terminal_since=None
        elif t.result_code is None:
            t.state='WAIT_ACK' if t.ack is None else 'ACCEPTED'
        t.attempts+=1;self._await_ack=seq
        self._send(t)

    def _protocol_fault(self,reason,t=None):
        self._ready=False
        if t is not None and t.result_code is None:t.state='UNKNOWN'
        self._event('PROTOCOL_FAULT',reason=reason,seq=None if t is None else t.seq)

    def _response(self,r):
        if r.session!=self._session:
            self._event('IGNORED_OLD_SESSION',seq=r.seq,session=f'{r.session:08X}');return
        t=self._records.get(r.seq)
        if t is None:
            self._event('IGNORED_UNTRACKED',seq=r.seq);return
        if int(t.op)!=r.op:
            self._protocol_fault('response opcode conflicts with retained request',t);return
        if r.record_type==11:
            if r.code==AckCode.BAD_SESSION:
                self._event('BAD_SESSION',seq=r.seq)
                self.disconnect('DEVICE_SESSION_LOST')
                return
            if r.code==AckCode.STALE:
                if self._await_ack==r.seq:self._await_ack=None
                if t.result_code is not None:
                    self._event('REPLAY_UNAVAILABLE',seq=r.seq,code='STALE')
                else:
                    t.state='UNKNOWN_ACCEPTED' if t.ack==AckCode.ACCEPTED else 'UNKNOWN'
                    self._event('STALE_OUTCOME_UNKNOWN',seq=r.seq)
                return
            if r.code==AckCode.SEQ_CONFLICT:
                self._protocol_fault('device reports SEQ_CONFLICT; identity cannot be reconciled',t)
                return
            if t.result_code is not None:
                if r.code!=AckCode.ACCEPTED:self._protocol_fault('rejection after known terminal result',t)
                elif self._await_ack==r.seq:self._await_ack=None
                self._event('REPLAY_ACK',seq=r.seq,code=r.code.name);return
            if t.ack is not None and t.ack!=r.code:
                self._protocol_fault('conflicting ACK without explicit rejected retry',t);return
            t.ack=int(r.code)
            if self._await_ack==r.seq:self._await_ack=None
            if r.code==AckCode.ACCEPTED:
                t.state='ACCEPTED'
                self._last_accepted=max(self._last_accepted,r.seq)
                if t.terminal_since is None:t.terminal_since=self.clock()
            else:t.state='REJECTED'
            self._event('ACK',seq=r.seq,code=r.code.name,completed=False)
        else:
            if t.ack is not None and t.ack!=AckCode.ACCEPTED:
                self._protocol_fault('terminal result follows rejected command',t);return
            if t.result_code is not None:
                if (t.result_code,t.result_value)!=(int(r.code),r.value):
                    self._protocol_fault('conflicting terminal replay',t)
                else:
                    if self._await_ack==r.seq:self._await_ack=None
                    self._event('REPLAY_RESULT',seq=r.seq,code=r.code.name)
                return
            t.result_code=int(r.code);t.result_value=r.value;t.state='COMPLETED'
            self._last_accepted=max(self._last_accepted,r.seq)
            if self._await_ack==r.seq:self._await_ack=None
            if r.code==ResultCode.SESSION_READY:self._ready=True
            self._event('RESULT',seq=r.seq,code=r.code.name,value=r.value,
                        accepted_ack_received=t.ack==AckCode.ACCEPTED)

    def poll(self,max_bytes=4096):
        if not 1<=max_bytes<=4096:raise ValueError('poll size must be 1..4096')
        if not self.connected:return
        try:
            data=self._transport.read(max_bytes)
            if not isinstance(data,(bytes,bytearray,memoryview)):
                raise TypeError('transport.read must return bytes')
        except Exception as exc:
            self.disconnect('TRANSPORT_READ_ERROR');raise ClientError(str(exc)) from exc
        if len(data)>max_bytes:
            self.disconnect('TRANSPORT_CONTRACT_ERROR');raise ClientError('transport exceeded bounded read')
        for response in self._parser.feed(data):
            if not self.connected:break
            if isinstance(response,_LegacyObserver):self._legacy_observer(response)
            else:self._response(response)
        if self._parser.invalid_candidates!=self._invalid_seen:
            self._event('INVALID_RESPONSE',count=self._parser.invalid_candidates-self._invalid_seen)
            self._invalid_seen=self._parser.invalid_candidates
        self.check_timeouts()

    def check_timeouts(self):
        if not self.connected:return
        now=self.clock()
        for t in self._records.values():
            if self._await_ack==t.seq and now-t.last_sent>=self.ack_timeout:
                if t.result_code is not None:
                    self._await_ack=None
                    self._event('REPLAY_TIMEOUT',seq=t.seq)
                elif t.state not in ('UNKNOWN','UNKNOWN_ACCEPTED'):
                    t.state='UNKNOWN_ACCEPTED' if t.ack==AckCode.ACCEPTED else 'UNKNOWN'
                    self._event('ACK_TIMEOUT_UNKNOWN',seq=t.seq)
            elif (t.result_code is None and t.ack==AckCode.ACCEPTED
                  and t.terminal_since is not None and now-t.terminal_since>=self.result_timeout
                  and t.state!='UNKNOWN_ACCEPTED'):
                t.state='UNKNOWN_ACCEPTED';self._event('RESULT_TIMEOUT_UNKNOWN',seq=t.seq)
