"""Read-only inspection of a loaded game module; never writes or executes game code.

Requires pefile and capstone (supply their location through PYTHONPATH).
Only requested instruction bytes and module metadata are printed, never a dump.
"""
import argparse
import ctypes as c
from ctypes import wintypes as w
import hashlib
from pathlib import Path
import re
import struct

import capstone
import pefile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', required=True, type=Path)
    parser.add_argument('--pid', required=True, type=int)
    parser.add_argument('--base', required=True, type=lambda s: int(s, 0))
    parser.add_argument('--start', type=lambda s: int(s, 0))
    parser.add_argument('--size', default=0x200, type=lambda s: int(s, 0))
    parser.add_argument('--find', action='append', help='Hex instruction pattern; ?? matches one byte')
    parser.add_argument('--calls', type=lambda s: int(s, 0), help='Find direct call sites for a function RVA')
    parser.add_argument('--component-map', nargs=3, metavar=('OWNER_SLOT', 'ENTRIES', 'OUTPUT'),
                        help='Export only a verified resource-to-index map as hex (build 25327279)')
    args = parser.parse_args()
    raw = args.dll.read_bytes()
    pe = pefile.PE(data=raw)
    print(f'SHA256={hashlib.sha256(raw).hexdigest()} timestamp={pe.FILE_HEADER.TimeDateStamp:#x} image_size={pe.OPTIONAL_HEADER.SizeOfImage:#x}')
    kernel = c.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    kernel.OpenProcess.restype = w.HANDLE
    kernel.ReadProcessMemory.argtypes = [w.HANDLE, c.c_void_p, c.c_void_p, c.c_size_t, c.POINTER(c.c_size_t)]
    kernel.CloseHandle.argtypes = [w.HANDLE]
    handle = kernel.OpenProcess(0x1010, False, args.pid)
    if not handle:
        raise c.WinError(c.get_last_error())
    def read(rva, size):
        assert 0 <= rva < pe.OPTIONAL_HEADER.SizeOfImage and 0 < size <= pe.OPTIONAL_HEADER.SizeOfImage - rva
        buffer, count = c.create_string_buffer(size), c.c_size_t()
        if not kernel.ReadProcessMemory(handle, args.base + rva, buffer, size, c.byref(count)):
            raise c.WinError(c.get_last_error())
        assert count.value == size
        return buffer.raw
    try:
        if args.component_map:
            assert hashlib.sha256(raw).hexdigest() == '73374bd4e38386beb9a23bef480082b67d457ebc77485fbec5f488b4e95e201f'
            slot, entries, output = args.component_map
            slot, entries = int(slot, 0), int(entries, 0)
            assert (slot, entries) in {(0xf124a0, 540), (0xf12820, 50), (0xf12cc8, 58)}
            def external(address, size):
                buffer, count = c.create_string_buffer(size), c.c_size_t()
                if not kernel.ReadProcessMemory(handle, address, buffer, size, c.byref(count)):
                    raise c.WinError(c.get_last_error())
                assert count.value == size
                return buffer.raw
            owner = struct.unpack('<Q', read(0x346bf98, 8))[0]
            table = struct.unpack('<Q', external(owner + slot, 8))[0]
            data = external(table, entries * 16)
            for offset in range(0, len(data), 16):
                key, index, _ = struct.unpack_from('<QII', data, offset)
                assert not key or index < entries
            Path(output).write_text(data.hex() + '\n', encoding='ascii')
            print(f'EXPORTED component_map entries={entries} sha256={hashlib.sha256(data).hexdigest()} output={output}')
        if args.find or args.calls is not None:
            patterns = [(value, re.compile(b''.join(b'.' if token == '??' else re.escape(bytes.fromhex(token))
                         for token in value.split()), re.DOTALL)) for value in args.find or []]
            for section in pe.sections:
                if section.Characteristics & 0x20000000:
                    data = read(section.VirtualAddress, section.Misc_VirtualSize)
                    if args.calls is not None:
                        for match in re.finditer(b'\xe8', data):
                            offset = match.start()
                            if offset + 5 <= len(data) and section.VirtualAddress + offset + 5 + struct.unpack_from('<i', data, offset + 1)[0] == args.calls:
                                print(f'CALL {section.VirtualAddress + offset:#x}')
                    for value, pattern in patterns:
                        for match in pattern.finditer(data):
                            print(f'MATCH {section.VirtualAddress + match.start():#x} pattern={value}')
        if args.start is not None:
            assert args.size <= 0x4000
            code = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
            for ins in code.disasm(read(args.start, args.size), args.start):
                print(f'{ins.address:08x} {ins.bytes.hex():24s} {ins.mnemonic:8s} {ins.op_str}')
    finally:
        kernel.CloseHandle(handle)


if __name__ == '__main__':
    main()
