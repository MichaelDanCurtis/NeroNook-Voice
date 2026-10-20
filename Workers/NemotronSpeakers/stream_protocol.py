"""Bounded, source-scoped PCM framing. Pure stdlib; no capture or model loading."""
import json
import math
import struct


def read_exact(source, count):
    data = bytearray()
    while len(data) < count:
        block = source.read(count - len(data))
        if not block:
            raise ValueError('Speaker input closed without finalization')
        data.extend(block)
    return bytes(data)


def packets(source):
    while True:
        size = struct.unpack('<I', read_exact(source, 4))[0]
        if size == 0:
            return
        if size > 1024:
            raise ValueError('Speaker header limit')
        header = json.loads(read_exact(source, size))
        track, start, count = header.get('track'), header.get('start'), header.get('length')
        if track not in ('mic', 'system') or isinstance(start, bool) or not isinstance(start, (int, float)) or not math.isfinite(start) or start < 0:
            raise ValueError('Invalid speaker source or clock')
        if isinstance(count, bool) or not isinstance(count, int) or count <= 0 or count > 65536 or count % 4 or start + count / 64000 > 14430:
            raise ValueError('Invalid speaker PCM size')
        yield track, start, read_exact(source, count)


def emit(output, **message):
    data = json.dumps(message, allow_nan=False, separators=(',', ':')).encode()
    if len(data) > 131000:
        raise ValueError('Speaker output limit')
    output.write(data + b'\n')
    output.flush()
