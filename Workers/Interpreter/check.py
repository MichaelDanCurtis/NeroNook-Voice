"""Bounded offline speech -> translation -> speech proof. No audio-device routing."""
import argparse,contextlib,fcntl,hashlib,json,os,signal,subprocess,sys,time,uuid
import xml.etree.ElementTree as ET
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
PYTHON=ROOT/'build/interpreter-venv/bin/python'
WORKER=Path(__file__).with_name('worker.py')
ENV={**os.environ,'HF_HUB_OFFLINE':'1','TRANSFORMERS_OFFLINE':'1','HF_HUB_DISABLE_IMPLICIT_TOKEN':'1'}
for key in list(ENV):
 if any(x in key.upper() for x in ['TOKEN','SECRET','API_KEY']): ENV.pop(key)
ENV['HF_HUB_DISABLE_IMPLICIT_TOKEN']='1'

def execute(argv, log, request=None, timeout=90):
 started=time.monotonic()
 with Path(log).open('wb') as stream:
  process=subprocess.Popen(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',*map(str,argv)],stdin=subprocess.PIPE if request is not None else subprocess.DEVNULL,stdout=stream,stderr=stream,env=ENV,start_new_session=False)
  try:
   process.communicate(json.dumps(request).encode() if request is not None else None,timeout=timeout)
   if process.returncode:raise RuntimeError(f'Stage exited {process.returncode}; see {log}')
  finally:
   if process.poll() is None:
    process.terminate()
    try:process.wait(timeout=1)
    except subprocess.TimeoutExpired:process.kill();process.wait()
 return time.monotonic()-started


@contextlib.contextmanager
def preview_lease():
 lock_path=ROOT/'build/interpreter-session.lock'
 lock_path.parent.mkdir(parents=True,exist_ok=True)
 with lock_path.open('a') as lock:
  try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  except BlockingIOError:raise RuntimeError('Another interpreter preview is already running; stop it first')
  try:yield
  finally:fcntl.flock(lock,fcntl.LOCK_UN)

def validate_source(source,out):
 source=Path(source)
 if not source.is_file() or not 0<source.stat().st_size<=32*1024*1024:
  raise ValueError('Choose an audio file smaller than 32 MB')
 execute(['/usr/bin/afinfo','-x',source],out/'source-info.xml',timeout=10)
 tree=ET.parse(out/'source-info.xml')
 durations=[float(e.text) for e in tree.iter() if e.tag.endswith('}duration')]
 if len(durations)!=1 or not 0<durations[0]<=30:
  raise ValueError('Preview accepts one audio track up to 30 seconds')

def process_audio(source,target,out,model_runner=None,progress=lambda _:None):
 if target not in ['en','es']:raise ValueError('Only English and Spanish in the first prototype')
 out=Path(out);out.mkdir(parents=True,exist_ok=False)
 # Fresh directory guarantees trials never overwrite recordings or previous receipts.
 receipt={'status':'running','target':target,'source':str(source),'stages':{},'models':'Nemotron 3.5 8-bit -> Hy-MT2 1.8B 4-bit -> Kokoro BF16','network':'denied during all stages'}
 try:
  validate_source(source,out)
  progress('Recognizing speech'); converted=out/'input.caf'
  receipt['stages']['convertSeconds']=execute(['/usr/bin/afconvert','-f','caff','-d','LEF32@16000','-c','1',source,converted],out/'convert.log')
  # Existing app worker has a four-hour bound; this preview deliberately caps input to 30 seconds.
  import soundfile as sf
  with sf.SoundFile(converted) as f:
   if not 0<f.frames<=f.samplerate*30:raise ValueError('Preview accepts clips up to 30 seconds')
   receipt['inputSeconds']=f.frames/f.samplerate
  app=Path((ROOT/'build/latest-package.txt').read_text().strip())
  receipt['stages']['asrSeconds']=execute([app/'Contents/Helpers/NeroASR',ROOT/'build/model-fixtures/nemotron-asr',converted,out/'asr.json','mic'],out/'asr.log')
  phrases=json.loads((out/'asr.json').read_text())
  text=' '.join(x['text'] for x in phrases)
  receipt['sourceText']=text
  progress('Translating')
  if model_runner:
   receipt['stages']['translationSeconds']=model_runner('translate',text,target,out)
  else:
   receipt['stages']['translationSeconds']=execute([PYTHON,WORKER,'translate','--model',ROOT/'build/interpreter-models/translator','--receipt',out/'translation.json'],out/'translation.log',{'text':text,'language':target})
  translation=json.loads((out/'translation.json').read_text());receipt['translatedText']=translation['text']
  progress('Generating translated voice')
  if model_runner:
   receipt['stages']['speechSeconds']=model_runner('speak',translation['text'],target,out)
  else:
   receipt['stages']['speechSeconds']=execute([PYTHON,WORKER,'speak','--model',ROOT/'build/interpreter-models/speaker','--receipt',out/'speech.json','--output',out/'translated.wav'],out/'speech.log',{'text':translation['text'],'language':target})
  receipt['status']='complete';receipt['processingSeconds']=sum(receipt['stages'].values())
 except BaseException as e:
  receipt['status']='cancelled' if isinstance(e,KeyboardInterrupt) else 'failed';receipt['error']=str(e);raise
 finally:(out/'result.json').write_text(json.dumps(receipt,indent=2,ensure_ascii=False))
 return receipt

if __name__=='__main__':
 os.umask(0o077)
 p=argparse.ArgumentParser();p.add_argument('audio',type=Path);p.add_argument('--to',choices=['en','es'],required=True);p.add_argument('--output',type=Path);a=p.parse_args()
 with preview_lease():
  result=process_audio(a.audio.resolve(),a.to,a.output or ROOT/'build/interpreter-runs'/str(uuid.uuid4()))
 print(json.dumps(result,indent=2,ensure_ascii=False))
