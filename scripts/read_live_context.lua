-- Read the actual addon context through a READ-ONLY external process handle.
-- Never loads the addon entry point, installs callbacks, or sends input.
-- Usage: luajit scripts/read_live_context.lua PID GAME_BASE [samples] [interval_ms] [entry] [dry-run]
-- dry-run evaluates the real controller with a print-only input stub.
local ffi = require('ffi')
ffi.cdef[[
void *OpenProcess(uint32_t, int, uint32_t);
int ReadProcessMemory(void *, const void *, void *, size_t, size_t *);
int CloseHandle(void *);
uint32_t GetLastError(void);
void Sleep(uint32_t);
uint64_t GetTickCount64(void);
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
local samples, interval = tonumber(arg[3]) or 1, tonumber(arg[4]) or 1000
assert(samples >= 1 and samples <= 100000 and interval >= 10 and interval <= 60000)
local source = readfile(arg[5] or 'build/auto_reload_entry.lua')
local reader_code = assert(source:match('(local bit =.-)\nlocal api, game'))
local maps = assert(source:match('(%-%- Embedded by scripts/build.py.-)\nlocal function snapshot'))
local factory = assert(loadstring(reader_code .. '\n' .. maps .. '\nreturn context_reader, verify_layout, verify_build'))
setfenv(factory, setmetatable({unsafe_resources={['11c27d3babb38956']=true}, emit=print}, {__index=_G}))
local reader, verify_layout, verify_build = factory()
local state, step, continuous
if arg[6] == 'dry-run' then
    state = {elapsed=0, ticks=0, keys={}}
    api.game_focused = function() return true end
    api.own_reload_active = function() return false end
    api.send_reload = function()
        print('DRY_RUN_WOULD_REQUEST_R no_input_sent=true')
        return true, 'dry_run_print_only'
    end
    local policies = assert(source:match('(local CONTINUOUS_RELOAD_INTERVAL_SECONDS =.-)\nlocal state ='))
    local controller = assert(source:match('(local function truly_empty.-)\nemit%(%\'START'))
    local simulation = assert(loadstring(policies .. '\n' .. controller .. '\nreturn auto_reload_step, continuous_reload_step'))
    setfenv(simulation, setmetatable({state=state, api=api, game=game, bit=require('bit'),
        context_reader=reader, unsafe_resources={}, scalar=tostring,
        debug_emit=function() end, emit=function(line) print('DRY_RUN '..line) end}, {__index=_G}))
    step, continuous = simulation()
end
local ok, why = pcall(function()
    local pe_offset = ffi.new('uint32_t[1]'); ffi.copy(pe_offset,assert(api.read(game+0x3c,4)),4)
    local header = assert(api.read(game+tonumber(pe_offset[0]),0x60))
    verify_build(header)
    verify_layout(api, game)
    local start = tonumber(kernel.GetTickCount64())
    for i=1,samples do
        local success,row,reason=pcall(reader,api,game)
        if success and row then
            local fields={}
            for _,name in ipairs({'context_status','selected_slot','selected_entity_id','current_weapon_resource',
                'weapon_context','seat_entity_id','seat_type','seat_role','seat_index',
                'ammo_path','ammo_status','heat_verified','heat_overheated','heat_requires_replacement',
                'heat_spares','heat_value_bits','heat_config_source','magazine_count','magazine_chamber_token',
                'rounds_magazine_count','rounds_chamber_token','rounds_chambered','memory_reads','memory_bytes'}) do
                fields[#fields+1]=name..'='..tostring(row[name])
            end
            print(table.concat(fields,' '))
        else print('CONTEXT_ERROR '..tostring(success and reason or row)) end
        if state then
            state.elapsed = (tonumber(kernel.GetTickCount64()) - start) / 1000
            state.ticks = i
            state.latest_row = success and row or nil
            state.latest_at = state.elapsed
            step(); continuous()
        end
        if i < samples then kernel.Sleep(interval) end
    end
end)
kernel.CloseHandle(handle)
assert(ok,why)
