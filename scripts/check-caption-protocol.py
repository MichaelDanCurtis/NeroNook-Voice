#!/usr/bin/env python3
"""Check optional caption negotiation on the signed app, without recording."""
import json, os, selectors, subprocess, time, uuid
from pathlib import Path
root=Path(__file__).resolve().parents[1]
app=Path((root/'build/latest-package.txt').read_text().strip())
for enhanced in (False, True):
 features=['dashboard-v1','panels-v1','forms-v1','transient-caption-v1']
 if enhanced:features.append('transient-caption-v2')
 session=str(uuid.uuid4())
 p=subprocess.Popen([str(app/'Contents/MacOS/ModuleApp'),'--neronook-plugin','--protocol-test'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
 selector=selectors.DefaultSelector();selector.register(p.stdout,selectors.EVENT_READ)
 try:
  hello=dict(type='hello',pluginID='cafe.nero.plugin.voice',session=session,sequence=0,apiVersion=1,features=features)
  p.stdin.write((json.dumps(hello)+'\n').encode());p.stdin.flush()
  data=b'';deadline=time.monotonic()+8;ready=None
  while ready is None and time.monotonic()<deadline:
   if not selector.select(.25):continue
   chunk=os.read(p.stdout.fileno(),131072)
   if not chunk:break
   data+=chunk
   while b'\n' in data:
    line,data=data.split(b'\n',1);m=json.loads(line)
    assert m['session'].lower()==session.lower()
    if m['type']=='ready':ready=m;break
  assert ready and ready['sequence']==0,'No valid ready message'
  assert 'transient-caption-v1' in ready['features']
  assert ('transient-caption-v2' in ready['features'])==enhanced,'Incorrect optional caption negotiation'
  p.stdin.close();p.wait(timeout=5);assert p.returncode==0
  print('PASS:', 'v2 fields negotiated' if enhanced else 'v1 compatibility retained')
 finally:
  selector.close()
  if p.poll() is None:p.terminate();p.wait(timeout=5)
