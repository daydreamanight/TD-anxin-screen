"use strict";
const $=id=>document.getElementById(id);
let state=null,token="",working=false,polling=false,error="",reachable=false,hideBefore=0,shownLast=-1;
const ops={HELLO:"建立会话",QUERY_STATUS:"查询状态",GOTO:"指定页面",SET_AUTO:"设置模式",NEXT:"下一页",PREV:"上一页"};
const acks={ACCEPTED:"已接受",BUSY:"忙碌",BAD_ARGUMENT:"参数无效",UNSUPPORTED:"不支持",SEQ_CONFLICT:"序号冲突",LOCKED:"已锁定，拒绝",BAD_SESSION:"会话失效",STALE:"超出历史",UNAVAILABLE:"页面不可用"};
function text(id,value){$(id).textContent=value;}
function statusWords(v){return `当前 PIC ${(v>>8)&255} · ${v&1?"自动":"手动"} · ${v&2?"应急锁定":"未锁定"}${v&4?" · 切换中":""}`;}
function resultWords(p){
 const v=p.value;
 switch(p.code){
  case "PRESENTED":return [`已呈现 PIC ${v}`,"ok"];
  case "APPLIED":return [v?"已应用 自动":"已应用 手动","ok"];
  case "STATUS":return [statusWords(v),"ok"];
  case "SESSION_READY":return ["会话已建立","ok"];
  case "FAILED":return [({1:"失败：加载",2:"失败：预取",3:"失败：输出",4:"失败：页面不可用"})[v]||"失败","bad"];
  case "SUPERSEDED":return [`被 #${v} 取代`,"warn"];
  case "CANCELLED":return [v===2?"被应急取消":"被按键取消","warn"];
  default:return [p.code,""];
 }
}
function parsedWords(p){
 if(!p)return ["非协议帧","warn"];
 if(p.kind==="CMD"){
  const arg=p.op==="GOTO"?` PIC ${p.arg}`:p.op==="SET_AUTO"?(p.arg?"：自动":"：手动"):"";
  return [`#${p.seq} ${ops[p.op]||p.op}${arg}`,""];
 }
 if(p.kind==="ACK")return [`#${p.seq} 回执：${acks[p.code]||p.code}`,p.code==="ACCEPTED"?"":"bad"];
 const [words,cls]=resultWords(p);
 return [`#${p.seq} 结果：${words}`,cls];
}
function renderWire(){
 const rows=state.wire.filter(r=>r.id>hideBefore),last=rows.length?rows[rows.length-1].id:0;
 if(last===shownLast&&rows.length===$("wire").children.length)return;
 shownLast=last;
 const wrap=$("log-wrap"),atEnd=wrap.scrollHeight-wrap.scrollTop-wrap.clientHeight<40,body=$("wire");
 body.replaceChildren();
 for(const r of rows){
  const tr=document.createElement("tr");
  const add=(value,cls)=>{const td=document.createElement("td");td.textContent=value;if(cls)td.className=cls;tr.append(td);};
  const [words,cls]=parsedWords(r.parsed);
  add(r.time,"mono");add(r.dir,r.dir==="TX"?"tx mono":"rx mono");add(r.raw,"mono");add(words,cls);body.append(tr);
 }
 if(atEnd)wrap.scrollTop=wrap.scrollHeight;
}
// QUERY gives the full status; later results of this session update the same fields as they arrive.
function deviceView(){
 const seen=state.wire.filter(r=>r.parsed&&r.parsed.kind==="RESULT"),d=state.device?{...state.device}:null;
 if(!d)return null;
 let start=-1;
 seen.forEach((r,i)=>{if(r.parsed.code==="STATUS")start=i;});
 for(const r of seen.slice(start+1)){
  if(r.parsed.code==="PRESENTED"){d.current_page=r.parsed.value;d.auto=false;d.loading=false;}
  if(r.parsed.code==="APPLIED")d.auto=!!r.parsed.value;
 }
 return d;
}
function render(){
 if(!state)return;
 const s=state.client,ready=s.session_ready,busy=s.awaiting_ack!==null;
 const enabled=reachable&&ready&&!busy&&s.unresolved<4&&!working;
 text("connection-label",ready?"已连接":s.connected?"连接中":"未连接");$("connection-dot").className="dot"+(ready?" ready":"");
 $("connect").disabled=!reachable||s.connected||working||!$("port").value;$("disconnect").disabled=!reachable||!s.connected||working;$("port").disabled=s.connected||working;$("refresh").disabled=working;
 for(const id of ["prev","next","goto","manual","auto","query"])$(id).disabled=!enabled;
 $("free-input").disabled=!s.connected||working||!reachable;$("free-send").disabled=!s.connected||working||!reachable||!$("free-input").value.trim();
 $("retry").hidden=!(s.connected&&busy);$("retry").disabled=working||!reachable;
 const d=deviceView();
 const live=state.live,page=live&&live.page?live.page:d&&d.current_page;
 text("current-page",page?`PIC ${page}`:"—");text("target-page",d&&d.target_page?`PIC ${d.target_page}`:"—");
 const v=live&&live.page?live:d;
 text("mode",v?(v.edit?"维护":v.auto?"自动":"手动"):"—");text("loading",v?(v.loading?"切换中":"就绪"):"—");
 text("locked",v?(v.locked?"已锁定":v.waiting?"等待中":v.failed?"失败":"未锁定"):"—");
 $("locked").className=v&&(v.locked||v.failed)?"alarm":"";
 $("manual").classList.toggle("on",!!v&&!v.auto&&!v.edit);$("auto").classList.toggle("on",!!v&&!!v.auto);
 const problem=error||state.error;$("notice").hidden=!problem;text("notice",problem||"");
 renderWire();
}
async function refresh(){if(polling)return;polling=true;try{const r=await fetch("/api/state",{cache:"no-store"});if(!r.ok)throw Error("状态读取失败");state=await r.json();token=state.csrf_token;reachable=true;render();}catch(e){reachable=false;error=`服务不可达：${e.message}`;text("notice",error);$("notice").hidden=false;for(const id of ["prev","next","goto","manual","auto","query","connect","disconnect","free-send"])$(id).disabled=true;}finally{polling=false;}}
async function ports(){try{const r=await fetch("/api/ports",{cache:"no-store"}),d=await r.json(),selected=$("port").value;$("port").replaceChildren();const blank=document.createElement("option");blank.value="";blank.textContent=d.ports.length?"请选择":"未发现串口";$("port").append(blank);for(const p of d.ports){const o=document.createElement("option");o.value=p.port;o.textContent=p.port;o.title=p.description;$("port").append(o);}if(d.ports.some(p=>p.port===selected))$("port").value=selected;else if(d.ports.length===1)$("port").value=d.ports[0].port;render();}catch(e){error=e.message;render();}}
async function post(path,data){if(working)return;working=true;error="";render();try{const r=await fetch(path,{method:"POST",headers:{"Content-Type":"application/json","X-Control-Token":token},body:JSON.stringify(data)}),d=await r.json();if(!r.ok)throw Error(d.error||"请求未完成");}catch(e){error=e.message;}finally{working=false;await refresh();}}
$("port").addEventListener("change",render);$("refresh").addEventListener("click",ports);$("connect").addEventListener("click",()=>post("/api/connect",{port:$("port").value}));$("disconnect").addEventListener("click",()=>post("/api/disconnect",{}));
for(const [id,op,arg] of [["prev","prev",0],["next","next",0],["manual","auto",0],["auto","auto",1],["query","query",0]])$(id).addEventListener("click",()=>post("/api/command",{op,arg}));
$("goto").addEventListener("click",()=>post("/api/command",{op:"goto",arg:Number($("page").value)}));
function sendFree(){const hex=$("free-input").value.trim();if(hex)post("/api/raw",{hex});}
$("free-input").addEventListener("input",render);$("free-send").addEventListener("click",sendFree);
$("free-input").addEventListener("keydown",e=>{if(e.key==="Enter")sendFree();});
$("retry").addEventListener("click",()=>{if(state&&state.client.awaiting_ack!==null)post("/api/retry",{seq:state.client.awaiting_ack});});
$("clear").addEventListener("click",()=>{if(state&&state.wire.length){hideBefore=state.wire[state.wire.length-1].id;renderWire();}});
refresh().then(ports);setInterval(refresh,500);
