"""Read-only, current-macOS Swift loader dependency gate. Never runs the worker.

This deliberately supports the current thin Mach-O worker and OS-provided Swift
@rpath dependencies only. An unsupported layout refuses packaging rather than
copying arbitrary developer libraries or claiming minimum-OS compatibility.
"""
import ctypes
import hashlib
import os
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import struct
import subprocess
import tempfile

MAX_BINARY = 256 * 1024 * 1024
MAX_COMMANDS = 4096
MAX_METADATA = 512 * 1024
LOADS = {'LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB', 'LC_LOAD_UPWARD_DYLIB'}


class DependencyError(ValueError):
    pass


def system_path(path):
    return (path.startswith('/usr/lib/') or path.startswith('/System/Library/')) and str(PurePosixPath(path)) == path and '..' not in PurePosixPath(path).parts


def parse_load_commands(text):
    if not isinstance(text, str) or len(text.encode('utf-8')) > MAX_METADATA or '\x00' in text:
        raise DependencyError('Invalid or oversized otool metadata')
    blocks = re.split(r'^Load command (\d+)\s*$', text, flags=re.MULTILINE)
    if len(blocks) < 3 or (len(blocks)-1)//2 > MAX_COMMANDS:
        raise DependencyError('Missing or excessive load commands')
    rpaths, loads, minimum, linker = [], [], None, None
    for index in range(1, len(blocks), 2):
        if int(blocks[index]) != (index-1)//2:
            raise DependencyError('Nonsequential or multiple-architecture load commands')
        body = blocks[index+1]
        commands = re.findall(r'^\s*cmd (\S+)\s*$', body, re.MULTILINE)
        if len(commands) != 1:
            raise DependencyError('Malformed load command')
        command = commands[0]
        if command == 'LC_RPATH' or command in LOADS:
            field = 'path' if command == 'LC_RPATH' else 'name'
            values = re.findall(r'^\s*'+field+r' (.+) \(offset \d+\)\s*$', body, re.MULTILINE)
            if len(values) != 1 or len(values[0].encode()) > 4096 or any(ord(c) < 32 for c in values[0]):
                raise DependencyError('Malformed loader path')
            if command == 'LC_RPATH':
                rpaths.append(values[0])
            else:
                loads.append({'command': command, 'name': values[0]})
        elif command == 'LC_LOAD_DYLINKER':
            values = re.findall(r'^\s*name (.+) \(offset \d+\)\s*$', body, re.MULTILINE)
            if values != ['/usr/lib/dyld'] or linker is not None:
                raise DependencyError('Unsupported or duplicate dynamic linker')
            linker = values[0]
        elif command == 'LC_BUILD_VERSION':
            p = re.findall(r'^\s*platform (\S+)\s*$', body, re.MULTILINE)
            m = re.findall(r'^\s*minos (\d+\.\d+(?:\.\d+)?)\s*$', body, re.MULTILINE)
            if p not in (['1'], ['MACOS']) or len(m) != 1 or minimum is not None:
                raise DependencyError('Missing or non-macOS build version')
            minimum = m[0]
        elif command.startswith('LC_LOAD_') or command in {'LC_ID_DYLIB', 'LC_LAZY_LOAD_DYLIB'}:
            raise DependencyError('Unsupported executable loader command: '+command)
    if minimum is None or not loads or linker is None:
        raise DependencyError('Missing macOS deployment target, system linker or dependencies')
    return {'rpaths': rpaths, 'loads': loads, 'workerMinimumMacOS': minimum, 'dynamicLinker': linker}


def evaluate(metadata, cache_contains):
    evidence = []
    for load in metadata['loads']:
        name = load['name']
        if system_path(name):
            if cache_contains(name):
                evidence.append(dict(load, provider='dyld-shared-cache', resolvedPath=name))
            elif load['command'] == 'LC_LOAD_WEAK_DYLIB':
                evidence.append(dict(load, provider='optional-unavailable'))
            else:
                raise DependencyError('Required system dependency has no verified OS cache provider: '+name)
            continue
        if not re.fullmatch(r'@rpath/libswift[A-Za-z0-9_]+\.dylib', name):
            raise DependencyError('Unsupported non-system dependency: '+name)
        provider = None
        for rpath in metadata['rpaths']:
            candidate = rpath+'/'+name[len('@rpath/'):]
            # A developer/bundle path before the verified system provider could
            # shadow it. Do not silently assume that path is missing/benign.
            if not system_path(candidate):
                raise DependencyError('Non-system rpath precedes verified OS provider: '+rpath)
            if cache_contains(candidate):
                provider = candidate
                break
        if provider is None:
            if load['command'] == 'LC_LOAD_WEAK_DYLIB':
                evidence.append(dict(load, provider='optional-unavailable'))
                continue
            raise DependencyError('Required Swift dependency has no verified OS cache provider: '+name)
        evidence.append(dict(load, provider='dyld-shared-cache', resolvedPath=provider))
    return evidence


