"""One local MLX model per process. File/text input only; no microphone or network."""
import argparse,hashlib,json,os,sys,time
from pathlib import Path
os.environ.update(HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',HF_HUB_DISABLE_IMPLICIT_TOKEN='1',TOKENIZERS_PARALLELISM='false')
LANGUAGES={'en':'English','es':'Spanish'}
def verified_model(path):
 path=Path(path).resolve(); receipt=json.loads((path/'receipt.json').read_text())
 for name,digest in receipt['files'].items():
  f=(path/name).resolve()
  if not f.is_relative_to(path) or hashlib.file_digest(f.open('rb'),'sha256').hexdigest()!=digest:
   raise ValueError('Model verification failed: '+name)
 return path

def run(args, request=None):
 started=time.monotonic(); model_path=verified_model(args.model)
 request=request if request is not None else json.loads(sys.stdin.buffer.read(8193))
 text=request['text'].strip(); language=request['language']
 if not text or len(text.encode())>2048 or language not in LANGUAGES: raise ValueError('Unsupported language or phrase length')
 import mlx.core as mx
 mx.set_cache_limit(128*1024*1024)
 if args.task=='translate':
  from mlx_lm import load,stream_generate
  from mlx_lm.sample_utils import make_sampler
  model,tokenizer=load(model_path,tokenizer_config={'trust_remote_code':False})
  prompt='Translate the following text into '+LANGUAGES[language]+'. Note that you should only output the translated result without any additional explanation:\n\n'+text
  prompt=tokenizer.apply_chat_template([{'role':'user','content':prompt}],tokenize=False,add_generation_prompt=True)
  ready=time.monotonic(); output=''; first=None; finish=None
  for r in stream_generate(model,tokenizer,prompt=prompt,max_tokens=384,sampler=make_sampler(temp=0)):
   if first is None: first=time.monotonic()
   output+=r.text; finish=r.finish_reason
  if finish=='length' or not output.strip() or len(output.encode())>3072: raise ValueError('Incomplete or oversized translation')
  result={'text':output.strip(),'loadSeconds':ready-started,'firstTokenSeconds':first-ready if first else None,'generationSeconds':time.monotonic()-ready,'finishReason':finish}
 else:
  from mlx_audio.tts.utils import load_model
  import numpy as np,soundfile as sf,spacy
  if language=='en' and not spacy.util.is_package('en_core_web_sm'): raise ValueError('Prepare English phonemizer first')
  model=load_model(model_path,strict=True,model_type="kokoro")
  ready=time.monotonic(); audio=[]; first=None; rate=None
  voice=model_path/'voices'/('af_heart.safetensors' if language=='en' else 'ef_dora.safetensors')
  for chunk in model.generate(text,voice=str(voice),lang_code='a' if language=='en' else 'e'):
   data=np.array(chunk.audio,dtype=np.float32).reshape(-1)
   if first is None:first=time.monotonic()
   if not np.isfinite(data).all():raise ValueError('Invalid synthesized audio')
   audio.append(data);rate=chunk.sample_rate
   if sum(len(x) for x in audio)>rate*60:raise ValueError('Speech exceeds one-minute limit')
  if not audio:raise ValueError('No speech generated')
  output=Path(args.output);output.parent.mkdir(parents=True,exist_ok=True)
  sf.write(output,np.concatenate(audio),rate,subtype='PCM_16')
  result={'audio':str(output.resolve()),'audioSeconds':sum(len(x) for x in audio)/rate,'loadSeconds':ready-started,'firstAudioSeconds':first-ready,'generationSeconds':time.monotonic()-ready}
 result.update(totalSeconds=time.monotonic()-started,peakMetalBytes=mx.get_peak_memory())
 Path(args.receipt).write_text(json.dumps(result,indent=2,ensure_ascii=False))
if __name__=='__main__':
 os.umask(0o077)
 p=argparse.ArgumentParser();p.add_argument('task',choices=['translate','speak']);p.add_argument('--model',required=True);p.add_argument('--receipt',required=True);p.add_argument('--output');a=p.parse_args()
 try:run(a)
 except Exception as e: print(type(e).__name__+': '+str(e),file=sys.stderr);sys.exit(1)
