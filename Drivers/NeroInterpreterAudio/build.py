from pathlib import Path
import json,plistlib,subprocess,sys,shutil
ROOT=Path(__file__).resolve().parents[2];SRC=Path(__file__).parent;OUT=ROOT/'build/interpreter-audio';OUT.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,str(ROOT/'scripts'));from signing import resolve,sign,details
vendor=ROOT/'Vendor/libASPL'; sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
for name in ['Object','Plugin','Device','Stream','VolumeControl','MuteControl']:
 subprocess.run([sys.executable,str(vendor/'scripts/generate-accessors.py'),'-i',str(vendor/f'src/{name}.json'),'-o',str(vendor/f'src/{name}.g.cpp')],check=True)
subprocess.run([sys.executable,str(vendor/'scripts/generate-bridge.py'),'-i',str(vendor/'src/Bridge.json'),'-o',str(vendor/'src/Bridge.g.cpp')],check=True)
subprocess.run([sys.executable,str(vendor/'scripts/generate-strings.py'),'-c','/usr/bin/clang++','-s',sdk,'-o',str(vendor/'src/Strings.g.cpp')],check=True)
flags=['clang++','-std=c++17','-O2','-mmacosx-version-min=14.0','-I'+str(vendor/'include')]
subprocess.run(flags+[str(SRC/'RingTests.cpp'),'-o',str(OUT/'RingTests')],check=True);subprocess.run([str(OUT/'RingTests')],check=True)
app=OUT/'NeroInterpreterAudio.driver';contents=app/'Contents';(contents/'MacOS').mkdir(parents=True,exist_ok=True);(contents/'Resources').mkdir(exist_ok=True)
objects=[]
for source in [*vendor.glob('src/*.cpp'),SRC/'Driver.cpp']:
 obj=OUT/(('Nero-' if source.parent==SRC else 'ASPL-')+source.stem+'.o');objects.append(str(obj))
 if not obj.exists() or obj.stat().st_mtime<source.stat().st_mtime or source==SRC/'Driver.cpp':
  subprocess.run(flags+['-fPIC','-c',str(source),'-o',str(obj)],check=True)
subprocess.run(['clang++','-bundle',*objects,'-framework','CoreFoundation','-framework','CoreAudio','-o',str(contents/'MacOS/NeroInterpreterAudio')],check=True)
uid='B7090B51-837A-4659-93A7-11B128A9BB14'
(contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'cafe.nero.interpreter.audio','CFBundleExecutable':'NeroInterpreterAudio','CFBundleName':'Nero Interpreter Audio','CFBundlePackageType':'BNDL','CFBundleVersion':'1','CFBundleShortVersionString':'0.1.0','CFPlugInFactories':{uid:'NeroInterpreterEntryPoint'},'CFPlugInTypes':{'443ABAB8-E7B3-491A-B985-BEB9187030DB':[uid]},'AudioServerPlugIn_MachServices':[],'sandboxSafe':True}))
for p in vendor.glob('LICENSE*'):shutil.copy2(p,contents/'Resources'/p.name)
identity,_=resolve('cafe.nero.plugin.voice');sign(app,identity);details(app)
subprocess.run(flags+[str(SRC/'BridgeCheck.cpp'),'-framework','CoreAudio','-framework','CoreFoundation','-o',str(OUT/'NeroBridgeCheck')],check=True)
sign(OUT/'NeroBridgeCheck',identity)
subprocess.run(flags+[str(SRC/'DriverTests.cpp'),*objects,'-framework','CoreFoundation','-framework','CoreAudio','-o',str(OUT/'DriverTests')],check=True)
subprocess.run([str(OUT/'DriverTests')],check=True)
subprocess.run([str(OUT/'NeroBridgeCheck'),'--list'],check=True)
print(app)
