-- Exercise the actual controller functions with synthetic observations.
local file = assert(io.open('src/auto_reload.lua', 'rb'))
local source = file:read('*a'); file:close()
local controller = assert(source:match('(local function rounds_empty.-)\nemit%(%\'START'))
local policies = assert(source:match('(local CONTINUOUS_RELOAD_INTERVAL_SECONDS =.-)\nlocal state ='))
local tests = 0
local function scenario()
    local row = {context_status='context_observed', ammo_path='weapon_rounds',
        current_weapon_resource='safe', selected_entity_id=1, weapon_owned=true,
        rounds_magazine_count=0, rounds_chambered=false}
    local state = {elapsed=0, ticks=0, latest_row=row, latest_at=0, keys={}}
    local sent, logs, fresh, focused, own_down = 0, {}, row, true, false
    local api = {game_focused=function() return focused end,
        own_reload_active=function() return own_down end,
        send_reload=function() sent=sent+1; return true,'test' end}
    local factory = assert(loadstring(policies .. '\n' .. controller ..
        '\nreturn auto_reload_step, rounds_empty, continuous_reload_step'))
    setfenv(factory, setmetatable({RELOAD_DELAY_SECONDS=1, state=state, api=api, unsafe_resources={unsafe=true},
        context_reader=function() return fresh end,
        emit=function(s) logs[#logs+1]=s end, debug_emit=function() end,
        scalar=tostring}, {__index=_G}))
    local step, empty, continuous = factory()
    return {row=row, state=state, logs=logs, empty=empty, sent=function() return sent end,
        fresh=function(value) fresh=value end, focus=function(value) focused=value end,
        own_key=function(value) own_down=value end,
        step=function(t) state.elapsed=t; state.latest_at=t; step() end,
        continuous_step=function(t) state.elapsed=t; state.latest_at=t; step(); continuous() end}
end
local function test(name, fn)
    fn(); tests=tests+1; print('PASS ' .. name)
end
test('empty timer sends only once', function()
    local s=scenario(); s.step(0); s.step(.99); assert(s.sent()==0)
    s.step(1); s.step(7); assert(s.sent()==1)
end)
test('AMR requests at one magazine round and still works at zero', function()
    local s=scenario(); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.magazine_chamber_token=40
    s.row.current_weapon_resource='89c5493e08ca4207'
    s.row.magazine_count=2; assert(not s.empty(s.row))
    s.row.magazine_count=1; assert(s.empty(s.row))
    s.row.magazine_count=0; assert(s.empty(s.row))
    s.row.current_weapon_resource='ordinary'
    assert(not s.empty(s.row))
    s.row.magazine_chamber_token=0; assert(s.empty(s.row))
end)
test('R-36 requests at zero magazine rounds without a bolt check', function()
    local s=scenario(); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.current_weapon_resource='b6aff2195568767f'
    s.row.magazine_chamber_token=40
    s.row.magazine_count=1; assert(not s.empty(s.row))
    s.row.magazine_count=0; assert(s.empty(s.row))
end)
test('Sweeper and Evictor thresholds include a chambered round', function()
    local s=scenario(); s.row.rounds_chambered=true; s.row.rounds_chamber_token=297
    s.row.current_weapon_resource='dcd1c835407ef7ba'
    s.row.rounds_magazine_count=4; assert(not s.empty(s.row))
    s.row.rounds_magazine_count=3; assert(s.empty(s.row))
    s.row.current_weapon_resource='006e44327bb953fe'
    s.row.rounds_magazine_count=2; assert(not s.empty(s.row))
    s.row.rounds_magazine_count=1; assert(s.empty(s.row))
end)
test('continuous loading repeats at 0.1 seconds and records each request', function()
    local s=scenario(); s.row.current_weapon_resource='dcd1c835407ef7ba'
    s.row.rounds_chambered=true; s.row.rounds_chamber_token=297
    s.row.rounds_magazine_count=3
    s.continuous_step(0); assert(s.sent()==1)
    s.continuous_step(.05); assert(s.sent()==1)
    s.continuous_step(.11); assert(s.sent()==2)
    local log=table.concat(s.logs,'\n')
    assert(select(2,log:gsub('reason=continuous_load',''))==2)
end)
test('manual R and stale context suppress continuous loading', function()
    local s=scenario(); s.row.current_weapon_resource='006e44327bb953fe'
    s.row.rounds_chambered=true; s.row.rounds_chamber_token=297
    s.row.rounds_magazine_count=1; s.state.keys.R=true
    s.continuous_step(0); assert(s.sent()==0)
    s.state.keys.R=false; s.continuous_step(.2); assert(s.sent()==0)
    s.row.rounds_magazine_count=3; s.continuous_step(.3)
    s.row.rounds_magazine_count=1; s.fresh({}); s.continuous_step(.4); assert(s.sent()==0)
    s.fresh(s.row); s.continuous_step(.51); assert(s.sent()==1)
end)
test('our injected R does not suppress the next continuous request', function()
    local s=scenario(); s.row.current_weapon_resource='dcd1c835407ef7ba'
    s.row.rounds_chambered=true; s.row.rounds_chamber_token=297
    s.row.rounds_magazine_count=3
    s.continuous_step(0); assert(s.sent()==1)
    s.state.keys.R=true; s.own_key(true); s.continuous_step(.05)
    assert(s.sent()==1 and not s.state.manual_reload_episode)
    s.state.keys.R=false; s.own_key(false); s.continuous_step(.11)
    assert(s.sent()==2)
end)
test('held fire triggers after empty observation', function()
    local s=scenario(); s.state.keys.LMB=true; s.step(0); s.step(.16); assert(s.sent()==1)
end)
test('ready chamber and missing configuration do not authorize reload', function()
    local s=scenario(); s.row.rounds_chambered=true; s.row.rounds_chamber_token=259
    s.step(0); s.step(4); assert(s.sent()==0)
    s.row.rounds_chambered=nil; s.step(5); s.step(9); assert(s.sent()==0)
end)
test('stale attack before empty does not trigger', function()
    local s=scenario(); s.state.lmb_edge_time=.9; s.step(1); assert(s.sent()==0)
end)
test('fresh selection mismatch rejects stale request', function()
    local s=scenario(); s.step(0); s.fresh({}); s.step(3); assert(s.sent()==0)
end)
test('failed fresh read rejects request', function()
    local s=scenario(); s.step(0); s.fresh(nil); s.step(3); assert(s.sent()==0)
end)
test('focus, ownership, and manual R inhibit input', function()
    for _,mode in ipairs({'focus','owned','manual'}) do
        local s=scenario()
        if mode=='focus' then s.focus(false)
        elseif mode=='owned' then s.row.weapon_owned=false
        else s.state.keys.R=true end
        s.step(0); s.step(4); assert(s.sent()==0)
    end
end)
test('unsafe and unsupported ammo paths never send', function()
    for _,path in ipairs({'weapon_magazine','weapon_heat','weapon_resource'}) do
        local s=scenario(); s.row.ammo_path=path; s.step(0); s.step(4); assert(s.sent()==0)
    end
    local s=scenario(); s.row.current_weapon_resource='unsafe'; s.step(0); s.step(4); assert(s.sent()==0)
end)
test('verified magazine reload is independent of inventory slot', function()
    for _,slot in ipairs({1,2,3}) do
        local s=scenario(); s.row.selected_slot=slot; s.row.ammo_path='weapon_magazine'
        s.row.magazine_verified=true; s.row.magazine_count=0; s.row.magazine_chamber_token=0
        s.step(0); s.step(3); assert(s.sent()==1)
    end
end)
test('magazine last chamber round is preserved even when blocked', function()
    local s=scenario(); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.magazine_count=0; s.row.magazine_chamber_token=259; s.row.magazine_chamber_blocked=true
    s.step(0); s.step(4); assert(s.sent()==0)
    s.row.magazine_chamber_token=0; s.step(5); s.step(8); assert(s.sent()==1)
end)
test('magazine fresh refill cancels queued input', function()
    local s=scenario(); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.magazine_count=0; s.row.magazine_chamber_token=0; s.step(0)
    local fresh={}; for k,v in pairs(s.row) do fresh[k]=v end
    fresh.magazine_count=10; s.fresh(fresh); s.step(3); assert(s.sent()==0)
end)
test('native magazine reader validates entity and exact layout', function()
    local ffi=require('ffi')
    local function word(v) return ffi.string(ffi.new('uint32_t[1]',v),4) end
    local function u32(s,o) local v=ffi.new('uint32_t[1]'); ffi.copy(v,s:sub(o+1,o+4),4); return tonumber(v[0]) end
    local function unhex(s) return (s:gsub('..',function(p) return string.char(tonumber(p,16)) end)) end
    local function hex(s) return (s:gsub('.',function(c) return string.format('%02x',c:byte()) end)) end
    local memory={
        [0x100000+0x744d02]=unhex('488b2d3f19be02'),
        [0x100000+0x744d6c]=unhex('488b4d38488bdf48c1e30448035d48488b0cf9e8bce9daff80b89c000000007420488b4550488d0c7f807c880800750a837b08000f85b600000032c0e9b1000000833b000f9fc0e9a6000000'),
        [0x40000]=string.rep('W',24),
        [0x50000+2*16]=word(7)..word(99)..word(259)..word(0),
        [0x60000+2*12]=string.rep('\0',8)..'\1\0\0\0',
    }
    local pointers={[0x20000+0x38]=0x30000,[0x30000+2*8]=0x40000,
        [0x20000+0x48]=0x50000,[0x20000+0x50]=0x60000}
    local verified=true
    local chunk=assert(source:match('(local function read_magazine_component.-)\nlocal function context_reader'))
    local factory=assert(loadstring(chunk..'\nreturn read_magazine_component'))
    setfenv(factory,setmetatable({u32=u32,hex=hex,magazine_static_records=function()
        if verified then return {magazine=string.rep('\0',160)} end
    end},{__index=_G}))
    local reader=factory()
    local e={game=0x100000,weapon_id=42,weapon=string.rep('W',24),
        global=function(rva) assert(rva==0x3326648); return 0x20000 end,
        lookup=function(address,id) assert(address==0x20020 and id==42); return 2 end,
        pointer=function(address,guard) assert(guard); return assert(pointers[address]) end,
        read=function(address,size) local s=assert(memory[address]); assert(#s==size); return s end}
    local row={}; reader(e,row)
    assert(row.magazine_count==7 and row.magazine_chamber_token==259 and row.magazine_verified)
    assert(row.magazine_chamber_blocked and row.ammo_status=='ammo_present')
    memory[0x50000+32]=string.rep('\0',16); row={}; reader(e,row)
    assert(row.ammo_status=='magazine_and_chamber_empty')
    memory[0x40000]=string.rep('X',24); assert(not pcall(reader,e,{}))
    verified=false; row={}; reader(e,row); assert(not row.magazine_verified)
    assert(row.ammo_status=='magazine_static_identity_unverified')
end)
test('burned heat sink waits a full second even while firing', function()
    for _,slot in ipairs({1,2,3}) do
        local s=scenario(); s.row.ammo_path='weapon_heat'; s.row.selected_slot=slot
        s.row.heat_verified=true; s.row.heat_requires_replacement=true; s.row.heat_overheated=true
        s.state.keys.LMB=true; s.state.lmb_edge_time=0
        s.step(0); s.step(.16); s.step(.99); assert(s.sent()==0)
        s.step(1); s.step(5); assert(s.sent()==1)
    end
end)

test('normal heat, cooling lock and unverified heat never trigger', function()
    for _,field in ipairs({'heat_overheated','heat_requires_replacement','heat_verified'}) do
        local s=scenario(); s.row.ammo_path='weapon_heat'
        s.row.heat_verified=true; s.row.heat_requires_replacement=true; s.row.heat_overheated=true
        s.row[field]=false; s.state.keys.LMB=true; s.step(0); s.step(4); assert(s.sent()==0)
    end
end)

test('heat fresh unlock and entity reuse cancel pending request', function()
    for _,field in ipairs({'heat_overheated','heat_verified','_weapon_bytes','selected_slot'}) do
        local s=scenario(); s.row.ammo_path='weapon_heat'; s.row._weapon_bytes='identity A'
        s.row.heat_verified=true; s.row.heat_requires_replacement=true; s.row.heat_overheated=true
        s.step(0)
        local fresh={}; for k,v in pairs(s.row) do fresh[k]=v end
        fresh[field]=false; s.fresh(fresh); s.step(2); assert(s.sent()==0)
    end
end)

test('manual heat replacement suppresses duplicate automatic request after key release', function()
    local s=scenario(); s.row.ammo_path='weapon_heat'
    s.row.heat_verified=true; s.row.heat_requires_replacement=true; s.row.heat_overheated=true
    s.step(0); s.state.keys.R=true; s.step(.5); s.state.keys.R=false
    s.step(2); s.step(5); assert(s.sent()==0)
    s.state.lmb_edge_time=6; s.step(6); assert(s.sent()==1)
end)

test('heat unlock rearms next episode without claiming confirmed reload', function()
    local s=scenario(); s.row.ammo_path='weapon_heat'
    s.row.heat_verified=true; s.row.heat_requires_replacement=true; s.row.heat_overheated=true
    s.step(0); s.step(1); assert(s.sent()==1)
    s.row.heat_overheated=false; s.step(2)
    assert(table.concat(s.logs,'\n'):find('HEAT_LOCK_CLEARED_AFTER_REQUEST',1,true))
    s.row.heat_overheated=true; s.step(4); s.step(5); assert(s.sent()==2)
end)

test('native heat reader checks identity, flags and effective override', function()
    local ffi=require('ffi')
    local function word(v) return ffi.string(ffi.new('uint32_t[1]',v),4) end
    local function u32(s,o) local v=ffi.new('uint32_t[1]'); ffi.copy(v,s:sub(o+1,o+4),4); return tonumber(v[0]) end
    local function unhex(s) return (s:gsub('..',function(p) return string.char(tonumber(p,16)) end)) end
    local function hex(s) return (s:gsub('.',function(c) return string.format('%02x',c:byte()) end)) end
    local function config(burned)
        local bytes=ffi.new('uint8_t[0x250]'); bytes[0x50]=1; bytes[0x90]=burned and 1 or 0
        return ffi.string(bytes,0x250)
    end
    local memory={
        [0x100000+0x764efa]=unhex('4c8b15471ebc02'),
        [0x100000+0x764f79]=unhex('8bc8498b4258488d1449807c9008000f94c0'),
        [0x40000]=string.rep('W',24),
        [0x60000+24]=word(2)..word(0x42c80000)..'\1\0\0\0',
        [0x70000+0x250]=config(false),
    }
    local pointers={[0x20040]=0x30000,[0x30010]=0x40000,[0x20058]=0x60000,[0x200a8]=0x70000}
    local verified,override=true,nil
    local chunk=assert(source:match('(local function read_heat_component.-)\nlocal function context_reader'))
    local factory=assert(loadstring(chunk..'\nreturn read_heat_component'))
    setfenv(factory,setmetatable({u32=u32,hex=hex,component_static_record=function(_,_,name)
        assert(name=='heat'); if verified then return config(true) end
    end},{__index=_G}))
    local reader=factory()
    local e={game=0x100000,weapon_id=42,weapon=string.rep('W',24),
        global=function(rva) assert(rva==0x3326d48); return 0x20000 end,
        lookup=function(address,id) assert(id==42); if address==0x20028 then return 2 end
            assert(address==0x20068); return override end,
        pointer=function(address,guard) assert(guard); return assert(pointers[address]) end,
        read=function(address,size) local s=assert(memory[address]); assert(#s==size); return s end}
    local row={}; reader(e,row); assert(row.heat_verified and row.heat_overheated and row.heat_requires_replacement)
    assert(row.heat_spares==2 and row.ammo_status=='heat_sink_burned_out')
    override=1; row={}; reader(e,row); assert(not row.heat_requires_replacement and row.ammo_status=='heat_cooling_lock')
    memory[0x40000]=string.rep('X',24); assert(not pcall(reader,e,{})); memory[0x40000]=e.weapon
    memory[0x60018]=word(2)..word(0)..'\2\0\0\0'; assert(not pcall(reader,e,{}))
    verified=false; row={}; reader(e,row); assert(not row.heat_verified)
    memory[0x100000+0x764efa]=string.rep('\0',7); assert(not pcall(reader,e,{}))
end)

test('explicit attack retries after request cooldown', function()
    local s=scenario(); s.step(0); s.step(3)
    s.state.lmb_edge_time=3.5; s.step(3.5); assert(s.sent()==1)
    s.state.lmb_edge_time=5.1; s.step(5.1); assert(s.sent()==2)
end)
test('no ammo recovery is reported as unconfirmed', function()
    local s=scenario(); s.step(0); s.step(3); s.step(11)
    assert(table.concat(s.logs,'\n'):find('RELOAD_UNCONFIRMED',1,true)); assert(s.sent()==1)
end)
test('ammo recovery permits next empty episode', function()
    local s=scenario(); s.step(0); s.step(3); s.row.rounds_magazine_count=5; s.step(4)
    assert(table.concat(s.logs,'\n'):find('AMMO_RECOVERED_AFTER_REQUEST',1,true))
    s.row.rounds_magazine_count=0; s.step(5); s.step(8); assert(s.sent()==2)
end)
test('scan-code press spans frames and failed keyup is retried', function()
    local ffi = require('ffi')
    local now, focused, fail_up, events = 1000, true, false, {}
    local user = {
        GetForegroundWindow=function() return ffi.cast('void *', 1) end,
        GetWindowThreadProcessId=function(_, owner) owner[0]=focused and 123 or 999 end,
        GetAsyncKeyState=function() return 0 end,
        SendInput=function(count, input, size)
            assert(count==1 and size==40)
            local kind=tonumber(ffi.cast('uint32_t *',input)[0])
            local vk=tonumber(ffi.cast('uint16_t *',input+8)[0])
            local scan=tonumber(ffi.cast('uint16_t *',input+10)[0])
            local flags=tonumber(ffi.cast('uint32_t *',input+12)[0])
            assert(kind==1 and vk==0 and scan==0x13)
            events[#events+1]=flags
            return flags==10 and fail_up and 0 or 1
        end,
    }
    local kernel = {GetCurrentProcess=function() return nil end,
        GetCurrentProcessId=function() return 123 end,
        GetTickCount64=function() return now end}
    local shim=setmetatable({load=function(name) return name=='user32' and user or kernel end}, {__index=ffi})
    local chunk=assert(source:match('(local function read_api%(%).-)%\nlocal function context_reader'))
    local factory=assert(loadstring(chunk .. '\nreturn read_api()'))
    setfenv(factory,setmetatable({require=function() return shim end,
        debug_emit=function() end, state={ticks=0,elapsed=0}},{__index=_G}))
    local api=factory()
    assert(api.key_state(1)==0 and not api.own_reload_active())
    assert(api.send_reload()); assert(#events==1 and events[1]==8 and api.own_reload_active())
    now=1070; assert(api.release_reload()); assert(#events==1)
    now=1081; fail_up=true; assert(not api.release_reload()); assert(events[2]==10)
    assert(not api.send_reload())
    fail_up=false; assert(api.release_reload()); assert(events[3]==10 and not api.own_reload_active())
    focused=false; assert(not api.send_reload()); assert(#events==3)
    focused=true; assert(api.send_reload()); focused=false
    assert(api.release_reload(true)); assert(events[5]==10)
end)
print(string.format('%d tests passed',tests))
