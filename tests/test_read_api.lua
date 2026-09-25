local ffi = require('ffi')
if ffi.os ~= 'Windows' then
    print('SKIP Windows input API initialization')
    return
end
if arg[1] == 'existing-declaration' then
    ffi.cdef('uint32_t __stdcall SendInput(uint32_t, const uint8_t *, int);')
end
local source_file = assert(io.open('src/auto_reload.lua', 'rb'))
local source = source_file:read('*a')
source_file:close()
local code = assert(source:match('(local function read_api%(%).-)%\nlocal function context_reader'))
local factory = assert(loadstring(code .. '\nreturn read_api()'))
setfenv(factory, setmetatable({debug_emit=function() end, state={ticks=0,elapsed=0},
    bit=require('bit')}, {__index=_G}))
local api = factory()
assert(api.module('user32.dll'))
assert(not api.own_reload_active())
print('PASS Windows API initialization without input: ' .. (arg[1] or 'fresh-declarations'))
