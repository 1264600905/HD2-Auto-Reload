"""Plaintext Bingus Shared Loader addon archive and deterministic ZIP packaging."""
import json
from pathlib import Path
import re
import struct
import uuid
import zipfile

ARCHIVE = '9ba626afa44a3aa3.patch_0'
LUA_TYPE = 0xA14E8DFA2CD117E2


def resource_hash(name):
    data = name.encode('utf-8')
    mask, mix = (1 << 64) - 1, 0xC6A4A7935BD1E995
    value = len(data) * mix & mask
    end = len(data) // 8 * 8
    for (word,) in struct.iter_unpack('<Q', data[:end]):
        word = word * mix & mask
        word ^= word >> 47
        value = (value ^ (word * mix & mask)) * mix & mask
    if data[end:]:
        value = (value ^ int.from_bytes(data[end:], 'little')) * mix & mask
    value ^= value >> 47
    value = value * mix & mask
    return value ^ (value >> 47)


def build_addon(name, source, guid, output, display_name):
    if not re.fullmatch(r'mods/[A-Za-z0-9_]+/[A-Za-z0-9_/]+', name):
        raise ValueError('Invalid addon resource name')
    source.decode('utf-8')
    if source.startswith((b'\xef\xbb\xbf', b'\x1b')) or b'\0' in source:
        raise ValueError('Source must be plaintext UTF-8 without BOM or NUL')
    marker = ('-- HD2-Addon: ' + name).encode()
    if source.startswith(b'-- HD2-Addon:'):
        first, sep, source = source.partition(b'\n')
        if not sep or first.rstrip(b'\r') != marker:
            raise ValueError('Addon declaration mismatch')
    body = marker + b'\n' + source
    payload = struct.pack('<II', len(body), 2) + body
    offset = 192  # 104-byte header/type plus one 80-byte entry, aligned to 16.
    total = (offset + len(payload) + 15) & ~15
    header = struct.pack('<III20sQQ24s', 0xF0000011, 1, 1, b'', total, 0, b'')
    types = struct.pack('<IIQIIII', 0, 0, LUA_TYPE, 1, 0, 16, 16)
    entry = struct.pack('<7Q6I', resource_hash(name), LUA_TYPE, offset, 0, 0, 0, 0,
                        len(payload), 0, 0, 16, 16, 0)
    archive = (header + types + entry).ljust(offset, b'\0') + payload
    archive = archive.ljust(total, b'\0')
    description = 'Requires Bingus Shared Loader v15+ / API 1. Enable both and deploy.'
    manifest = {'Version': 1, 'Guid': str(uuid.UUID(guid)), 'Name': display_name,
                'Description': description, 'Options': [{'Name': display_name,
                'Description': description, 'Include': ['Addon']}]}
    files = {'manifest.json': (json.dumps(manifest, indent=2) + '\n').encode(),
             'Addon/' + ARCHIVE: archive, 'Addon/' + ARCHIVE + '.stream': b'',
             'Addon/' + ARCHIVE + '.gpu_resources': b''}
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w') as package:
        for path, data in sorted(files.items()):
            info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            package.writestr(info, data)
    return output
