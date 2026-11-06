#!/usr/bin/env python3
"""Plan or stage shared Voice bundle data. Never builds, signs, launches or installs."""
import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat

SERVICE_ID = 'cafe.nero.plugin.voice'
CONNECTOR_ID = 'cafe.nero.connector.voice'
MAX_BYTES = 256 * 1024 * 1024
MAX_FILES = 4096
MAX_ENTRIES = 8192
MAX_PATH = 1024
PRIVACY = ('NSMicrophoneUsageDescription', 'NSAudioCaptureUsageDescription', 'NSSpeechRecognitionUsageDescription')


class PackageError(ValueError):
    pass


def physical(path):
    raw=os.fspath(path)
    try:
        raw.encode('utf-8')
    except UnicodeError as error:
        raise PackageError('Paths must have exact UTF-8 names.') from error
    path = Path(raw)
    if not path.is_absolute() or any(part in ('.','..') for part in raw.split('/')):
        raise PackageError('Use an absolute physical path without dot components.')
    return path


def _parent(path):
    """Retain each directory while opening its child without following links."""
    path = physical(path)
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    lineage = []
    try:
        for part in path.parts[1:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
            value = os.fstat(fd)
            lineage.append((value.st_dev, value.st_ino, value.st_mode))
        return fd, path.name, tuple(lineage)
    except BaseException:
        os.close(fd)
        raise


def _identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_size, value.st_mtime_ns, value.st_ctime_ns)


@dataclass(frozen=True)
class File:
    path: Path
    size: int
    sha256: str
    executable: bool
    identity: tuple
    lineage: tuple


def read_file(path, maximum=MAX_BYTES, expected=None, sink=None):
    parent, name, lineage = _parent(path)
    fd = None
    try:
        before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or not 0 <= before.st_size <= maximum:
            raise PackageError('Expected one bounded, unlinked regular file: ' + str(path))
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        opened = os.fstat(fd)
        if _identity(opened) != _identity(before):
            raise PackageError('Input changed before open.')
        if expected and (_identity(opened) != expected.identity or lineage != expected.lineage):
            raise PackageError('Input or its physical ancestors changed since planning.')
        digest, chunks, count = hashlib.sha256(), [], 0
        while True:
            chunk = os.read(fd, min(1024 * 1024, maximum + 1 - count))
            if not chunk:
                break
            count += len(chunk)
            if count > maximum or count > before.st_size:
                raise PackageError('Input grew beyond its declared bound.')
            digest.update(chunk)
            if sink:
                sink(chunk)
            else:
                chunks.append(chunk)
        after = os.fstat(fd)
        named = os.stat(name, dir_fd=parent, follow_symlinks=False)
        fresh, fresh_name, fresh_lineage = _parent(path)
        try:
            fresh_named = os.stat(fresh_name, dir_fd=fresh, follow_symlinks=False)
        finally:
            os.close(fresh)
        if (count != before.st_size or _identity(after) != _identity(before)
                or _identity(named) != _identity(before) or _identity(fresh_named) != _identity(before)
                or fresh_lineage != lineage):
            raise PackageError('Input or its physical ancestors changed during reading.')
        value = digest.hexdigest()
        if expected and value != expected.sha256:
            raise PackageError('Input digest changed since planning.')
        record = File(Path(path), count, value, bool(before.st_mode & 0o111), _identity(before), lineage)
        return record, b''.join(chunks)
    finally:
        if fd is not None:
            os.close(fd)
        os.close(parent)


def open_directory(path):
    if physical(path) == Path('/'):
        return os.open('/',os.O_RDONLY | os.O_DIRECTORY)
    parent, name, lineage = _parent(path)
    try:
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        value = os.fstat(fd)
        if not stat.S_ISDIR(value.st_mode):
            os.close(fd)
            raise PackageError('Expected a physical directory.')
        return fd
    finally:
        os.close(parent)


