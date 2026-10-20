"""Four synthetic phrases through one warm runtime, serially and offline."""
import json,subprocess,time,uuid
from check import ROOT,PYTHON,ENV
started=time.monotonic()
with (ROOT/'build/interpreter-session.log').open('w') as log:
 p=subprocess.Popen(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(PYTHON),str(ROOT/'Workers/Interpreter/engine.py')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True,env=ENV)
 try:
  ready=json.loads(p.stdout.readline());print(ready,flush=True)
  results=[]
  for name,target in [('english','es'),('spanish','en'),('english','es'),('spanish','en')]:
   request={'id':str(uuid.uuid4()),'source':str(ROOT/'build/interpreter-fixtures'/f'{name}.aiff'),'target':target}
   p.stdin.write(json.dumps(request)+'\n');p.stdin.flush()
   while True:
    line=p.stdout.readline()
    if not line:raise RuntimeError('Engine exited')
    event=json.loads(line);print(event,flush=True)
    if event['type']=='error':raise RuntimeError(event['error'])
    if event['type']=='result':results.append(event);break
  (ROOT/'build/interpreter-session-results.json').write_text(json.dumps({'ready':ready,'runs':results},indent=2,ensure_ascii=False))
 finally:
  p.stdin.close()
  try:p.wait(timeout=3)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=3)
