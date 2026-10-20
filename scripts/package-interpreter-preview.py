"""Package a workspace-bound interpreter preview; does not install a plugin or driver."""
from pathlib import Path
import plistlib,shutil,subprocess
from signing import resolve,sign,details
ROOT=Path(__file__).resolve().parents[1]
subprocess.run(['swift','build','--product','InterpreterPreview'],cwd=ROOT,check=True)
binpath=Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=ROOT,text=True).strip())
app=ROOT/'build/Nero Interpreter Preview.app'
contents=app/'Contents'
for sub in ['MacOS','Resources']:(contents/sub).mkdir(parents=True,exist_ok=True)
shutil.copy2(binpath/'InterpreterPreview',contents/'MacOS/InterpreterPreview')
(contents/'Resources/preview-root.txt').write_text(str(ROOT))
(contents/'Info.plist').write_bytes(plistlib.dumps({
 'CFBundleIdentifier':'cafe.nero.voice.interpreter.preview','CFBundleName':'Nero Interpreter Preview',
 'CFBundleExecutable':'InterpreterPreview','CFBundlePackageType':'APPL',
 'CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1','LSMinimumSystemVersion':'26.0',
 'NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication',
 'NSMicrophoneUsageDescription':'Record a short phrase only when you press Record phrase, then translate it locally.'}))
helper=ROOT/'build/interpreter-audio/NeroBridgeCheck'
if helper.exists():
 (contents/'Helpers').mkdir(exist_ok=True)
 shutil.copy2(helper,contents/'Helpers/NeroBridgeCheck')
entitlements=ROOT/'build/interpreter-preview.entitlements'
entitlements.write_bytes(plistlib.dumps({'com.apple.security.device.audio-input':True}))
identity,_=resolve('cafe.nero.plugin.voice')
sign(app,identity,'--options','runtime','--entitlements',str(entitlements))
details(app)
print(app)