def scan(root):
    files, directories, entries, total = {}, set(), 0, 0
    root_fd = open_directory(root)
    try:
        def visit(fd, relative, depth):
            nonlocal entries, total
            if depth > 32:
                raise PackageError('Resource nesting exceeds its limit.')
            with os.scandir(fd) as iterator:
                for entry in iterator:
                    entries += 1
                    if entries > MAX_ENTRIES:
                        raise PackageError('Too many input entries.')
                    rel = relative + '/' + entry.name if relative else entry.name
                    try:
                        encoded=rel.encode('utf-8')
                    except UnicodeError as error:
                        raise PackageError('Resource paths must be exact UTF-8.') from error
                    if len(encoded) > MAX_PATH:
                        raise PackageError('Resource path exceeds its limit.')
                    value = os.stat(entry.name, dir_fd=fd, follow_symlinks=False)
                    if stat.S_ISDIR(value.st_mode):
                        child = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                        try:
                            if _identity(os.fstat(child)) != _identity(value):
                                raise PackageError('Input directory changed.')
                            directories.add(rel)
                            visit(child, rel, depth + 1)
                        finally:
                            os.close(child)
                    elif stat.S_ISREG(value.st_mode):
                        if len(files) >= MAX_FILES or total + value.st_size > MAX_BYTES:
                            raise PackageError('Input app exceeds its bounded package size.')
                        record, _ = read_file(Path(root) / rel, sink=lambda _: None)
                        if record.identity != _identity(value):
                            raise PackageError('Input leaf changed between physical walk and read.')
                        files[rel] = record
                        total += record.size
                    else:
                        raise PackageError('Links and special input files are unsupported.')
        visit(root_fd, '', 0)
        fresh=open_directory(root)
        try:
            if _identity(os.fstat(fresh))[:3] != _identity(os.fstat(root_fd))[:3]:
                raise PackageError('Input root identity changed during inventory.')
        finally:
            os.close(fresh)
        return files, directories
    finally:
        os.close(root_fd)


def tree_digest(files):
    digest = hashlib.sha256()
    for name, file in sorted(files.items(), key=lambda item: os.fsencode(item[0])):
        digest.update(os.fsencode(name) + b'\0' + bytes.fromhex(file.sha256) + b'\0')
    return digest.hexdigest()


def views_digest(files):
    prefix = 'Contents/Resources/Views/'
    selected = {name[len(prefix):]: value for name, value in files.items() if name.startswith(prefix)}
    return bounded_views_digest(selected)


def bounded_views_digest(selected):
    if not selected or len(selected) > 256 or sum(value.size for value in selected.values()) > 16 * 1024 * 1024:
        raise PackageError('Views exceed the paired service bounds.')
    if any(value.size > 2 * 1024 * 1024 for value in selected.values()):
        raise PackageError('One view exceeds the paired service bound.')
    return tree_digest(selected)


@dataclass
class Plan:
    output: Path
    files: dict
    generated: dict
    receipt: dict

    def summary(self):
        return dict(self.receipt, mode='read-only-plan', output=str(self.output),
                    filesToStage=len(self.files) + len(self.generated),
                    bytesToStage=sum(f.size for f in self.files.values()) + sum(len(b) for b in self.generated.values()))


def _unique_pairs(pairs):
    result={}
    for key,value in pairs:
        if key in result:
            raise PackageError('Duplicate manifest JSON member.')
        result[key]=value
    return result


def _native_identifier(value):
    # Same lower-ASCII bounded component spelling as the native SDK policy.
    return (type(value) is str and len(value) <= 100
            and re.fullmatch(r'[a-z][a-z0-9]*(?:\.[a-z][a-z0-9-]*)+', value) is not None)


