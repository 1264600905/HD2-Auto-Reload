-- Read the actual addon context through a READ-ONLY external process handle.
-- Never loads the addon entry point, installs callbacks, or sends input.
-- Usage: luajit scripts/read_live_context.lua PID GAME_BASE [samples]
local ffi = require('ffi')
ffi.cdef[[
void *OpenProcess(uint32_t, int, uint32_t);
int ReadProcessMemory(void *, const void *, void *, size_t, size_t *);
int CloseHandle(void *);
uint32_t GetLastError(void);
void Sleep(uint32_t);
]]
local kernel = ffi.load('kernel32')
local handle = assert(kernel.OpenProcess(0x1010, 0, assert(tonumber(arg[1]))))
assert(handle ~= nil, 'OpenProcess failed')
local game = assert(tonumber(arg[2]))
local api = {}
function api.read(address, size)
    assert(address >= 65536 and address + size < 0x800000000000 and size > 0 and size <= 4096)
    local buffer, count = ffi.new('uint8_t[?]',size), ffi.new('size_t[1]')
    if kernel.ReadProcessMemory(handle, ffi.cast('void *', address), buffer, size, count) == 0 or
        tonumber(count[0]) ~= size then
        print(string.format('READ_FAILED address=0x%X size=%d error=%d',address,size,tonumber(kernel.GetLastError())))
        return nil
    end
    return ffi.string(buffer,size)
end
function api.pointer(bytes)
    if not bytes or #bytes < 8 then return nil end
    local value = ffi.new('uint64_t[1]'); ffi.copy(value,bytes,8)
    local n = tonumber(value[0]); if n >= 65536 and n < 0x800000000000 then return n end
end
local function readfile(path)
    local file=assert(io.open(path,'rb'));local value=file:read('*a');file:close();return value
end
local source = readfile('build/auto_reload_entry.lua')
local reader_code = assert(source:match('(local bit =.-)\nlocal api, game'))
local maps = assert(source:match('(%-%- Embedded by scripts/build.py.-)\nlocal function snapshot'))
local factory = assert(loadstring(reader_code .. '\n' .. maps .. '\nreturn context_reader, verify_layout'))
setfenv(factory, setmetatable({unsafe_resources={['11c27d3babb38956']=true}, emit=print}, {__index=_G}))
local reader, verify_layout = factory()
local ok, why = pcall(function()
    local pe_offset = ffi.new('uint32_t[1]'); ffi.copy(pe_offset,assert(api.read(game+0x3c,4)),4)
    local header = assert(api.read(game+tonumber(pe_offset[0]),0x60))
    local function word(offset)
        local n=ffi.new('uint32_t[1]');ffi.copy(n,header:sub(offset+1,offset+4),4);return tonumber(n[0])
    end
    assert(word(8)==0x6aa96b14 and word(0x50)==0x4770000,'unsupported_game_build')
    verify_layout(api, game)
    for i=1,tonumber(arg[3]) or 1 do
        local success,row,reason=pcall(reader,api,game)
        if success and row then
            local fields={}
            for _,name in ipairs({'context_status','selected_slot','selected_entity_id','current_weapon_resource',
                'ammo_path','ammo_status','heat_verified','heat_overheated','heat_requires_replacement',
                'heat_spares','heat_value_bits','heat_config_source','magazine_count','rounds_magazine_count','memory_reads','memory_bytes'}) do
                fields[#fields+1]=name..'='..tostring(row[name])
            end
            print(table.concat(fields,' '))
        else print('CONTEXT_ERROR '..tostring(success and reason or row)) end
        if i < (tonumber(arg[3]) or 1) then kernel.Sleep(1000) end
    end
end)
kernel.CloseHandle(handle)
assert(ok,why)
