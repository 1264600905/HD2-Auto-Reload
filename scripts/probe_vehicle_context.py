"""Read-only seat and weapon observations for live reload investigation.

Never writes game memory, invokes game functions, or sends input. Output is
limited to seat fields, entity identifiers, and ammunition counters.
"""
import argparse
import ctypes as c
from ctypes import wintypes as w
import json
import struct
import time

from export_live_weapon_catalog import module_base


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--samples', type=int, default=1)
    parser.add_argument('--interval', type=float, default=0.2)
    parser.add_argument('--all-owned', action='store_true', help='Include other locally owned driver entities')
    args = parser.parse_args()
    kernel = c.WinDLL('kernel32', use_last_error=True)
    psapi = c.WinDLL('psapi', use_last_error=True)
    kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    kernel.OpenProcess.restype = w.HANDLE
    kernel.ReadProcessMemory.argtypes = [w.HANDLE, c.c_void_p, c.c_void_p, c.c_size_t, c.POINTER(c.c_size_t)]
    kernel.CloseHandle.argtypes = [w.HANDLE]
    psapi.EnumProcessModulesEx.argtypes = [w.HANDLE, c.POINTER(w.HMODULE), w.DWORD, c.POINTER(w.DWORD), w.DWORD]
    psapi.GetModuleFileNameExW.argtypes = [w.HANDLE, w.HMODULE, w.LPWSTR, w.DWORD]
    handle = kernel.OpenProcess(0x1010, False, args.pid)
    if not handle:
        raise c.WinError(c.get_last_error())

    def read(address, size):
        assert 0x10000 <= address < 0x800000000000 and 0 < size <= 32768
        buffer, count = c.create_string_buffer(size), c.c_size_t()
        if not kernel.ReadProcessMemory(handle, address, buffer, size, c.byref(count)):
            raise c.WinError(c.get_last_error())
        assert count.value == size
        return buffer.raw

    def u32(address):
        return struct.unpack('<I', read(address, 4))[0]

    def pointer(address):
        value = struct.unpack('<Q', read(address, 8))[0]
        assert 0x10000 <= value < 0x800000000000
        return value

    def lookup(address, key):
        table, count, empty, multiplier = struct.unpack('<QIII', read(address, 20))
        assert count <= 1048576 and (not count or count & (count - 1) == 0)
        if key in (empty, 0xffffffff):
            return None
        for probe in range(min(count, 128)):
            found, index = struct.unpack('<II', read(table + (((key * multiplier) & 0xffffffff) + probe) % count * 8, 8))
            if found == key:
                return index if index != 0xffffffff else None
            if found == empty:
                return None
        return None

    try:
        base, _ = module_base(psapi, handle, '\\game.dll')
        pe = read(base + u32(base + 0x3c), 0x60)
        assert (struct.unpack_from('<I', pe, 8)[0], struct.unpack_from('<I', pe, 0x50)[0]) in (
            (0x6aa96b14, 0x4770000), (0x6ab3b43f, 0x4744000))
        previous = None
        for sample in range(args.samples):
            owner = pointer(base + 0x346bf98)
            player = pointer(base + 0x3326468)
            unit = u32(player + 0x3a8)
            avatar_index = lookup(owner + 0xf22ec8, unit)
            assert avatar_index is not None
            avatar = read(owner + 0xf32f18 + avatar_index * 24, 24)
            avatar_id = struct.unpack_from('<I', avatar, 8)[0]
            result = {'avatar': avatar_id}
            wield = pointer(base + 0x3326420)
            wield_index = lookup(wield + 0x30, avatar_id)
            if wield_index is not None:
                assert wield_index < 4096
                slots = pointer(wield + 0x60) + wield_index * 0x1d0
                result['wield_slots'] = [struct.unpack('<II', read(slots + slot * 0x50, 8)) for slot in range(2)]
            seater = pointer(base + 0x3326d78)
            index = lookup(seater + 0x20, avatar_id)
            if index is not None:
                assert index < u32(seater + 0x10) <= 256
                seat = read(pointer(seater + 0x48) + index * 64, 64)
                seat_id, seat_type, role = struct.unpack_from('<III', seat)
                result['seat'] = {'entity': seat_id, 'type': seat_type, 'role': role,
                                  'index': struct.unpack_from('<I', seat, 0x14)[0],
                                  'transition': struct.unpack_from('<I', seat, 0x30)[0]}
            driver = pointer(base + 0x3326660)
            count = u32(driver + 0x14)
            assert count < 4096
            registry = pointer(driver + 0x40)
            weapons = []
            for i in range(count):
                weapon = read(pointer(registry + i * 8), 24)
                if not weapon[20] & 1:
                    continue
                resource, entity_id = struct.unpack_from('<QI', weapon)
                if not args.all_owned and resource not in (
                    0x05d8d8c073b9d502, 0x1fa1f596769225c2, 0xd58ae6a04edb10de, 0xdf51fe8d62f294be):
                    continue
                weapon_row = {'resource': f'{resource:016x}', 'entity': entity_id}
                for label, global_rva, map_offset, data_offset, stride in (
                    ('magazine', 0x3326648, 0x20, 0x48, 16),
                    ('rounds', 0x3326cf0, 0x28, 0x50, 24)):
                    manager = pointer(base + global_rva)
                    ammo_index = lookup(manager + map_offset, entity_id)
                    if ammo_index is not None:
                        assert ammo_index < 4096
                        values = struct.unpack('<' + 'I' * (stride // 4), read(pointer(manager + data_offset) + ammo_index * stride, stride))
                        weapon_row[label] = values
                weapons.append(weapon_row)
            result['owned_weapons'] = weapons
            encoded = json.dumps(result, separators=(',', ':'))
            if encoded != previous:
                print(json.dumps({'sample': sample, 'seconds': round(sample * args.interval, 2), **result}), flush=True)
                previous = encoded
            if sample + 1 < args.samples:
                time.sleep(args.interval)
    finally:
        kernel.CloseHandle(handle)


if __name__ == '__main__':
    main()
