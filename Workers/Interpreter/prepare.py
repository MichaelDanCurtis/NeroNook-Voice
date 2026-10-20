"""Explicit, development-only model preparation. No inference or audio capture."""
import hashlib,json,os
from pathlib import Path
from huggingface_hub import snapshot_download
ROOT=Path(__file__).resolve().parents[2]
MODELS={
 'translator':('mlx-community/Hy-MT2-1.8B-4bit','e5c6fe56c7b3bc77fae5ae92db31f2178f1e6912',['*.json','*.safetensors','*.jinja','LICENSE.txt','README.md']),
 'speaker':('mlx-community/Kokoro-82M-bf16','a71e4d38b236d968966a2002c4c895dbd12b1c3c',['config.json','kokoro-v1_0.safetensors','voices/af_heart.safetensors','voices/ef_dora.safetensors','README.md','VOICES.md'])}
if __name__=='__main__':
 os.umask(0o077)
 for role,(repo,revision,files) in MODELS.items():
  target=ROOT/'build/interpreter-models'/role
  print('Preparing',role,flush=True)
  snapshot_download(repo_id=repo,revision=revision,allow_patterns=files,local_dir=target)
  receipt={'repo':repo,'revision':revision,'files':{str(p.relative_to(target)):hashlib.file_digest(p.open('rb'),'sha256').hexdigest() for p in target.rglob('*') if p.is_file() and '.cache' not in p.parts and p.name!='receipt.json'}}
  (target/'receipt.json').write_text(json.dumps(receipt,indent=2))
  print('Verified local receipt',role,flush=True)
