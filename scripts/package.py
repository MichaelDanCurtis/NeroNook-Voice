#!/usr/bin/env python3
"""Package Nero Voice with its own macOS microphone privacy identity."""
import argparse, hashlib, json, os, plistlib, shutil, subprocess, tempfile, sys
from pathlib import Path
from speaker_runtime import package_runtime
from signing import resolve, sign, verify_update
ROOT = Path(__file__).resolve().parents[1]
def run(args, **kw):
    return subprocess.run([str(x) for x in args], cwd=ROOT, check=True, **kw)
def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--identity'); args = parser.parse_args()
    identity, reference = resolve(json.loads((ROOT/'Resources/NookPlugin.json').read_text())['id'], args.identity)
    run(['swift', 'build', '-c', 'release'])
    binaries = Path(run(['swift', 'build', '-c', 'release', '--show-bin-path'], capture_output=True, text=True).stdout.strip())
    worker = ROOT/'Workers/Diarization'
    subprocess.run(['swift', 'package', 'resolve'], cwd=worker, check=True)
    run([sys.executable, ROOT/'scripts/patch-mlx-audio.py'])
    subprocess.run(['swift', 'build', '-c', 'release'], cwd=worker, check=True)
    worker_bin = Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=worker, text=True).strip())
    manifest = (ROOT/'Resources/NookPlugin.json').read_bytes(); value = json.loads(manifest)
    run([binaries/'PluginCheck', '--manifest'], input=manifest, capture_output=True)
    output = ROOT/'build'; output.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='voice-pack-', dir=output) as temp:
        app = Path(temp)/'Nero Voice.app'; (app/'Contents/MacOS').mkdir(parents=True); (app/'Contents/Resources').mkdir()
        shutil.copy2(binaries/'ModuleApp', app/'Contents/MacOS/ModuleApp')
        shutil.copytree(binaries/'NookPluginSDK_NookPluginSDK.bundle', app/'Contents/Resources/NookPluginSDK_NookPluginSDK.bundle')
        (app/'Contents/Resources/NookPlugin.json').write_bytes(manifest)
        shutil.copytree(ROOT/'Resources/Views', app/'Contents/Resources/Views')
        shutil.copytree(ROOT/'Resources/Speech', app/'Contents/Resources/Speech')
        shutil.copytree(ROOT/'Resources/Models', app/'Contents/Resources/Models')
        shutil.copytree(ROOT/'Resources/Licenses', app/'Contents/Resources/Licenses')
        helpers = app/'Contents/Helpers'; helpers.mkdir()
        shutil.copy2(worker_bin/'NeroNemotron', helpers/'NeroASR')
        # Keep original build symbols for debugging; strip only the staged shared worker.
        run(['xcrun', 'strip', '-S', '-x', helpers/'NeroASR'])
        shutil.copytree(ROOT/'Workers/NemotronSpeakers', app/'Contents/Resources/NemotronSpeakers', ignore=shutil.ignore_patterns('__pycache__'))
        package_runtime(app/'Contents/Resources/speaker-runtime.tar.gz', identity)
        shutil.copy2(worker_bin/'mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib', helpers/'mlx.metallib')
        for resource in worker_bin.glob('*.bundle'): shutil.copytree(resource, app/'Contents/Resources'/resource.name)
        sign(helpers/'mlx.metallib', identity)
        sign(helpers/'NeroASR', identity, '--options', 'runtime')
        info = dict(CFBundleName='Nero Voice', CFBundleDisplayName='Nero Voice', CFBundleIdentifier=value['id'],
                    CFBundleExecutable='ModuleApp', CFBundlePackageType='APPL', CFBundleShortVersionString=value['version'],
                    CFBundleVersion='1', LSUIElement=True, LSMinimumSystemVersion='26.0', NSHighResolutionCapable=True,
                    NSMicrophoneUsageDescription='Nero Voice records your selected microphone when you start dictation, a meeting, Talk or a voice-cloning reference. Saved audio stays on this Mac.',
                    NSAudioCaptureUsageDescription='Record your selected call audio or system audio when you start a meeting. Audio is saved on this Mac.',
                    NSSpeechRecognitionUsageDescription='Nero Voice turns speech into an editable transcript using on-device Apple Speech.')
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        entitlements = Path(temp)/'audio.plist'; entitlements.write_bytes(plistlib.dumps({'com.apple.security.device.audio-input': True}))
        sign(app, identity, '--options', 'runtime', '--entitlements', entitlements)
        verify_update(app, reference)
        run(['codesign', '--verify', '--deep', '--strict', app], capture_output=True)
        files=[p for p in app.rglob('*') if p.is_file()]
        if sum(p.stat().st_size for p in files)>128*1024*1024 or len(files)>4096:
            raise SystemExit('Plugin exceeds the host package limit; existing package preserved.')
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
