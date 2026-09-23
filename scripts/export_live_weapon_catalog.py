"""Export verified live ammo-component resource IDs and known display names.

Reads only the three build-25327279 resource/index maps from the running game.
No game memory is written, and no game function is called.
"""

import argparse
import csv
import ctypes as c
from ctypes import wintypes as w
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import urllib.request

from package import resource_hash


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_DLL_SHA256 = "73374bd4e38386beb9a23bef480082b67d457ebc77485fbec5f488b4e95e201f"
NAME_SOURCE_REVISION = "721d6b58906bdd28c61582e661da1515b44a6869"
NAME_SOURCE_URL = (
    "https://raw.githubusercontent.com/Darctor/Helldivers2_RawData/"
    + NAME_SOURCE_REVISION + "/Data/Hash.csv"
)
PATH_SOURCE_REVISION = "697fdc2dbc5ede3c5be09ccd6615758d3d1cbfdc"
PATH_SOURCE_URL = (
    "https://raw.githubusercontent.com/xypwn/filediver/"
    + PATH_SOURCE_REVISION + "/hashes/hashes.txt"
)
MAPS = (
    ("WeaponMagazine", "weapon_magazine", 0xF124A0, 540),
    ("WeaponRounds", "weapon_rounds", 0xF12820, 50),
    ("WeaponHeat", "weapon_heat", 0xF12CC8, 58),
)
UNSAFE_RESOURCE = "11c27d3babb38956"
PROJECT_NAMES = {"006e44327bb953fe": "GL-15 Evictor"}


