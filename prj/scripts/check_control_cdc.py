"""Checks routed clock-domain crossing paths of the serial control link."""
from pathlib import Path
import csv,hashlib,json,argparse,tempfile,re
from check_cdc_paths import check_report
ROOT=Path(__file__).resolve().parents[1]
SPECS=(('u_control_link/u_request','request',22,40.0),('u_control_link/u_return','return',40,20.0))
CONTROLS=(
 ('control_request_req_first','u_control_link/u_request/req_toggle','u_control_link/u_request/req_meta',40.0,False),
 ('control_request_ack_first','u_control_link/u_request/ack_toggle','u_control_link/u_request/ack_meta',20.0,False),
 ('control_return_req_first','u_control_link/u_return/req_toggle','u_control_link/u_return/req_meta',20.0,False),
 ('control_return_ack_first','u_control_link/u_return/ack_toggle','u_control_link/u_return/ack_meta',40.0,False),
 ('control_request_req_second','u_control_link/u_request/req_meta','u_control_link/u_request/req_sync',40.0,True),
 ('control_request_ack_second','u_control_link/u_request/ack_meta','u_control_link/u_request/ack_sync',20.0,True),
 ('control_return_req_second','u_control_link/u_return/req_meta','u_control_link/u_return/req_sync',20.0,True),
 ('control_return_ack_second','u_control_link/u_return/ack_meta','u_control_link/u_return/ack_sync',40.0,True),
 ('control_uart_rx_second','u_serial_rx/rx_meta','u_serial_rx/rx_sync',20.0,True))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest().upper()
def sdc_lines():
 return ['set_max_delay %.3f -datapath_only -from [get_regs -regexp {^%s$}] -to [get_regs -regexp {^%s$}]'%(b,s,t) for _,s,t,b,_ in CONTROLS[:4]]+['set_false_path -from [get_ports {uart_rx}] -to [get_regs -regexp {^u_serial_rx/rx_meta$}]']
def check_control_report(path,source,target,limit,budget,ordinary_hold,errors):
 if path.is_file():
  content=path.read_text(encoding='utf-8-sig',errors='replace')
  if re.search(r'(?m)^.*\b(?:ERROR|FATAL|CRITICAL-WARNING)\s*:',content):errors.append('Native report diagnostic: '+path.name)
  blocks=re.split(r'(?m)^Slack\s+:\s+',content)[1:]
  expected=('setup','hold') if ordinary_hold else ('setup',)
  types=[]
  if len(blocks)!=len(expected):errors.append('Unexpected native path count: '+path.name)
  for block in blocks:
   if not ordinary_hold:block=re.split(r'(?m)^Set False Path\s*$',block,maxsplit=1)[0]
   kinds=re.findall(r'(?m)^Check Type\s+:\s+(\S+)\s*$',block)
   if len(kinds)!=1:errors.append('Duplicate/missing native check type: '+path.name)
   types+=kinds
   for field in ('Budget','Data Path Delay'):
    if len(re.findall(r'(?m)^'+field+r'\s+:',block))!=1:errors.append('Duplicate/missing native '+field+': '+path.name)
  if sorted(types)!=sorted(expected):errors.append('Unexpected native check types: '+path.name)
 return check_report(path,source,target,limit,budget,ordinary_hold,errors)
def audit(folder,reports,sdc,db,synthetic=False):
 errors=[];rows=[];controls=[]
 expected={(i,str(b)):(short,limit) for i,short,w,limit in SPECS for b in range(w)}
 manifest=folder/'manifest.tsv'
 try:
  entries=list(csv.DictReader(manifest.open(encoding='utf-8-sig'),delimiter='\t'))
  keys=[(x['instance'],x['bit']) for x in entries]
  if len(keys)!=62 or len(set(keys))!=62 or set(keys)!=set(expected):errors.append('Exact 62-bit manifest mismatch')
  for row in entries:
   key=(row['instance'],row['bit'])
   if key not in expected:continue
   short,limit=expected[key];i,b=key;label=f'control_{short}_bit{b}'
   if row.get('source_count')!='1' or row.get('target_count')!='1' or row.get('label')!=label:errors.append('Missing/aliased endpoint '+label)
   rows.append(check_control_report(reports/(label+'.rpt'),f'{i}/payload[{b}]',f'{i}/dst_data[{b}]',limit,20.0,True,errors))
 except (OSError,KeyError,ValueError) as e:errors.append(str(e))
 for label,s,t,b,h in CONTROLS:controls.append(check_control_report(reports/(label+'.rpt'),s,t,b,b,h,errors))
 if sdc.is_file():
  actual=[x.strip() for x in sdc.read_text(encoding='utf-8-sig').splitlines() if x.strip() and not x.lstrip().startswith('#') and ('u_control_link' in x or 'u_serial_rx' in x or 'uart_rx' in x)]
  if sorted(actual)!=sorted(sdc_lines()):errors.append('Control SDC must contain only exact first-stage exceptions')
 else:errors.append('Missing SDC')
 if not db.is_file():errors.append('Missing routed database')
 return {'status':'PASS' if not errors else 'FAIL','physical_gate_pass':not errors and not synthetic,'synthetic':synthetic,'logical_bits':62,'controls':9,'pruned_bits':0,'route_db_sha256':sha(db) if db.is_file() else None,'sdc_sha256':sha(sdc) if sdc.is_file() else None,'manifest_sha256':sha(manifest) if manifest.is_file() else None,'rows':rows,'control_rows':controls,'errors':errors}