def cache_probe():
    # Inspect the already loaded process's dyld API. Never dlopen the target
    # dylib, ASR executable, MLX or any framework to answer this question.
    symbol = getattr(ctypes.CDLL(None), '_dyld_shared_cache_contains_path', None)
    if symbol is None:
        raise DependencyError('Current OS cannot provide non-executing cache evidence')
    symbol.argtypes, symbol.restype = [ctypes.c_char_p], ctypes.c_bool
    return lambda path: bool(symbol(path.encode('utf-8')))


def snapshot(worker):
    fd = os.open(worker, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or not 32 <= before.st_size <= MAX_BINARY or before.st_nlink != 1:
            raise DependencyError('Worker must be a bounded, singly linked regular file')
        header = os.read(fd, 32)
        if header[:4] != b'\xcf\xfa\xed\xfe' or struct.unpack('<I', header[12:16])[0] != 2:
            raise DependencyError('Only a thin little-endian 64-bit Mach-O executable is supported')
        architecture = {0x100000c: 'arm64', 0x1000007: 'x86_64'}.get(struct.unpack('<I', header[4:8])[0])
        if architecture is None:
            raise DependencyError('Unsupported Mach-O architecture')
        digest = hashlib.sha256(header)
        total = len(header)
        while True:
            block = os.read(fd, min(1024*1024, MAX_BINARY+1-total))
            if not block:
                break
            total += len(block)
            if total > MAX_BINARY:
                raise DependencyError('Worker grew beyond limit')
            digest.update(block)
        after = os.fstat(fd)
        key = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if key(before) != key(after) or total != after.st_size:
            raise DependencyError('Worker changed during read')
        return {'sha256': digest.hexdigest(), 'size': total, 'architecture': architecture, 'identity': list(key(after))}
    finally:
        os.close(fd)


def inspect(worker, minimum_macos='26.0'):
    worker = Path(worker)
    current = platform.mac_ver()[0]
    version = lambda v: tuple(int(x) for x in v.split('.'))
    if platform.system() != 'Darwin' or not current or version(current) < version(minimum_macos):
        raise DependencyError('Audit requires a Mac at or above the app minimum')
    before = snapshot(worker)
    if before['architecture'] != platform.machine():
        raise DependencyError('Current shared-cache evidence cannot validate a different worker architecture')
    # Trusted Apple inspector only; it parses data and does not launch worker.
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        result = subprocess.run(['/usr/bin/otool', '-l', str(worker)], stdout=out, stderr=err, timeout=15, check=False)
        out.seek(0); raw = out.read(MAX_METADATA+1)
        err.seek(0); error = err.read(MAX_METADATA+1)
    if result.returncode != 0 or len(raw) > MAX_METADATA or len(error) > MAX_METADATA:
        raise DependencyError('otool failed or metadata exceeded limit')
    try:
        metadata = parse_load_commands(raw.decode('utf-8', errors='strict'))
    except UnicodeError as exc:
        raise DependencyError('Non-UTF8 load metadata') from exc
    providers = evaluate(metadata, cache_probe())
    if snapshot(worker) != before:
        raise DependencyError('Worker changed across metadata audit')
    # Distributed resource must not publish arbitrary developer/home rpaths.
    public_metadata = dict(metadata, rpaths=[p if system_path(p+'/library.dylib') else '<non-system-rpath>' for p in metadata['rpaths']])
    public_worker = {k: v for k, v in before.items() if k != 'identity'}
    return {'schemaVersion': 1, 'phase': 'stripped worker before codesigning', 'scope': 'current-OS direct Swift external dependency audit; no target execution',
            'minimumOSCompatibilityVerified': False, 'appMinimumMacOS': minimum_macos,
            'auditMacOS': current, 'auditArchitecture': platform.machine(), 'worker': public_worker,
            'otoolMetadataSha256': hashlib.sha256(raw).hexdigest(), **public_metadata, 'providers': providers}