def module_base(psapi, handle, suffix):
    modules = (w.HMODULE * 2048)()
    needed = w.DWORD()
    if not psapi.EnumProcessModulesEx(handle, modules, c.sizeof(modules), c.byref(needed), 3):
        raise c.WinError(c.get_last_error())
    if needed.value > c.sizeof(modules):
        raise RuntimeError("module list too long")
    for module in modules[: needed.value // c.sizeof(w.HMODULE)]:
        path = c.create_unicode_buffer(32768)
        if psapi.GetModuleFileNameExW(handle, module, path, len(path)) and path.value.lower().endswith(suffix):
            return c.cast(module, c.c_void_p).value, Path(path.value)
    raise RuntimeError("game.dll is not loaded")


def read_names(path):
    if path:
        data = path.read_bytes()
        source = str(path)
    else:
        request = urllib.request.Request(NAME_SOURCE_URL, headers={"User-Agent": "HD2-Auto-Reload-Research"})
        with urllib.request.urlopen(request, timeout=20) as response:
            data = response.read()
        source = NAME_SOURCE_URL
    names = {}
    for row in csv.DictReader(io.StringIO(data.decode("utf-8-sig"))):
        if row["row_type"] != "entry":
            continue
        digits = re.sub(r"[^0-9]", "", row["hash"])
        if digits:
            key = f"{int(digits):016x}"
            if key in names:
                raise RuntimeError(f"duplicate name hash: {key}")
            names[key] = row
    return names, source, hashlib.sha256(data).hexdigest()


def read_paths(path, wanted):
    if path:
        data = path.read_bytes()
        source = str(path)
    else:
        request = urllib.request.Request(PATH_SOURCE_URL, headers={"User-Agent": "HD2-Auto-Reload-Research"})
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read()
        source = PATH_SOURCE_URL
    paths = {}
    for line in data.decode("utf-8-sig").splitlines():
        candidate = line.strip()
        if not candidate or candidate.startswith("//"):
            continue
        key = f"{resource_hash(candidate):016x}"
        if key in wanted:
            if key in paths and paths[key] != candidate:
                raise RuntimeError(f"ambiguous resource path for {key}")
            paths[key] = candidate
    return paths, source, hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True, help="Running helldivers2.exe PID")
    parser.add_argument("--names", type=Path, help="Optional local Hash.csv; default is pinned upstream revision")
    parser.add_argument("--paths", type=Path, help="Optional local hashes.txt; default is pinned filediver revision")
    parser.add_argument("--output", type=Path, default=ROOT / "build/live_weapon_catalog.json")
    args = parser.parse_args()

    kernel = c.WinDLL("kernel32", use_last_error=True)
    psapi = c.WinDLL("psapi", use_last_error=True)
    kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    kernel.OpenProcess.restype = w.HANDLE
    kernel.ReadProcessMemory.argtypes = [w.HANDLE, c.c_void_p, c.c_void_p, c.c_size_t, c.POINTER(c.c_size_t)]
    kernel.ReadProcessMemory.restype = w.BOOL
    kernel.CloseHandle.argtypes = [w.HANDLE]
    psapi.EnumProcessModulesEx.argtypes = [w.HANDLE, c.POINTER(w.HMODULE), w.DWORD, c.POINTER(w.DWORD), w.DWORD]
    psapi.EnumProcessModulesEx.restype = w.BOOL
    psapi.GetModuleFileNameExW.argtypes = [w.HANDLE, w.HMODULE, w.LPWSTR, w.DWORD]
    psapi.GetModuleFileNameExW.restype = w.DWORD

    handle = kernel.OpenProcess(0x1010, False, args.pid)  # query + VM_READ
    if not handle:
        raise c.WinError(c.get_last_error())
    try:
        base, dll = module_base(psapi, handle, "\\game.dll")
        actual_sha = hashlib.sha256(dll.read_bytes()).hexdigest()
        if actual_sha != EXPECTED_DLL_SHA256:
            raise RuntimeError(f"unsupported game.dll SHA256: {actual_sha}")

        def read(address, size):
            if not (0x10000 <= address < 0x800000000000 and 0 < size <= 0x10000):
                raise RuntimeError("invalid read address or size")
            buffer = c.create_string_buffer(size)
            count = c.c_size_t()
            if not kernel.ReadProcessMemory(handle, c.c_void_p(address), buffer, size, c.byref(count)):
                raise c.WinError(c.get_last_error())
            if count.value != size:
                raise RuntimeError(f"short read at 0x{address:x}")
            return buffer.raw

        def pointer(address):
            value = struct.unpack("<Q", read(address, 8))[0]
            if not 0x10000 <= value < 0x800000000000:
                raise RuntimeError(f"invalid pointer at 0x{address:x}")
            return value

        pe_offset = struct.unpack("<I", read(base + 0x3C, 4))[0]
        pe_header = read(base + pe_offset, 0x60)
        if struct.unpack_from("<I", pe_header, 8)[0] != 0x6AA96B14 or struct.unpack_from("<I", pe_header, 0x50)[0] != 0x4770000:
            raise RuntimeError("live PE identity mismatch")
        owner = pointer(base + 0x346BF98)
        names, name_source, name_sha = read_names(args.names)
        rows = []
        map_sha = {}
        for component, ammo_path, slot, entries in MAPS:
            live = read(pointer(owner + slot), entries * 16)
            expected_path = ROOT / f"data/{component}Component.25327279.map.hex"
            expected = bytes.fromhex(expected_path.read_text(encoding="ascii"))
            if live != expected:
                raise RuntimeError(f"live {component} map differs from {expected_path.name}")
            map_sha[component] = hashlib.sha256(live).hexdigest()
            for offset in range(0, len(live), 16):
                key, index, unused = struct.unpack_from("<QII", live, offset)
                if not key:
                    continue
                if index >= entries:
                    raise RuntimeError(f"invalid {component} record index")
                key_hex = f"{key:016x}"
                match = names.get(key_hex, {})
                project_name = PROJECT_NAMES.get(key_hex, "")
                rows.append({
                    "resource_id": key_hex,
                    "name_en": match.get("name", project_name),
                    "name_zh": match.get("name_zh", ""),
                    "name_category": match.get("category", ""),
                    "component": component,
                    "ammo_path": ammo_path,
                    "record_index": index,
                    "name_status": "matched_hash_csv" if match else "project_comment" if project_name else "unresolved",
                    "mod_status": "skip_reported_crash" if key_hex == UNSAFE_RESOURCE else "reader_path_available",
                })
        keys = [row["resource_id"] for row in rows]
        if len(keys) != len(set(keys)):
            raise RuntimeError("resource appears in more than one ammo component map")
        paths, path_source, path_sha = read_paths(args.paths, set(keys))
        for row in rows:
            row["resource_path"] = paths.get(row["resource_id"], "")
        rows.sort(key=lambda row: (row["component"], row["name_en"] or "~", row["resource_id"]))
        output = {
            "metadata": {
                "extracted_at_utc": datetime.now(timezone.utc).isoformat(),
                "pid": args.pid,
                "game_dll_sha256": actual_sha,
                "game_build": 25327279,
                "live_maps_sha256": map_sha,
                "name_source": name_source,
                "name_source_sha256": name_sha,
                "name_source_note": "Community-maintained names; matches are exact resource hashes, not proof of player availability or reload behavior.",
                "path_source": path_source,
                "path_source_sha256": path_sha,
            },
            "rows": rows,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"EXPORTED rows={len(rows)} named={sum(row['name_status'] != 'unresolved' for row in rows)} "
              f"paths={len(paths)} output={args.output}")
    finally:
        kernel.CloseHandle(handle)


if __name__ == "__main__":
    main()