def self_test():
 outcomes=[]
 def fixture(d):
  reports=d/'reports';reports.mkdir();folder=d/'audit';folder.mkdir()
  def report(s,t,b,h=True):
   def block(kind,budget):return f'Slack               : 1.000ns\nCheck Type          : {kind}\nBudget              : {budget:.3f}ns\nData Path Delay     : 1.000ns\nnet: {s}, fixture\nnet: {t}, fixture\n'
   return block('setup',b)+(block('hold',0) if h else '')
  entries=[]
  for i,short,w,limit in SPECS:
   for bit in range(w):
    label=f'control_{short}_bit{bit}';entries.append(f'{i}\t{bit}\t1\t1\t{label}\n')
    (reports/(label+'.rpt')).write_text(report(f'{i}/payload[{bit}]',f'{i}/dst_data[{bit}]',20))
  (folder/'manifest.tsv').write_text('instance\tbit\tsource_count\ttarget_count\tlabel\n'+''.join(entries))
  for label,s,t,b,h in CONTROLS:(reports/(label+'.rpt')).write_text(report(s,t,b,h))
  (d/'design.sdc').write_text('\n'.join(sdc_lines())+'\n');(d/'route.db').write_bytes(b'SYNTHETIC NOT ROUTED')
  return folder,reports
 cases=['valid','missing_bit','duplicate_bit','one_sided','pruned','wrong_net','negative_setup','negative_hold','payload_relaxed','payload_hold_missing','second_stage_relaxed','missing_control','broad_cut','missing_db','duplicate_budget','native_report_error','extra_check_type']
 for case in cases:
  with tempfile.TemporaryDirectory() as temp:
   d=Path(temp);folder,reports=fixture(d);m=folder/'manifest.tsv';p=reports/'control_request_bit0.rpt'
   if case=='missing_bit':m.write_text('\n'.join(m.read_text().splitlines()[:-1])+'\n')
   if case=='duplicate_bit':m.write_text(m.read_text()+m.read_text().splitlines()[1]+'\n')
   if case=='one_sided':m.write_text(m.read_text().replace('\t1\t1\tcontrol_request_bit0','\t0\t1\tcontrol_request_bit0'))
   if case=='pruned':m.write_text(m.read_text().replace('\t1\t1\tcontrol_request_bit0','\t0\t0\tcontrol_request_bit0'))
   if case=='wrong_net':p.write_text(p.read_text().replace('/payload[0]','/payload[1]'))
   if case=='negative_setup':p.write_text(p.read_text().replace('Slack               : 1.000ns','Slack               : -0.001ns',1))
   if case=='negative_hold':p.write_text(p.read_text().replace('Slack               : 1.000ns\nCheck Type          : hold','Slack               : -0.001ns\nCheck Type          : hold'))
   if case=='payload_relaxed':p.write_text(p.read_text().replace('Budget              : 20.000ns','Budget              : 40.000ns'))
   if case=='payload_hold_missing':p.write_text(p.read_text().replace('Check Type          : hold','Check Type          : hidden'))
   if case=='second_stage_relaxed':
    q=reports/'control_request_ack_second.rpt';q.write_text(q.read_text().replace('Budget              : 20.000ns','Budget              : 40.000ns'))
   if case=='missing_control':(reports/'control_uart_rx_second.rpt').unlink()
   if case=='broad_cut':
    q=d/'design.sdc';q.write_text(q.read_text()+'set_false_path -to [get_regs {u_control_link/*}]\n')
   if case=='missing_db':(d/'route.db').unlink()
   if case=='duplicate_budget':p.write_text(p.read_text().replace('Budget              : 20.000ns','Budget              : 20.000ns\nBudget              : 100.000ns'))
   if case=='native_report_error':p.write_text(p.read_text()+'USR-8011 ERROR: report path failed\n')
   if case=='extra_check_type':p.write_text(p.read_text().replace('Check Type          : setup','Check Type          : setup\nCheck Type          : recovery'))
   r=audit(folder,reports,d/'design.sdc',d/'route.db',True)
   ok=(r['status']=='PASS')==(case=='valid') and not r['physical_gate_pass']
   outcomes.append({'case':case,'pass':ok,'errors':r['errors']});assert ok,outcomes[-1]
 return outcomes
if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--self-test',action='store_true');parser.add_argument('--output',type=Path);a=parser.parse_args()
 if a.self_test:r={'status':'PASS','synthetic':True,'tests':self_test()}
 else:r=audit(ROOT/'build/control_cdc_audit',ROOT/'build/cdc_route_audit',ROOT/'../source_code/adc_sdc/anxin_screen.sdc',ROOT/'build/td/route.db')
 output=a.output or (ROOT/'build/control_cdc_audit/acceptance.json' if not a.self_test else None)
 if output:output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(r,indent=2)+'\n')
 print(json.dumps({k:v for k,v in r.items() if k not in ['rows','control_rows','tests']},indent=2))
 if r['status']!='PASS':raise SystemExit(1)
