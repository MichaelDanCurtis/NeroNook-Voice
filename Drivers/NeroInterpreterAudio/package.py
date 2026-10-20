"""Build a reviewable local installer; never runs it or restarts Core Audio."""
from pathlib import Path
import subprocess,shutil,sys,json,hashlib,plistlib
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'build/interpreter-audio';driver=OUT/'NeroInterpreterAudio.driver'
sys.path.insert(0,str(ROOT/'scripts'));from signing import details
signature=details(driver)
stage=OUT/'installer-root';stage.mkdir(exist_ok=True)
target=stage/driver.name
if target.exists():shutil.rmtree(target)
shutil.copytree(driver,target)
scripts=OUT/'installer-scripts';scripts.mkdir(exist_ok=True)
pre=scripts/'preinstall'
pre.write_text('''#!/bin/sh
set -eu
# First development install only: preserve any existing driver, including symlinks.
target="/Library/Audio/Plug-Ins/HAL/NeroInterpreterAudio.driver"
if [ -e "$target" ] || [ -L "$target" ]; then
 echo "An existing Nero Interpreter driver was found. This first-install package will not overwrite it." >&2
 exit 1
fi
exit 0
''');pre.chmod(0o755)
component=OUT/'NeroInterpreterAudio-component.pkg'
components=OUT/'components.plist'
subprocess.run(['/usr/bin/pkgbuild','--analyze','--root',str(stage),str(components)],check=True)
items=plistlib.loads(components.read_bytes())
for item in items:item['BundleIsRelocatable']=False
components.write_bytes(plistlib.dumps(items))
subprocess.run(['/usr/bin/pkgbuild','--component-plist',str(components),'--filter',r'(^|/)\._[^/]*$','--filter',r'(^|/)\.DS_Store$','--root',str(stage),'--install-location','/Library/Audio/Plug-Ins/HAL','--ownership','recommended','--identifier','cafe.nero.interpreter.audio.pkg','--version','0.1.0','--scripts',str(scripts),str(component)],check=True)
resources=OUT/'installer-resources';resources.mkdir(exist_ok=True)
(resources/'Welcome.txt').write_text('Nero Interpreter Audio 0.1 — local development preview\n\nAdds two virtual audio devices: Nero Interpreter Speaker and Nero Interpreter Microphone.\n\nThis installs only the driver. It does not connect Teams, record audio, change your default devices, or start translation. Routes are silent until explicitly activated by the bridge, and expire after 500 ms without its heartbeat.\n\nAdministrator approval is required. Restart the Mac when convenient to load the driver; this package does not restart the audio service. Save your work first. This is a locally signed development driver, not a notarized public release.\n\nAfter restarting, return to Nero Interpreter Preview and run the audio bridge check before selecting devices in Teams.\n')
(resources/'Conclusion.txt').write_text('Driver copied. Restart your Mac when convenient, then return to Nero Interpreter Preview and run Check audio bridge. Do not select these devices in a real meeting yet: the two-way translation session is not connected.\n\nThe source and removal instructions are in NeroNook-Voice/Drivers/NeroInterpreterAudio/README.md.\n')
dist=OUT/'Distribution.xml';dist.write_text('''<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
<title>Nero Interpreter Audio — Preview</title><organization>cafe.nero</organization>
<options customize="never" require-scripts="false" hostArchitectures="arm64"/>
<welcome file="Welcome.txt" mime-type="text/plain"/><conclusion file="Conclusion.txt" mime-type="text/plain"/>
<domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
<choices-outline><line choice="audio"/></choices-outline>
<choice id="audio" visible="false"><pkg-ref id="cafe.nero.interpreter.audio.pkg"/></choice>
<pkg-ref id="cafe.nero.interpreter.audio.pkg" version="0.1.0" auth="Root">NeroInterpreterAudio-component.pkg</pkg-ref>
</installer-gui-script>''')
pkg=OUT/'NeroInterpreterAudio-0.1.0.pkg'
subprocess.run(['/usr/bin/productbuild','--distribution',str(dist),'--package-path',str(OUT),'--resources',str(resources),str(pkg)],check=True)
(OUT/'package-receipt.json').write_text(json.dumps({'driverSignature':signature,'installer':str(pkg),'sha256':hashlib.sha256(pkg.read_bytes()).hexdigest(),'installed':False,'restartPerformed':False},indent=2)+'\n')
print(pkg)
