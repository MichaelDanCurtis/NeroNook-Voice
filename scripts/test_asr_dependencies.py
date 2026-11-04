import json
import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch, Mock

import asr_dependencies as audit


def fixture(rpaths=('/usr/lib/swift', '@loader_path', '/Applications/Xcode.app/Toolchain'),
            name='@rpath/libswiftCompatibilitySpan.dylib', command='LC_LOAD_DYLIB'):
    # Representative real otool -l format, including an unrelated segment.
    commands = ['      cmd LC_SEGMENT_64\n  cmdsize 72\n  segname __TEXT',
                '      cmd LC_LOAD_DYLINKER\n  cmdsize 32\n     name /usr/lib/dyld (offset 12)',
                '      cmd LC_BUILD_VERSION\n  cmdsize 32\n platform 1\n    minos 14.0\n      sdk 27.0\n   ntools 1']
    commands += ['      cmd LC_RPATH\n  cmdsize 40\n     path '+p+' (offset 12)' for p in rpaths]
    commands += ['      cmd '+command+'\n  cmdsize 80\n     name '+name+' (offset 24)\n    time stamp 2 Thu Jan  1 00:00:02 1970\n      current version 6.4.0\ncompatibility version 1.0.0']
    return '/authored/NeroASR:\n'+''.join('Load command '+str(i)+'\n'+c+'\n' for i,c in enumerate(commands))


