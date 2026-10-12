"""Capture ammo context from a running Helldivers 2 process, read-only.

Uses the existing guarded Lua reader in the game's lua51.dll, loaded into this
Python process. Never installs an addon callback or sends game input.
"""
import argparse
import ctypes as c
from ctypes import wintypes as w
from pathlib import Path

from export_live_weapon_catalog import module_base


ROOT = Path(__file__).resolve().parents[1]


class ProcessEntry(c.Structure):
    _fields_ = [('size', w.DWORD), ('usage', w.DWORD), ('pid', w.DWORD),
                ('heap', c.c_size_t), ('module', w.DWORD), ('threads', w.DWORD),
                ('parent', w.DWORD), ('priority', w.LONG), ('flags', w.DWORD),
                ('name', w.WCHAR * 260)]


def find_game(kernel):
    kernel.CreateToolhelp32Snapshot.argtypes = [w.DWORD, w.DWORD]
    kernel.CreateToolhelp32Snapshot.restype = w.HANDLE
    kernel.Process32FirstW.argtypes = [w.HANDLE, c.POINTER(ProcessEntry)]
    kernel.Process32NextW.argtypes = [w.HANDLE, c.POINTER(ProcessEntry)]
    snapshot = kernel.CreateToolhelp32Snapshot(2, 0)
    if snapshot == c.c_void_p(-1).value:
        raise c.WinError(c.get_last_error())
    try:
        entry = ProcessEntry(size=c.sizeof(ProcessEntry))
        found = []
        ok = kernel.Process32FirstW(snapshot, c.byref(entry))
        while ok:
            if entry.name.lower() == 'helldivers2.exe':
                found.append(entry.pid)
            ok = kernel.Process32NextW(snapshot, c.byref(entry))
    finally:
        kernel.CloseHandle(snapshot)
    if len(found) != 1:
        raise RuntimeError('Expected one running helldivers2.exe; start the game or specify --pid')
    return found[0]


def run_reader(dll_path, arguments):
    def lua_string(value):
        return '"' + ''.join('\\%03d' % byte for byte in str(value).encode('utf-8')) + '"'

    # Arguments are Lua literals, never interpolated as shell commands.
    chunk = ('local output = {}\n'
             'print = function(...) local fields = {} '
             'for i = 1, select("#", ...) do fields[#fields+1] = tostring((select(i, ...))) end '
             'output[#output+1] = table.concat(fields, " ") end\n'
             'arg = {' + ','.join(lua_string(value) for value in arguments) + '}\n'
             'local ok, why = pcall(dofile, ' + lua_string(ROOT / 'scripts/read_live_context.lua') + ')\n'
             'if not ok then error(tostring(why), 0) end\n'
             'return table.concat(output, "\\n")').encode('utf-8')
    dll = c.CDLL(str(dll_path))
    dll.luaL_newstate.restype = c.c_void_p
    dll.luaL_openlibs.argtypes = [c.c_void_p]
    dll.luaL_loadbuffer.argtypes = [c.c_void_p, c.c_char_p, c.c_size_t, c.c_char_p]
    dll.lua_pcall.argtypes = [c.c_void_p, c.c_int, c.c_int, c.c_int]
    dll.lua_tolstring.argtypes = [c.c_void_p, c.c_int, c.c_void_p]
    dll.lua_tolstring.restype = c.c_char_p
    dll.lua_close.argtypes = [c.c_void_p]
    state = dll.luaL_newstate()
    if not state:
        raise RuntimeError('Could not create the external Lua reader state')
    try:
        dll.luaL_openlibs(state)
        status = dll.luaL_loadbuffer(state, chunk, len(chunk), b'=read_only_reload_capture')
        if not status:
            status = dll.lua_pcall(state, 0, 1, 0)
        message = dll.lua_tolstring(state, -1, None)
        message = message.decode('utf-8', errors='replace') if message else ''
        if status:
            raise RuntimeError(message)
        return message
    finally:
        dll.lua_close(state)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, help='Auto-detected when omitted')
    parser.add_argument('--samples', type=int, default=300)
    parser.add_argument('--interval-ms', type=int, default=100)
    parser.add_argument('--entry', type=Path, default=ROOT / 'build/auto_reload_entry.lua')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/reload-context-v0.6.9.log')
    args = parser.parse_args()
    if not 1 <= args.samples <= 100000 or not 10 <= args.interval_ms <= 60000:
        parser.error('samples must be 1..100000 and interval-ms must be 10..60000')
    if not args.entry.is_file():
        parser.error('Build the addon before capturing its context')
    kernel = c.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    kernel.OpenProcess.restype = w.HANDLE
    kernel.CloseHandle.argtypes = [w.HANDLE]
    psapi = c.WinDLL('psapi', use_last_error=True)
    psapi.EnumProcessModulesEx.argtypes = [w.HANDLE, c.POINTER(w.HMODULE), w.DWORD, c.POINTER(w.DWORD), w.DWORD]
    psapi.GetModuleFileNameExW.argtypes = [w.HANDLE, w.HMODULE, w.LPWSTR, w.DWORD]
    pid = args.pid if args.pid is not None else find_game(kernel)
    handle = kernel.OpenProcess(0x1010, False, pid)
    if not handle:
        raise c.WinError(c.get_last_error())
    try:
        base, game_dll = module_base(psapi, handle, '\\game.dll')
    finally:
        kernel.CloseHandle(handle)
    lua_dll = game_dll.parents[2] / 'bin/lua51.dll'
    print(f'Capturing read-only: pid={pid} samples={args.samples} interval_ms={args.interval_ms}', flush=True)
    result = run_reader(lua_dll, [pid, base, args.samples, args.interval_ms, args.entry.resolve()])
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(f'READ_ONLY_CAPTURE pid={pid} base={base:#x} entry={args.entry.resolve()}\n' + result + '\n',
                      encoding='utf-8')
    print('Saved', output)


if __name__ == '__main__':
    main()
