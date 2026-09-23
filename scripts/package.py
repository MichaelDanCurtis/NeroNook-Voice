#!/usr/bin/env python3
"""Package Nero Voice with its own macOS microphone privacy identity."""
import argparse, hashlib, json, os, plistlib, shutil, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def run(args, **kw):
    return subprocess.run([str(x) for x in args], cwd=ROOT, check=True, **kw)
def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--identity', default='-'); args = parser.parse_args()
    run(['swift', 'build', '-c', 'release'])
    binaries = Path(run(['swift', 'build', '-c', 'release', '--show-bin-path'], capture_output=True, text=True).stdout.strip())
    manifest = (ROOT/'Resources/NookPlugin.json').read_bytes(); value = json.loads(manifest)
    run([binaries/'PluginCheck', '--manifest'], input=manifest, capture_output=True)
    output = ROOT/'build'; output.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='voice-pack-', dir=output) as temp:
        app = Path(temp)/'Nero Voice.app'; (app/'Contents/MacOS').mkdir(parents=True); (app/'Contents/Resources').mkdir()
        shutil.copy2(binaries/'ModuleApp', app/'Contents/MacOS/ModuleApp')
        (app/'Contents/Resources/NookPlugin.json').write_bytes(manifest)
        info = dict(CFBundleName='Nero Voice', CFBundleDisplayName='Nero Voice', CFBundleIdentifier=value['id'],
                    CFBundleExecutable='ModuleApp', CFBundlePackageType='APPL', CFBundleShortVersionString=value['version'],
                    CFBundleVersion='1', LSMinimumSystemVersion='26.0', NSHighResolutionCapable=True,
                    NSMicrophoneUsageDescription='Nero Voice records your selected microphone when you press Record or hold your shortcut. Speech is transcribed on this Mac.',
                    NSSpeechRecognitionUsageDescription='Nero Voice turns speech into an editable transcript using on-device Apple Speech.')
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        entitlements = Path(temp)/'audio.plist'; entitlements.write_bytes(plistlib.dumps({'com.apple.security.device.audio-input': True}))
        run(['codesign', '--force', '--sign', args.identity, '--options', 'runtime', '--entitlements', entitlements, app], capture_output=True)
        run(['codesign', '--verify', '--deep', '--strict', app], capture_output=True)
        digest = hashlib.sha256()
        for p in sorted(app.rglob('*')):
            if p.is_file(): digest.update(str(p.relative_to(app)).encode()+b'\0'+p.read_bytes())
        final = output/(value['id']+'-'+value['version']+'-'+digest.hexdigest()[:12]+'.app')
        if final.exists():
            raise SystemExit('Output already exists; preserved it. '+str(final))
        shutil.move(app, final)
    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', final, final.with_suffix('.zip')])
    (output/'latest-package.txt').write_text(str(final)+'\n')
    print('Packaged: '+str(final))
if __name__ == '__main__': main()