def make_plan(resource_app, service_binary, connector_binary, template, output, version, build,
              service_sha256, connector_sha256, sdk_resources, sdk_sha256, views_resources, views_sha256,
              service_identifier=SERVICE_ID, connector_identifier=CONNECTOR_ID, module_identifier=SERVICE_ID):
    if (not all(_native_identifier(value) for value in (service_identifier, connector_identifier, module_identifier))
            or connector_identifier in (service_identifier, module_identifier)):
        raise PackageError('Provide distinct bounded native service/connector identities and a reviewed logical module identity.')
    output = physical(output)
    parent_fd = open_directory(output.parent)
    try:
        try:
            os.stat(output.name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise PackageError('Output already exists; it was preserved.')
    finally:
        os.close(parent_fd)
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or not re.fullmatch(r'[1-9][0-9]{0,8}', build):
        raise PackageError('Use a three-part version and positive bounded build number.')
    if any(not re.fullmatch(r'[0-9a-f]{64}', pin) for pin in (service_sha256, connector_sha256,sdk_sha256,views_sha256)):
        raise PackageError('Provide exact lowercase SHA-256 pins from the qualified build receipts.')
    resource_app = physical(resource_app)
    sdk_resources=physical(sdk_resources)
    sdk_files,_=scan(sdk_resources)
    if (not sdk_files or tree_digest(sdk_files) != sdk_sha256
            or not any(Path(name).name == 'shared-application-v1.schema.json' for name in sdk_files)):
        raise PackageError('Select the exact pinned compiled SDK resource bundle, including shared schema.')
    views_resources=physical(views_resources)
    view_files,_=scan(views_resources)
    revision=bounded_views_digest(view_files)
    if revision != views_sha256:
        raise PackageError('Select the exact pinned Views from the qualified source build.')
    for source in (resource_app,sdk_resources,views_resources,physical(service_binary),physical(connector_binary),physical(template)):
        if output == source or output.is_relative_to(source):
            raise PackageError('Output cannot be inside a source input; source bytes are preserved.')
    files, directories = scan(resource_app)
    children = {name.split('/')[1] for name in set(files) | directories if name.startswith('Contents/')}
    if any(not name.startswith('Contents/') and name != 'Contents' for name in set(files) | directories):
        raise PackageError('Unsupported app shell outside Contents.')
    if children - {'Info.plist', 'Resources', 'Helpers', 'MacOS', '_CodeSignature', 'PkgInfo'}:
        raise PackageError('Unsupported app shell dependency (including Frameworks); no dependency was silently dropped.')
    if {name for name in files if name.startswith('Contents/MacOS/')} != {'Contents/MacOS/ModuleApp'}:
        raise PackageError('Unsupported executable shell.')
    required = ['Contents/Info.plist', 'Contents/MacOS/ModuleApp', 'Contents/Helpers/NeroASR',
                'Contents/Helpers/mlx.metallib', 'Contents/Resources/Speech/apple_voice.swift',
                'Contents/Resources/speaker-runtime.tar.gz']
    required += ['Contents/Resources/Models/' + name + '.json' for name in ('qwen-tts', 'qwen-base', 'qwen-design')]
    required += ['Contents/Resources/Licenses/' + name + '.txt' for name in
                 ('speaker-model', 'parakeet-model', 'mlx-swift', 'mlx-audio-swift', 'qwen-tts', 'nemotron-models')]
    if any(name not in files or files[name].size == 0 for name in required):
        raise PackageError('Prebuilt app is missing required worker, model recipes, speech or license resources.')
    for prefix in ('Contents/Resources/Views/', 'Contents/Resources/NookPluginSDK_NookPluginSDK.bundle/',
                   'Contents/Resources/NemotronSpeakers/'):
        if not any(name.startswith(prefix) for name in files):
            raise PackageError('Prebuilt app lacks required resource subtree: ' + prefix)
    if not files['Contents/Helpers/NeroASR'].executable or not files['Contents/MacOS/ModuleApp'].executable:
        raise PackageError('Prebuilt app executable modes are missing.')
    _, info_bytes = read_file(resource_app / 'Contents/Info.plist', maximum=65536,
                              expected=files['Contents/Info.plist'])
    info = plistlib.loads(info_bytes)
    if not isinstance(info, dict) or info.get('CFBundleIdentifier') != SERVICE_ID or info.get('CFBundleExecutable') != 'ModuleApp':
        raise PackageError('Prebuilt worker/resource app has the wrong role identity.')
    if any(not isinstance(info.get(key), str) or not 0 < len(info[key].encode()) <= 2048 for key in PRIVACY):
        raise PackageError('Prebuilt app lacks bounded explicit privacy usage text.')
    service, _ = read_file(physical(service_binary), maximum=128 * 1024 * 1024, sink=lambda _: None)
    connector, _ = read_file(physical(connector_binary), maximum=128 * 1024 * 1024, sink=lambda _: None)
    if (not service.executable or not connector.executable or not service.size or not connector.size
            or service.sha256 != service_sha256 or connector.sha256 != connector_sha256
            or service.sha256 == connector.sha256):
        raise PackageError('Executable byte pins or executable modes do not match.')
    _, template_bytes = read_file(physical(template), maximum=8192)
    manifest = json.loads(template_bytes,object_pairs_hook=_unique_pairs)
    if not isinstance(manifest,dict) or not isinstance(manifest.get('sharedApplication'),dict):
        raise PackageError('Expected a shared manifest object.')
    descriptor = manifest['sharedApplication']
    if (manifest.get('id') != module_identifier or manifest.get('launchMode') != 'sharedApplication'
            or type(manifest.get('apiVersion')) is not int or manifest['apiVersion'] != 1 or manifest.get('version') != '__VERSION__'
            or set(descriptor) != {'protocolVersion', 'connectorBundleIdentifier', 'serviceIdentifier', 'resourceRevision'}
            or type(descriptor.get('protocolVersion')) is not int or descriptor['protocolVersion'] != 1 or descriptor.get('connectorBundleIdentifier') != connector_identifier
            or descriptor.get('serviceIdentifier') != service_identifier or descriptor.get('resourceRevision') != '__VIEWS_REVISION__'):
        raise PackageError('Unsupported shared manifest template.')
    manifest['version'] = version
    descriptor['resourceRevision'] = revision
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode()
    if len(manifest_bytes) > 8192:
        raise PackageError('Generated manifest exceeds the host limit.')
    service_name, module_name = 'Nero Voice.app', 'Nero Voice Module.app'
    selected = {}
    for name, record in files.items():
        if (name.startswith(('Contents/Resources/', 'Contents/Helpers/')) and name != 'Contents/Resources/NookPlugin.json'
                and not name.startswith(('Contents/Resources/NookPluginSDK_NookPluginSDK.bundle/', 'Contents/Resources/Views/'))):
            selected[service_name + '/' + name] = record
        if name.startswith('Contents/Resources/Licenses/'):
            selected[module_name + '/' + name] = record
    for app in (service_name,module_name):
        for name,record in view_files.items():
            selected[app+'/Contents/Resources/Views/'+name]=record
        for name,record in sdk_files.items():
            selected[app+'/Contents/Resources/NookPluginSDK_NookPluginSDK.bundle/'+name]=record
    selected[service_name + '/Contents/MacOS/ModuleApp'] = service
    selected[module_name + '/Contents/MacOS/VoiceConnector'] = connector
    common = dict(CFBundlePackageType='APPL', CFBundleShortVersionString=version, CFBundleVersion=build,
                  LSUIElement=True, LSMinimumSystemVersion='26.0', NSHighResolutionCapable=True)
    service_info = dict(common, CFBundleIdentifier=service_identifier, CFBundleName='Nero Voice',
                        CFBundleDisplayName='Nero Voice', CFBundleExecutable='ModuleApp',
                        NeroVoiceRuntimeKind='shared-service-v1', **{key: info[key] for key in PRIVACY})
    module_info = dict(common, CFBundleIdentifier=connector_identifier, CFBundleName='Nero Voice Module',
                       CFBundleDisplayName='Nero Voice Module', CFBundleExecutable='VoiceConnector')
    icon = info.get('CFBundleIconFile')
    if icon:
        if not isinstance(icon, str) or '/' in icon or '..' in icon or not any('Contents/Resources/'+name in files for name in (icon,icon+'.icns')):
            raise PackageError('Unsupported prebuilt app icon reference.')
        service_info['CFBundleIconFile'] = icon
    generated = {service_name + '/Contents/Info.plist': plistlib.dumps(service_info),
                 module_name + '/Contents/Info.plist': plistlib.dumps(module_info),
                 module_name + '/Contents/Resources/NookPlugin.json': manifest_bytes}
    for app in (service_name, module_name):
        own = [record for name, record in selected.items() if name.startswith(app + '/')]
        data = [value for name, value in generated.items() if name.startswith(app + '/')]
        names=[name[len(app)+1:] for name in set(selected)|set(generated) if name.startswith(app+'/')]
        dirs={str(parent) for name in names for parent in Path(name).parents if str(parent) != '.'}
        if (len(own) + len(data) > MAX_FILES or len(names)+len(dirs)>MAX_ENTRIES
                or sum(f.size for f in own) + sum(map(len, data)) > MAX_BYTES):
            raise PackageError('Staged app would exceed the host package bound.')
    receipt = dict(formatVersion=1, status='stage-data-only-not-signed-or-native-verified', version=version,
                   build=build, viewsRevision=revision, sourceResourceApp=str(resource_app),
                   sourceResourceTreeSHA256=tree_digest(files),
                   binaryPins={'service': service.sha256, 'connector': connector.sha256},
                   identityComposition={'module':module_identifier,'service':service_identifier,'connector':connector_identifier},
                   compiledSDKTreeSHA256=sdk_sha256,compiledSDKResources=str(sdk_resources),
                   qualifiedViewsTreeSHA256=views_sha256,qualifiedViewsResources=str(views_resources),
                   provenance='Caller byte pins require an independent join to actual qualified build receipts; fixtures prove assembly only.')
    return Plan(output, selected, generated, receipt)


def _write(root_fd, relative, mode, producer):
    parts = relative.split('/')
    if any(part in ('', '.', '..') for part in parts):
        raise PackageError('Invalid generated relative path.')
    fd = os.dup(root_fd)
    leaf = None
    try:
        for part in parts[:-1]:
            try:
                os.mkdir(part, 0o700, dir_fd=fd)
            except FileExistsError:
                pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        leaf = os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=fd)
        def sink(data):
            view = memoryview(data)
            while view:
                count = os.write(leaf, view)
                if count <= 0:
                    raise PackageError('Staged write did not progress.')
                view = view[count:]
        producer(sink)
        os.fsync(leaf)
    finally:
        if leaf is not None:
            os.close(leaf)
        os.close(fd)


