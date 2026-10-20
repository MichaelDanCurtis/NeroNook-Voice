"""Build-only preparation of the plugin's self-contained, signed speaker runtime.
Never installs software into the user's Python; never runs pip in the product.
"""
import hashlib, json, shutil, subprocess, tarfile
from pathlib import Path
from signing import sign
ROOT=Path(__file__).resolve().parents[1]

def package_runtime(destination, identity):
    source=ROOT/'build/speaker-runtime'
    if not (source/'bin/python3.12').exists():
        raise SystemExit('Prepare the private build runtime as documented in Workers/NemotronSpeakers/README.md')
    work=destination.parent/'speaker-runtime-stage'
    shutil.copytree(source,work,symlinks=False)
    # Build tooling, tests and caches are not needed by the installed worker.
    for p in list(work.rglob('__pycache__'))+list(work.rglob('tests'))+list(work.rglob('test')):
        if p.is_dir(): shutil.rmtree(p)
    for name in ['include','share','lib/pkgconfig','lib/python3.12/ensurepip','lib/python3.12/idlelib','lib/python3.12/tkinter']:
        shutil.rmtree(work/name,ignore_errors=True)
    for p in (work/'bin').iterdir():
        if p.name!='python3.12':
            if p.is_dir():shutil.rmtree(p)
            else:p.unlink()
    for p in list(work.rglob('*.a'))+list(work.rglob('*.pyc')):p.unlink()
    version=subprocess.check_output([str(work/'bin/python3.12'),'-I','-c','import mlx.core,numpy; print(mlx.core.__version__,numpy.__version__)'],text=True).strip()
    if version!='0.31.1 2.4.3':raise SystemExit('Unexpected runtime dependencies: '+version)
    # Sign each Mach-O before putting it in the app's signed resource archive.
    for p in sorted(work.rglob('*')):
        if not p.is_file():continue
        with p.open('rb') as f:magic=f.read(4)
        if magic in [b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca']:
            sign(p,identity,'--options','runtime')
    with tarfile.open(destination,'w:gz') as archive:
        for p in sorted(work.rglob('*')):archive.add(p,arcname=str(p.relative_to(work)),recursive=False)
    digest=hashlib.file_digest(destination.open('rb'),'sha256').hexdigest()
    destination.with_suffix('.json').write_text(json.dumps({'sha256':digest,'python':'3.12.11','mlx':'0.31.1','numpy':'2.4.3','upstream':'94c7716212b2228f178d2f9c7619a591fd1b0b78'}))
    shutil.rmtree(work)