class ASRDependencyAuditTests(unittest.TestCase):
    def test_real_format_parse_preserves_order_and_minimum(self):
        value = audit.parse_load_commands(fixture())
        self.assertEqual(value['workerMinimumMacOS'], '14.0')
        self.assertEqual(value['rpaths'], ['/usr/lib/swift', '@loader_path', '/Applications/Xcode.app/Toolchain'])
        self.assertEqual(value['loads'], [{'command':'LC_LOAD_DYLIB','name':'@rpath/libswiftCompatibilitySpan.dylib'}])

    def test_system_cache_provider_precedes_developer_fallback(self):
        queried = []
        def cache(p):
            queried.append(p)
            return p == '/usr/lib/swift/libswiftCompatibilitySpan.dylib'
        value = audit.evaluate(audit.parse_load_commands(fixture()), cache)
        self.assertEqual(queried, ['/usr/lib/swift/libswiftCompatibilitySpan.dylib'])
        self.assertEqual(value[0]['provider'], 'dyld-shared-cache')

    def test_missing_file_does_not_override_cache_provider(self):
        with patch('asr_dependencies.os.path.exists', side_effect=AssertionError('No file-absence inference')):
            result = audit.evaluate(audit.parse_load_commands(fixture()), lambda p: True)
        self.assertEqual(result[0]['resolvedPath'], '/usr/lib/swift/libswiftCompatibilitySpan.dylib')

    def test_developer_only_dependency_refuses(self):
        with self.assertRaisesRegex(audit.DependencyError, 'Non-system rpath'):
            audit.evaluate(audit.parse_load_commands(fixture(('/Applications/Xcode.app/lib',))), lambda p: False)

    def test_developer_shadow_before_system_refuses(self):
        with self.assertRaisesRegex(audit.DependencyError, 'Non-system rpath'):
            audit.evaluate(audit.parse_load_commands(fixture(('@loader_path','/usr/lib/swift'))), lambda p: True)

    def test_missing_required_os_provider_refuses(self):
        with self.assertRaisesRegex(audit.DependencyError, 'no verified OS cache'):
            audit.evaluate(audit.parse_load_commands(fixture(('/usr/lib/swift',))), lambda p: False)

    def test_absolute_developer_load_refuses(self):
        with self.assertRaisesRegex(audit.DependencyError, 'Unsupported non-system'):
            audit.evaluate(audit.parse_load_commands(fixture(name='/Applications/Xcode.app/lib/libswiftX.dylib')), lambda p: True)

    def test_other_relative_load_refuses(self):
        with self.assertRaises(audit.DependencyError):
            audit.evaluate(audit.parse_load_commands(fixture(name='@rpath/libUnreviewed.dylib')), lambda p: True)

    def test_system_traversal_refuses(self):
        with self.assertRaises(audit.DependencyError):
            audit.evaluate(audit.parse_load_commands(fixture(name='/usr/lib/../../Applications/Xcode.app/libX.dylib')), lambda p: True)

    def test_absolute_system_load_requires_actual_cache_evidence(self):
        name='/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation'
        result = audit.evaluate(audit.parse_load_commands(fixture(name=name)), lambda p:p==name)
        self.assertEqual(result[0]['resolvedPath'],name)
        self.assertEqual(result[0]['provider'],'dyld-shared-cache')

    def test_missing_required_absolute_system_load_refuses(self):
        with self.assertRaisesRegex(audit.DependencyError,'Required system dependency'):
            audit.evaluate(audit.parse_load_commands(fixture(name='/usr/lib/libDefinitelyMissing.dylib')),lambda p:False)

    def test_missing_weak_absolute_system_load_is_explicit(self):
        result=audit.evaluate(audit.parse_load_commands(fixture(name='/usr/lib/libDefinitelyMissing.dylib',command='LC_LOAD_WEAK_DYLIB')),lambda p:False)
        self.assertEqual(result[0]['provider'],'optional-unavailable')

    def test_optional_missing_swift_overlay_is_explicit(self):
        result = audit.evaluate(audit.parse_load_commands(fixture(('/usr/lib/swift',), command='LC_LOAD_WEAK_DYLIB')), lambda p: False)
        self.assertEqual(result[0]['provider'], 'optional-unavailable')

    def test_malformed_load_name_refuses(self):
        with self.assertRaises(audit.DependencyError):
            audit.parse_load_commands(fixture().replace('(offset 24)', '(offset bad)'))

    def test_multiple_architecture_metadata_refuses(self):
        with self.assertRaises(audit.DependencyError):
            audit.parse_load_commands(fixture()+fixture())

    def test_non_macos_platform_refuses(self):
        with self.assertRaises(audit.DependencyError):
            audit.parse_load_commands(fixture().replace('platform 1','platform 7'))

    def test_non_system_linker_refuses(self):
        with self.assertRaisesRegex(audit.DependencyError,'dynamic linker'):
            audit.parse_load_commands(fixture().replace('/usr/lib/dyld','/Applications/Unreviewed/dyld'))

    def test_lazy_load_dependency_refuses_before_provider_query(self):
        text = fixture()
        text += ('Load command '+str(text.count('Load command '))+'\n'
                 '      cmd LC_LAZY_LOAD_DYLIB\n  cmdsize 80\n'
                 '     name /usr/lib/libSystem.B.dylib (offset 24)\n')
        provider = Mock(return_value=True)
        with self.assertRaisesRegex(audit.DependencyError, 'Unsupported executable loader command'):
            audit.evaluate(audit.parse_load_commands(text), provider)
        provider.assert_not_called()

    def test_missing_build_version_refuses(self):
        with self.assertRaises(audit.DependencyError):
            audit.parse_load_commands(fixture().replace('LC_BUILD_VERSION','LC_UUID'))

    def test_oversized_or_nul_metadata_refuses(self):
        for text in [fixture()+'\0', 'a'*(audit.MAX_METADATA+1)]:
            with self.assertRaises(audit.DependencyError): audit.parse_load_commands(text)

    def test_authored_binary_snapshot_and_symlink_refusal(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve(); worker=root/'worker'
            worker.write_bytes(struct.pack('<8I',0xfeedfacf,0x100000c,0,2,0,0,0,0)+b'authored-fixture')
            value=audit.snapshot(worker)
            self.assertEqual(value['size'],worker.stat().st_size)
            link=root/'link'; link.symlink_to(worker)
            with self.assertRaises(OSError): audit.snapshot(link)

    def test_non_macho_refuses_without_execution(self):
        with tempfile.TemporaryDirectory() as temp:
            worker=Path(temp)/'not-code';worker.write_bytes(b'# no executable bytes\n'*4)
            with self.assertRaises(audit.DependencyError): audit.snapshot(worker)

    def test_actual_inspect_records_pre_sign_scope_and_redacts_developer_paths(self):
        with tempfile.TemporaryDirectory() as temp:
            worker=Path(temp).resolve()/'worker'
            worker.write_bytes(struct.pack('<8I',0xfeedfacf,0x100000c,0,2,0,0,0,0)+b'authored-fixture')
            def metadata(args,stdout,stderr,**kwargs):
                self.assertEqual(args[:2],['/usr/bin/otool','-l'])
                stdout.write(fixture(rpaths=('/usr/lib/swift','/Users/authored/private-build')).encode())
                return subprocess.CompletedProcess(args,0)
            with patch.object(audit.platform,'system',return_value='Darwin'), \
                 patch.object(audit.platform,'mac_ver',return_value=('27.0.1',(),'')), \
                 patch.object(audit.platform,'machine',return_value='arm64'), \
                 patch.object(audit.subprocess,'run',side_effect=metadata), \
                 patch.object(audit,'cache_probe',return_value=lambda p:True):
                result=audit.inspect(worker)
            self.assertFalse(result['minimumOSCompatibilityVerified'])
            self.assertEqual(result['appMinimumMacOS'],'26.0')
            self.assertEqual(result['phase'],'stripped worker before codesigning')
            self.assertEqual(result['rpaths'],['/usr/lib/swift','<non-system-rpath>'])
            self.assertNotIn('/Users/authored',json.dumps(result))

    def test_unknown_cache_api_refuses_without_loading_target_library(self):
        with patch.object(audit.ctypes,'CDLL',return_value=object()) as loaded:
            with self.assertRaisesRegex(audit.DependencyError,'cache evidence'):audit.cache_probe()
        loaded.assert_called_once_with(None)

    def test_foreign_architecture_refuses_before_metadata_or_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            worker=Path(temp).resolve()/'worker'
            worker.write_bytes(struct.pack('<8I',0xfeedfacf,0x1000007,0,2,0,0,0,0)+b'authored-x86-fixture')
            with patch.object(audit.platform,'system',return_value='Darwin'), \
                 patch.object(audit.platform,'mac_ver',return_value=('27.0.1',(),'')), \
                 patch.object(audit.platform,'machine',return_value='arm64'), \
                 patch.object(audit.subprocess,'run') as inspector, \
                 patch.object(audit,'cache_probe') as cache:
                with self.assertRaisesRegex(audit.DependencyError,'different worker architecture'):audit.inspect(worker)
            inspector.assert_not_called();cache.assert_not_called()

    def test_package_gate_precedes_all_signing_and_records_scope(self):
        source=Path(__file__).with_name('package.py').read_text()
        self.assertLess(source.index('dependency_audit = inspect_asr_dependencies'),source.index('package_runtime(app/'))
        self.assertIn('ASRDependencyAudit.json',source)
        self.assertNotIn('swift-stdlib-tool',source) # No unconditional runtime redistribution.

    def package_fixture(self, root):
        binaries=root/'bin'; worker=root/'worker-bin'
        for directory in [binaries,worker,root/'Workers/Diarization']:
            directory.mkdir(parents=True)
        (binaries/'ModuleApp').write_bytes(b'authored ModuleApp data')
        (binaries/'NookPluginSDK_NookPluginSDK.bundle').mkdir()
        (worker/'NeroNemotron').write_bytes(b'authored worker data; never executed')
        metal=worker/'mlx-swift_Cmlx.bundle/Contents/Resources';metal.mkdir(parents=True)
        (metal/'default.metallib').write_bytes(b'authored metallib data')
        for rel in ['Views','Speech','Models','Licenses']:
            (root/'Resources'/rel).mkdir(parents=True)
        (root/'Workers/NemotronSpeakers').mkdir()
        (root/'Resources/NookPlugin.json').write_text(json.dumps({'id':'fixture.voice','version':'0.0.0'}))
        runtime=types.ModuleType('speaker_runtime');runtime.package_runtime=Mock()
        signing=types.ModuleType('signing');signing.resolve=Mock(return_value=('fixture-identity',None))
        signing.sign=Mock();signing.verify_update=Mock()
        spec=importlib.util.spec_from_file_location('authored_package_fixture',Path(__file__).with_name('package.py'))
        module=importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules,{'speaker_runtime':runtime,'signing':signing}):
            spec.loader.exec_module(module)
        module.ROOT=root
        module.run=Mock(return_value=subprocess.CompletedProcess([],0,stdout=str(binaries)+'\n'))
        return module,worker,runtime,signing

    def test_actual_package_main_refusal_precedes_every_sign(self):
        with tempfile.TemporaryDirectory() as temp:
            module,worker,runtime,signing=self.package_fixture(Path(temp).resolve())
            def refuse(*args,**kwargs):
                return audit.evaluate(audit.parse_load_commands(fixture(('/Applications/Xcode.app/lib',))),lambda p:False)
            with patch.object(module,'inspect_asr_dependencies',side_effect=refuse), \
                 patch.object(module.subprocess,'run'), \
                 patch.object(module.subprocess,'check_output',return_value=str(worker)), \
                 patch.object(sys,'argv',['package.py']):
                with self.assertRaisesRegex(audit.DependencyError,'Non-system rpath'):module.main()
            runtime.package_runtime.assert_not_called()
            signing.sign.assert_not_called()
            signing.verify_update.assert_not_called()
            self.assertFalse((module.ROOT/'build/latest-package.txt').exists())

    def test_actual_package_main_records_audit_before_existing_sign_flow(self):
        with tempfile.TemporaryDirectory() as temp:
            module,worker,runtime,signing=self.package_fixture(Path(temp).resolve())
            evidence={'phase':'stripped worker before codesigning','minimumOSCompatibilityVerified':False,
                      'providers':audit.evaluate(audit.parse_load_commands(fixture()),lambda p:True)}
            observed=[]
            def nested_runtime(path,identity):
                report=path.parent/'ASRDependencyAudit.json'
                self.assertEqual(json.loads(report.read_text()),evidence)
                observed.append('runtime-sign-phase')
            runtime.package_runtime.side_effect=nested_runtime
            def sign(path,*args):
                self.assertTrue(observed)
                observed.append(Path(path).name)
            signing.sign.side_effect=sign
            with patch.object(module,'inspect_asr_dependencies',return_value=evidence), \
                 patch.object(module.subprocess,'run'), \
                 patch.object(module.subprocess,'check_output',return_value=str(worker)), \
                 patch.object(sys,'argv',['package.py']):
                module.main()
            self.assertEqual(observed[:3],['runtime-sign-phase','mlx.metallib','NeroASR'])
            final=Path((module.ROOT/'build/latest-package.txt').read_text().strip())
            self.assertEqual(json.loads((final/'Contents/Resources/ASRDependencyAudit.json').read_text()),evidence)


if __name__ == '__main__':
    unittest.main()