def stage(plan):
    parent_fd = open_directory(plan.output.parent)
    root_fd = None
    try:
        available=os.fstatvfs(parent_fd)
        if available.f_bavail*available.f_frsize < plan.summary()['bytesToStage']+16*1024*1024:
            raise PackageError('Insufficient space for this bounded data stage; output preserved.')
        # Atomic reservation; never rename over, remove or replace a prior output.
        os.mkdir(plan.output.name, 0o700, dir_fd=parent_fd)
        root_fd = os.open(plan.output.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
        root_identity = _identity(os.fstat(root_fd))[:2]
        _write(root_fd, 'INCOMPLETE.json', 0o600,
               lambda sink: sink(b'{"status":"incomplete-stage; preserve for diagnosis"}\n'))
        for name, record in plan.files.items():
            _write(root_fd, name, 0o755 if record.executable else 0o644,
                   lambda sink, record=record: read_file(record.path, expected=record, sink=sink))
        for name, data in plan.generated.items():
            _write(root_fd, name, 0o644, lambda sink, data=data: sink(data))
        if _identity(os.stat(plan.output.name, dir_fd=parent_fd, follow_symlinks=False))[:2] != root_identity:
            raise PackageError('Output directory identity changed.')
        observed = {}
        for app in ('Nero Voice.app', 'Nero Voice Module.app'):
            records, _ = scan(plan.output / app)
            observed[app] = dict(files=len(records), bytes=sum(f.size for f in records.values()),
                                 assemblyTreeSHA256=tree_digest(records))
            if views_digest(records) != plan.receipt['viewsRevision']:
                raise PackageError('Paired staged Views changed.')
            expected_names={name[len(app)+1:] for name in set(plan.files)|set(plan.generated) if name.startswith(app+'/')}
            if set(records) != expected_names:
                raise PackageError('Staged file inventory differs from the reviewed plan.')
            for relative, record in records.items():
                name = app + '/' + relative
                expected = plan.files.get(name)
                digest = expected.sha256 if expected else hashlib.sha256(plan.generated[name]).hexdigest()
                if digest != record.sha256 or record.executable != (expected.executable if expected else False):
                    raise PackageError('Staged bytes differ from the reviewed plan.')
        actual_root=open_directory(plan.output)
        try:
            if _identity(os.fstat(actual_root))[:2] != root_identity:
                raise PackageError('Physical output ancestors changed.')
        finally:
            os.close(actual_root)
        receipt = dict(plan.receipt, mode='stage-only', apps=observed)
        data = (json.dumps(receipt, indent=2) + '\n').encode()
        # Complete every fallible flush before publishing the success name.
        # This is ordinary command ordering, not a power-loss/installer promise.
        _write(root_fd, '.assembly-pending.json', 0o600, lambda sink: sink(data))
        os.fsync(root_fd)
        try:
            os.stat('assembly.json',dir_fd=root_fd,follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise PackageError('Unexpected existing stage receipt was preserved.')
        os.unlink('INCOMPLETE.json', dir_fd=root_fd)
        try:
            os.rename('.assembly-pending.json','assembly.json',src_dir_fd=root_fd,dst_dir_fd=root_fd)
        except BaseException:
            _write(root_fd,'INCOMPLETE.json',0o600,lambda sink:sink(b'{"status":"receipt publication failed; preserve stage"}\n'))
            raise
        return receipt
    finally:
        if root_fd is not None:
            os.close(root_fd)
        os.close(parent_fd)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resource-app', required=True, )
    parser.add_argument('--service-binary', required=True, )
    parser.add_argument('--connector-binary', required=True, )
    parser.add_argument('--service-sha256', required=True)
    parser.add_argument('--connector-sha256', required=True)
    parser.add_argument('--sdk-resources',required=True)
    parser.add_argument('--sdk-sha256',required=True)
    parser.add_argument('--views-resources',required=True)
    parser.add_argument('--views-sha256',required=True)
    parser.add_argument('--template', default=Path(__file__).resolve().parents[1] / 'Resources/SharedNookPlugin.template.json')
    parser.add_argument('--output', required=True, )
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--service-identifier', default=SERVICE_ID)
    parser.add_argument('--connector-identifier', default=CONNECTOR_ID)
    parser.add_argument('--module-identifier', default=SERVICE_ID)
    parser.add_argument('--stage-only', action='store_true')
    args = parser.parse_args(argv)
    plan = make_plan(args.resource_app, args.service_binary, args.connector_binary, args.template,
                     args.output, args.version, args.build, args.service_sha256, args.connector_sha256,
                     args.sdk_resources,args.sdk_sha256,args.views_resources,args.views_sha256,
                     service_identifier=args.service_identifier,connector_identifier=args.connector_identifier,
                     module_identifier=args.module_identifier)
    print(json.dumps(stage(plan) if args.stage_only else plan.summary(), indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        raise SystemExit('Shared Voice staging refused: ' + str(error))
