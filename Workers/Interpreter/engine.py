"""Warm interpreter preview engine. Newline JSON over pipes; network denied by launcher.
No model stays loaded between stages. Stop the process to cancel any active job.
"""
import contextlib,gc,json,os,signal,sys,time,uuid
from pathlib import Path
from types import SimpleNamespace
from check import ROOT,process_audio,preview_lease
from worker import run

def emit(**message):print(json.dumps(message,ensure_ascii=False),file=sys.__stdout__,flush=True)
def interrupted(signum,frame):
 raise KeyboardInterrupt('Interpreter stopped')

def model_runner(task,text,language,out):
 start=time.monotonic()
 args=SimpleNamespace(task=task,model=ROOT/'build/interpreter-models'/('translator' if task=='translate' else 'speaker'),receipt=out/('translation.json' if task=='translate' else 'speech.json'),output=out/'translated.wav')
 with (out/(task+'-warm.log')).open('w') as log,contextlib.redirect_stdout(log),contextlib.redirect_stderr(log):
  try:run(args,{'text':text,'language':language})
  finally:
   # Destroy model/pipeline reference cycles before the next model starts.
   gc.collect();mx.clear_cache()
 return time.monotonic()-start

if __name__=='__main__':
 os.umask(0o077)
 os.setpgrp()
 signal.signal(signal.SIGTERM,interrupted)
 signal.signal(signal.SIGALRM,interrupted)
 lease=preview_lease();lease.__enter__()
 started=time.monotonic()
 # Warm imports, not weights. English/Spanish phonemizers are prepared before ready.
 with contextlib.redirect_stdout(sys.stderr):
  import mlx.core as mx,mlx_lm,mlx_audio.tts.utils,spacy,numpy,soundfile
  from mlx_audio.tts.models.kokoro import Model
  from misaki import en,espeak
  en.G2P(fallback=espeak.EspeakFallback(british=False));espeak.EspeakG2P('es')
 emit(type='ready',startupSeconds=time.monotonic()-started)
 while True:
  line=sys.stdin.readline(8193)
  if not line:break
  if len(line)>8192:
   emit(type='error',error='Request too large');break
  request=None
  try:
   if len(line.encode())>8192:raise ValueError('Request too large')
   request=json.loads(line);source=Path(request['source']).resolve()
   if not source.is_file():raise ValueError('Select an existing audio file')
   request_id=str(uuid.UUID(request['id']))
   out=ROOT/'build/interpreter-runs'/request_id
   # A deadline also bounds MLX/G2P code that stops returning control to Python.
   signal.alarm(90)
   with contextlib.redirect_stdout(sys.stderr):
    result=process_audio(source,request['target'],out,model_runner,lambda stage:emit(type='progress',id=request_id,stage=stage))
   emit(type='result',id=request_id,result=result,folder=str(out))
  except Exception as e:emit(type='error',id=request.get('id') if isinstance(request,dict) else None,error=str(e))
  finally:signal.alarm(0)
 lease.__exit__(None,None,None)
