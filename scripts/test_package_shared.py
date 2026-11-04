"""Assembly/filesystem checks only: authored bytes are never executable identity proof."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import package_shared as pack
if Path(pack.__file__).resolve() != Path(__file__).resolve().with_name('package_shared.py'):
    raise RuntimeError('Test import did not select its exact sibling package source.')


class SharedPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='voice-package-authored-')
        # macOS /var and /tmp aliases must not obscure the physical-path tests.
        self.root = Path(self.temporary.name).resolve()
        self.app = self.root / 'Prebuilt.app'
        self.info = dict(CFBundleIdentifier=pack.SERVICE_ID, CFBundleExecutable='ModuleApp',
                         **{name: 'Authored privacy text for ' + name for name in pack.PRIVACY})
        self.put(self.app / 'Contents/Info.plist', plistlib.dumps(self.info))
        for name in ('Contents/MacOS/ModuleApp', 'Contents/Helpers/NeroASR'):
            self.put(self.app / name, b'authored prebuilt bytes, not a real binary', executable=True)
        self.put(self.app / 'Contents/Helpers/mlx.metallib', b'authored metal data')
        for name in ('qwen-tts', 'qwen-base', 'qwen-design'):
            self.put(self.app / ('Contents/Resources/Models/' + name + '.json'), b'{}')
        for name in ('speaker-model', 'parakeet-model', 'mlx-swift', 'mlx-audio-swift', 'qwen-tts', 'nemotron-models'):
            self.put(self.app / ('Contents/Resources/Licenses/' + name + '.txt'), ('authored license ' + name).encode())
        for name, data in {'Views/index.html': b'authored view', 'Speech/apple_voice.swift': b'authored speech adapter',
                           'speaker-runtime.tar.gz': b'opaque authored archive, never unpacked',
                           'NemotronSpeakers/speakers.py': b'authored helper',
                           'NookPluginSDK_NookPluginSDK.bundle/old-sdk.txt': b'old SDK must not be copied',
                           'NookPlugin.json': b'{"launchMode":"application"}'}.items():
            self.put(self.app / 'Contents/Resources' / name, data)
        self.service, self.connector = self.root / 'ModuleApp.bin', self.root / 'VoiceConnector.bin'
        self.put(self.service, b'authored service bytes, never run', executable=True)
        self.put(self.connector, b'authored connector bytes, never run', executable=True)
        self.sdk = self.root / 'CompiledSDK.bundle'
        self.put(self.sdk / 'Contracts/shared-application-v1.schema.json', b'{"authored":"same build SDK"}')
        self.put(self.sdk / 'theme.css', b'authored same-build theme')
        self.template = self.root / 'shared-template.json'
        self.manifest = dict(id=pack.SERVICE_ID, name='Nero Voice', summary='Authored assembly fixture', version='__VERSION__',
                             apiVersion=1, launchMode='sharedApplication', capabilities=['authored capability'],
                             sharedApplication=dict(protocolVersion=1, connectorBundleIdentifier=pack.CONNECTOR_ID,
                                                    serviceIdentifier=pack.SERVICE_ID, resourceRevision='__VIEWS_REVISION__'))
        self.put(self.template, json.dumps(self.manifest).encode())
        self.args = dict(resource_app=self.app, service_binary=self.service, connector_binary=self.connector,
                         template=self.template, output=self.root / 'stage', version='0.22.8', build='2',
                         service_sha256=self.sha(self.service), connector_sha256=self.sha(self.connector),
                         sdk_resources=self.sdk, sdk_sha256=pack.tree_digest(pack.scan(self.sdk)[0]),
                         views_resources=self.app / 'Contents/Resources/Views',
                         views_sha256=pack.tree_digest(pack.scan(self.app / 'Contents/Resources/Views')[0]))

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def put(path, data, executable=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o755 if executable else 0o644)

    @staticmethod
    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def plan(self, **changes):
        return pack.make_plan(**dict(self.args, **changes))

    def test_qualified_views_replace_older_base_views_in_both_apps(self):
        current = self.root / 'QualifiedViews'
        self.put(current / 'index.html', b'qualified new interface')
        self.put(current / 'meetings/meeting.js', b'qualified new meeting behavior')
        expected = pack.tree_digest(pack.scan(current)[0])
        plan = self.plan(views_resources=current, views_sha256=expected)
        receipt = pack.stage(plan)
        for name in ('Nero Voice.app', 'Nero Voice Module.app'):
            root = self.args['output'] / name / 'Contents/Resources/Views'
            self.assertEqual((root / 'index.html').read_bytes(), b'qualified new interface')
            self.assertEqual((root / 'meetings/meeting.js').read_bytes(), b'qualified new meeting behavior')
            self.assertEqual(pack.tree_digest(pack.scan(root)[0]), expected)
        self.assertEqual(receipt['viewsRevision'], expected)
        self.assertEqual(receipt['qualifiedViewsTreeSHA256'], expected)
        self.assertEqual((self.app / 'Contents/Resources/Views/index.html').read_bytes(), b'authored view')

    def test_wrong_or_changed_qualified_views_never_publish_success(self):
        with self.assertRaises(pack.PackageError):
            self.plan(views_sha256='0' * 64)
        self.assertFalse(self.args['output'].exists())
        plan = self.plan()
        (self.args['views_resources'] / 'index.html').write_bytes(b'changed after reviewed plan')
        with self.assertRaises(pack.PackageError):
            pack.stage(plan)
        self.assertFalse((self.args['output'] / 'assembly.json').exists())
        self.assertTrue((self.args['output'] / 'INCOMPLETE.json').is_file())

    def test_default_cli_only_plans_without_build_sign_launch_or_output(self):
        argv = []
        for key, value in self.args.items():
            argv += ['--' + key.replace('_', '-'), str(value)]
        with mock.patch('subprocess.run', side_effect=AssertionError('subprocess forbidden')):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                pack.main(argv)
        value = json.loads(output.getvalue())
        self.assertEqual(value['mode'], 'read-only-plan')
        self.assertFalse(self.args['output'].exists())
        self.assertEqual(self.sha(self.service), self.args['service_sha256'])

    def test_stage_pairs_roles_privacy_and_same_build_sdk_without_service_launcher_in_module(self):
        plan = self.plan()
        receipt = pack.stage(plan)
        output = self.args['output']
        service, module = output / 'Nero Voice.app', output / 'Nero Voice Module.app'
        service_info = plistlib.loads((service / 'Contents/Info.plist').read_bytes())
        module_info = plistlib.loads((module / 'Contents/Info.plist').read_bytes())
        self.assertEqual(service_info['CFBundleIdentifier'], pack.SERVICE_ID)
        self.assertEqual(service_info['NeroVoiceRuntimeKind'], 'shared-service-v1')
        self.assertEqual(service_info['CFBundleExecutable'], 'ModuleApp')
        self.assertEqual(module_info['CFBundleIdentifier'], pack.CONNECTOR_ID)
        self.assertEqual(module_info['CFBundleExecutable'], 'VoiceConnector')
        self.assertNotIn('NeroVoiceRuntimeKind', module_info)
        self.assertFalse((module / 'Contents/Helpers').exists())
        self.assertFalse((module / 'Contents/Resources/Models').exists())
        self.assertFalse((service / 'Contents/Resources/NookPlugin.json').exists())
        for key in pack.PRIVACY:
            self.assertEqual(service_info[key], self.info[key])
        manifest = json.loads((module / 'Contents/Resources/NookPlugin.json').read_bytes())
        self.assertEqual(manifest['launchMode'], 'sharedApplication')
        self.assertEqual(manifest['sharedApplication']['resourceRevision'], receipt['viewsRevision'])
        for app in (service, module):
            sdk = app / 'Contents/Resources/NookPluginSDK_NookPluginSDK.bundle'
            self.assertEqual(pack.tree_digest(pack.scan(sdk)[0]), self.args['sdk_sha256'])
            self.assertFalse((sdk / 'old-sdk.txt').exists())
            self.assertTrue((app / 'Contents/Resources/Licenses/qwen-tts.txt').is_file())
        self.assertFalse((output / 'INCOMPLETE.json').exists())
        self.assertEqual(json.loads((output / 'assembly.json').read_bytes())['apps'], receipt['apps'])
        self.assertEqual(self.sha(service / 'Contents/MacOS/ModuleApp'), self.args['service_sha256'])
        self.assertEqual(self.sha(module / 'Contents/MacOS/VoiceConnector'), self.args['connector_sha256'])

    def test_existing_output_is_never_replaced_by_plan_or_racing_stage(self):
        plan = self.plan()
        self.args['output'].mkdir()
        marker = self.args['output'] / 'keep.txt'
        marker.write_bytes(b'existing output')
        with self.assertRaises(pack.PackageError):
            self.plan()
        with self.assertRaises(FileExistsError):
            pack.stage(plan)
        self.assertEqual(marker.read_bytes(), b'existing output')
        self.assertEqual(list(self.args['output'].iterdir()), [marker])

    def test_binary_and_same_build_sdk_pins_refuse_wrong_bytes(self):
        for key in ('service_sha256', 'connector_sha256', 'sdk_sha256'):
            with self.subTest(key=key), self.assertRaises(pack.PackageError):
                self.plan(**{key: '0' * 64})
        self.assertFalse(self.args['output'].exists())

    def test_unsupported_framework_dependency_is_refused_not_silently_dropped(self):
        self.put(self.app / 'Contents/Frameworks/Required.framework/resource', b'required dependency')
        with self.assertRaises(pack.PackageError):
            self.plan()
        self.assertFalse(self.args['output'].exists())

    def test_missing_privacy_or_required_license_refuses(self):
        broken = dict(self.info)
        del broken[pack.PRIVACY[0]]
        self.put(self.app / 'Contents/Info.plist', plistlib.dumps(broken))
        with self.assertRaises(pack.PackageError):
            self.plan()
        self.put(self.app / 'Contents/Info.plist', plistlib.dumps(self.info))
        (self.app / 'Contents/Resources/Licenses/qwen-tts.txt').unlink()
        with self.assertRaises(pack.PackageError):
            self.plan()

    def test_symlink_leaf_dangling_and_ancestor_are_refused(self):
        original = self.service
        for target in (original, self.root / 'missing'):
            link = self.root / 'linked-binary'
            link.symlink_to(target)
            with self.assertRaises((OSError, pack.PackageError)):
                self.plan(service_binary=link)
            link.unlink()
        alias = self.root / 'alias'
        alias.symlink_to(self.app / 'Contents', target_is_directory=True)
        with self.assertRaises((OSError, pack.PackageError)):
            pack.read_file(alias / 'Info.plist', maximum=65536)
        out_alias = self.root / 'output-alias'
        out_alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises((OSError, pack.PackageError)):
            self.plan(output=out_alias / 'fresh')
        with self.assertRaises(pack.PackageError):
            pack.physical(str(self.root) + '/\udcff')

    def test_hardlinks_and_special_resources_are_rejected_before_read(self):
        hard = self.root / 'hard-binary'
        os.link(self.service, hard)
        with self.assertRaises(pack.PackageError):
            self.plan(service_binary=hard)
        hard.unlink()
        special = self.app / 'Contents/Resources/fifo'
        os.mkfifo(special)
        with self.assertRaises(pack.PackageError):
            self.plan()

    def test_views_digest_matches_independent_swift_combining_filename_vector(self):
        views = self.app / 'Contents/Resources/Views'
        (views / 'index.html').write_bytes(b'authored index')
        self.put(views / '\u0301echo.txt', b'authored combining path')
        self.assertEqual(pack.views_digest(pack.scan(self.app)[0]),
                         '945feaf79d22d3b838d7bf5a2a528e7b7cf683bfb83eb5504b856e2a34dcfd7e')

    def test_per_file_view_limit_is_checked_before_staging(self):
        with (self.app / 'Contents/Resources/Views/huge.txt').open('wb') as handle:
            handle.truncate(2 * 1024 * 1024 + 1)
        with self.assertRaises(pack.PackageError):
            self.plan()
        self.assertFalse(self.args['output'].exists())

    def test_entry_and_total_byte_limits_are_enforced_before_stage(self):
        with mock.patch.object(pack, 'MAX_ENTRIES', 3):
            with self.assertRaises(pack.PackageError):
                self.plan()
        with mock.patch.object(pack, 'MAX_BYTES', 8):
            with self.assertRaises(pack.PackageError):
                self.plan()
        self.assertFalse(self.args['output'].exists())

    def test_input_change_after_plan_preserves_incomplete_new_stage_without_success(self):
        plan = self.plan()
        self.service.write_bytes(b'changed input')
        with self.assertRaises(pack.PackageError):
            pack.stage(plan)
        self.assertTrue((self.args['output'] / 'INCOMPLETE.json').is_file())
        self.assertFalse((self.args['output'] / 'assembly.json').exists())
        self.assertEqual(self.service.read_bytes(), b'changed input')

    def test_swapped_source_ancestor_is_refused_even_with_identical_file_bytes(self):
        directory = self.root / 'artifacts'
        source = directory / 'ModuleApp'
        self.put(source, self.service.read_bytes(), executable=True)
        plan = self.plan(service_binary=source)
        directory.rename(self.root / 'old-artifacts')
        self.put(source, self.service.read_bytes(), executable=True)
        with self.assertRaises(pack.PackageError):
            pack.stage(plan)
        self.assertFalse((self.args['output'] / 'assembly.json').exists())

    def test_missing_nonviews_staged_file_cannot_publish_success(self):
        plan = self.plan()
        original_write = pack._write
        def remove_worker(fd, relative, mode, producer):
            original_write(fd, relative, mode, producer)
            if relative == 'Nero Voice Module.app/Contents/Resources/NookPlugin.json':
                (self.args['output'] / 'Nero Voice.app/Contents/Helpers/NeroASR').unlink()
        with mock.patch.object(pack, '_write', side_effect=remove_worker):
            with self.assertRaises(pack.PackageError):
                pack.stage(plan)
        self.assertTrue((self.args['output'] / 'INCOMPLETE.json').exists())
        self.assertFalse((self.args['output'] / 'assembly.json').exists())

    def test_marker_unlink_failure_cannot_leave_success_receipt(self):
        plan = self.plan()
        original = os.unlink
        def refuse_marker(path, **kwargs):
            if path == 'INCOMPLETE.json':
                raise OSError('authored marker failure')
            return original(path, **kwargs)
        with mock.patch.object(pack.os, 'unlink', side_effect=refuse_marker):
            with self.assertRaises(OSError):
                pack.stage(plan)
        self.assertFalse((self.args['output'] / 'assembly.json').exists())
        self.assertTrue((self.args['output'] / 'INCOMPLETE.json').exists())

    def test_directory_flush_failure_is_before_success_publication(self):
        plan = self.plan()
        original = os.fsync
        def refuse_directory(fd):
            import stat
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                raise OSError('authored directory flush failure')
            return original(fd)
        with mock.patch.object(pack.os, 'fsync', side_effect=refuse_directory):
            with self.assertRaises(OSError):
                pack.stage(plan)
        self.assertFalse((self.args['output'] / 'assembly.json').exists())
        self.assertTrue((self.args['output'] / 'INCOMPLETE.json').exists())

    def test_receipt_publish_failure_restores_incomplete_diagnostic(self):
        plan = self.plan()
        with mock.patch.object(pack.os, 'rename', side_effect=OSError('authored publish failure')):
            with self.assertRaises(OSError):
                pack.stage(plan)
        self.assertFalse((self.args['output'] / 'assembly.json').exists())
        self.assertTrue((self.args['output'] / 'INCOMPLETE.json').exists())

    def test_mutation_inside_source_app_is_never_an_output_target(self):
        output = self.app / 'Contents/Resources/derived'
        with self.assertRaises(pack.PackageError):
            self.plan(output=output)
        self.assertFalse(output.exists())

    def test_duplicate_descriptor_and_boolean_protocol_are_refused(self):
        data = json.dumps(self.manifest).replace('"protocolVersion": 1', '"protocolVersion": 1,"protocolVersion": 1')
        self.template.write_text(data)
        with self.assertRaises(pack.PackageError):
            self.plan()
        self.manifest['sharedApplication']['protocolVersion'] = True
        self.template.write_text(json.dumps(self.manifest))
        with self.assertRaises(pack.PackageError):
            self.plan()

    def test_metadata_and_manifest_bounds_refuse_without_output(self):
        self.template.write_bytes(b' ' * 8193)
        with self.assertRaises(pack.PackageError):
            self.plan()
        self.assertFalse(self.args['output'].exists())


    def isolated_roles(self):
        values = dict(module_identifier=pack.SERVICE_ID,
                      service_identifier='cafe.nero.voice.isolated074',
                      connector_identifier='cafe.nero.connector.voice.isolated074')
        self.manifest['sharedApplication']['serviceIdentifier'] = values['service_identifier']
        self.manifest['sharedApplication']['connectorBundleIdentifier'] = values['connector_identifier']
        self.template.write_text(json.dumps(self.manifest))
        self.args.update(values)
        return values

    def test_distinct_native_roles_stage_full_resources_without_relabeling_module(self):
        identities = self.isolated_roles()
        plan = self.plan()
        before = pack.tree_digest(pack.scan(self.app)[0])
        receipt = pack.stage(plan)
        output = self.args['output']
        service = plistlib.loads((output / 'Nero Voice.app/Contents/Info.plist').read_bytes())
        connector = plistlib.loads((output / 'Nero Voice Module.app/Contents/Info.plist').read_bytes())
        manifest = json.loads((output / 'Nero Voice Module.app/Contents/Resources/NookPlugin.json').read_text())
        self.assertEqual(service['CFBundleIdentifier'], identities['service_identifier'])
        self.assertEqual(connector['CFBundleIdentifier'], identities['connector_identifier'])
        self.assertEqual(manifest['id'], pack.SERVICE_ID)
        self.assertEqual(manifest['sharedApplication']['serviceIdentifier'], identities['service_identifier'])
        self.assertEqual(manifest['sharedApplication']['connectorBundleIdentifier'], identities['connector_identifier'])
        self.assertEqual(receipt['identityComposition'], dict(module=pack.SERVICE_ID,
                         service=identities['service_identifier'], connector=identities['connector_identifier']))
        self.assertEqual(before, pack.tree_digest(pack.scan(self.app)[0]))
        for app in ('Nero Voice.app', 'Nero Voice Module.app'):
            self.assertEqual((output / app / 'Contents/Resources/Views/index.html').read_bytes(), b'authored view')
        self.assertFalse((output / 'Nero Voice Module.app/Contents/Helpers').exists())

    def test_explicit_roles_cannot_silently_override_template_identity(self):
        self.args['service_identifier'] = 'cafe.nero.voice.isolated074'
        self.args['connector_identifier'] = 'cafe.nero.connector.voice.isolated074'
        with self.assertRaises(pack.PackageError):
            self.plan()
        self.assertFalse(self.args['output'].exists())
        self.isolated_roles()
        self.args['module_identifier'] = 'different.logical.module'
        with self.assertRaises(pack.PackageError):
            self.plan()
        self.assertFalse(self.args['output'].exists())

    def test_invalid_or_colliding_identity_inputs_refuse_before_output(self):
        baseline = dict(self.args)
        invalid = ['', 'One.Upper', 'a..b', 'a/../b', 'a.' + 'b' * 100, 'a.\x00b', 'a.\ud800', None, True]
        for name in ('service_identifier', 'connector_identifier', 'module_identifier'):
            for value in invalid:
                with self.subTest(name=name, value=repr(value)):
                    self.args = dict(baseline, **{name: value})
                    with self.assertRaises(pack.PackageError):
                        self.plan()
                    self.assertFalse(self.args['output'].exists())
        self.args = dict(baseline, connector_identifier=pack.SERVICE_ID)
        with self.assertRaises(pack.PackageError):
            self.plan()
        self.assertFalse(self.args['output'].exists())

    def test_target_service_identity_does_not_reinterpret_resource_base_role(self):
        identities = self.isolated_roles()
        self.info['CFBundleIdentifier'] = identities['service_identifier']
        self.put(self.app / 'Contents/Info.plist', plistlib.dumps(self.info))
        with self.assertRaises(pack.PackageError):
            self.plan()
        self.assertFalse(self.args['output'].exists())


if __name__ == '__main__':
    unittest.main()
