-- Real controller/reader/input code; SendInput is always a local recording stub.
local ffi, bit = require('ffi'), require('bit')
local function file(path) local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local source, built = file('src/auto_reload.lua'), file('build/auto_reload_entry.lua')
local policies=assert(built:match('(local CONTINUOUS_RELOAD_INTERVAL_SECONDS =.-)\nlocal state ='))
local controller=assert(source:match('(local function eruptor_bolt_step.-)\nemit%(%\'START'))
local count=0
local function test(name,fn) fn();count=count+1;print('PASS '..name) end
local function copy(row) local out={};for k,v in pairs(row) do out[k]=v end;return out end
local function scenario()
    local row={context_status='context_observed',weapon_owned=true,weapon_context='on_foot',
        current_weapon_resource='b6aff2195568767f',selected_entity_id=42,selected_slot=1,
        _weapon_bytes='weapon',local_entity_id=7,eruptor_bolt_verified=true,eruptor_bolt_ability=2660,
        eruptor_needs_bolt=true,eruptor_action_active=false,eruptor_player_action_active=false,eruptor_gameplay_input=true}
    local state={elapsed=0,ticks=0,latest_at=0,latest_row=row}
    local settings={eruptor_auto_bolt=true,tactical_reload=false}
    local fresh,focused,held,reloading,sent,owned,release_at,accepted,on_read=row,true,{},false,0,false,0,true,nil
    local api={game_focused=function() return focused end,key_state=function(k) return held[k] or 0 end,
        own_reload_active=function() return reloading end,own_bolt_active=function() return owned end}
    api.release_bolt=function(force) if force or state.elapsed>=release_at then owned=false end;return true end
    api.send_bolt=function()
        if not focused or held[1] or held[0x52] or not accepted then return false,'blocked' end
        sent=sent+1;owned=true;release_at=state.elapsed+.08;return true,'recorded'
    end
    local factory=assert(loadstring(policies..'\n'..controller..'\nreturn eruptor_bolt_step'))
    setfenv(factory,setmetatable({state=state,reload_settings=settings,api=api,bit=bit,
        context_reader=function() if on_read then on_read() end;return fresh end,emit=function() end}, {__index=_G}))
    local step=factory()
    return {row=row,state=state,settings=settings,sent=function() return sent end,owned=function() return owned end,
        fresh=function(v) fresh=v end,focus=function(v) focused=v end,hold=function(k,v) held[k]=v and -32768 or nil end,
        reload=function(v) reloading=v end,accept=function(v) accepted=v end,on_read=function(v) on_read=v end,
        step=function(t) state.elapsed=t;state.latest_at=t;state.ticks=state.ticks+1;api.release_bolt(false);step() end}
end
test('independent default bolt option taps once and waits for confirmation',function()
    local s=scenario();s.step(0);s.step(.08);s.step(.99);assert(s.sent()==1)
    assert(not s.settings.tactical_reload)
end)
test('normal bolt animation, early cleared flag and completed bolt never cause another shot',function()
    local s=scenario();s.step(0);s.row.eruptor_action_active=true;s.step(.04);assert(not s.owned())
    s.step(1.2);s.row.eruptor_needs_bolt=false;s.step(1.4);s.step(2)
    s.row.eruptor_action_active=false;s.step(3);s.step(10);assert(s.sent()==1)
end)
test('manual cycling is left alone; an interrupted action may be completed',function()
    local s=scenario();s.row.eruptor_action_active=true;s.step(0);s.step(2);assert(s.sent()==0)
    s.row.eruptor_action_active=false;s.step(2.1);assert(s.sent()==1)
end)
test('avatar reload or another avatar action blocks bolt input independently of weapon actions',function()
    local s=scenario();s.row.eruptor_player_action_active=true;s.step(0);s.step(3);assert(s.sent()==0)
    s.row.eruptor_player_action_active=false;s.step(4);assert(s.sent()==1)
    s.row.eruptor_player_action_active=true;s.step(4.01);assert(not s.owned())
end)
test('unconfirmed requests retry at one second and stop after three accepted taps',function()
    local s=scenario();for _,t in ipairs({0,.9,1,1.9,2,3,10}) do s.step(t) end
    assert(s.sent()==3)
    s.row.eruptor_needs_bolt=false;s.step(11);s.row.eruptor_needs_bolt=true;s.step(12)
    assert(s.sent()==4)
end)
test('physical fire, manual R and automatic R defer without consuming attempts',function()
    local s=scenario();s.hold(1,true);s.step(0);s.hold(1,false);s.hold(0x52,true);s.step(1)
    s.hold(0x52,false);s.reload(true);s.step(2);assert(s.sent()==0 and not s.state.bolt_requested_at)
    s.reload(false);s.step(3);assert(s.sent()==1)
end)
test('unsupported identities, vehicles, layouts, abilities and UI screens cannot inject fire',function()
    for k,v in pairs({context_status='waiting_for_avatar',weapon_owned=false,weapon_context='vehicle',
        current_weapon_resource='other',eruptor_bolt_verified=false,eruptor_bolt_ability=1,
        eruptor_gameplay_input=false}) do
        local s=scenario();s.row[k]=v;s.step(0);assert(s.sent()==0,k)
    end
end)
test('switch off, focus loss and death discard requests and release owned input',function()
    for _,reason in ipairs({'off','focus','death','swap'}) do
        local s=scenario();s.step(0);assert(s.owned())
        if reason=='off' then s.settings.eruptor_auto_bolt=false
        elseif reason=='focus' then s.focus(false)
        elseif reason=='death' then s.state.latest_row=nil
        else s.row.current_weapon_resource='other' end
        s.step(.01);assert(not s.owned() and s.state.bolt_identity==nil and s.sent()==1,reason)
    end
end)
test('input boundary refresh rejects completed bolts, resumed actions, menus and reused entities',function()
    for k,v in pairs({selected_entity_id=43,selected_slot=2,_weapon_bytes='reused',local_entity_id=8,
        eruptor_bolt_verified=false,eruptor_bolt_ability=1,eruptor_needs_bolt=false,
        eruptor_action_active=true,eruptor_player_action_active=true,eruptor_gameplay_input=false,weapon_context='vehicle',weapon_owned=false}) do
        local s=scenario();local fresh=copy(s.row);fresh[k]=v;s.fresh(fresh);s.step(0);assert(s.sent()==0,k)
    end
    local s=scenario();s.fresh(nil);s.step(0);assert(s.sent()==0)
    s=scenario();s.on_read(function() s.hold(1,true) end);s.step(0);assert(s.sent()==0)
    s=scenario();s.on_read(function() s.focus(false) end);s.step(0);assert(s.sent()==0)
end)
test('failed sends leave all three attempts available',function()
    local s=scenario();s.accept(false);s.step(0);s.step(2);assert(s.sent()==0 and s.state.bolt_attempts==0)
    s.accept(true);s.step(3);assert(s.sent()==1)
end)

local function word(n) return ffi.string(ffi.new('uint32_t[1]',n),4) end
local function ptr(n) return ffi.string(ffi.new('uint64_t[1]',n),8) end
local function unhex(s) return (s:gsub('..',function(h) return string.char(tonumber(h,16)) end)) end
local reader_code=assert(source:match('(local bit =.-)\nlocal function context_reader'))
local reader_factory=assert(loadstring(reader_code..'\nreturn read_eruptor_bolt_component'))
local reader=reader_factory()
local function reader_fixture(override)
    local bytes,guards,indices={}, {}, {}
    local function put(a,s) for i=1,#s do bytes[a+i-1]=s:byte(i) end end
    local function read(a,n,guard)
        local out={};for i=0,n-1 do assert(bytes[a+i],'unmapped');out[#out+1]=string.char(bytes[a+i]) end
        if guard then guards[a]=true end;return table.concat(out)
    end
    local function pointer(a,guard)
        local b=read(a,8,guard);local n=ffi.new('uint64_t[1]');ffi.copy(n,b,8);return tonumber(n[0])
    end
    local game,owner=0x100000,0x4000000
    local weapon=unhex('7f76685519f2afb6')..word(42)..word(0)..word(123)..'\1\0\0\0'
    put(game+0x3c,word(0x100));put(game+0x108,word(0x6ab3b43f))
    for _,sig in ipairs({{0x777786,'8bc8498b4350448534880f95c0'},
        {0x77eaa4,'83b8b00400000074c2488b0dbc7fba0241b8000800008bd3e82f8cffff84c074aa'},
        {0x786d4e,'e86d7bffff84c0745d8bd3e81283ffff'},
        {0x50957f,'4c8b90d82bf100'},{0x5095f1,'4869c1d00400004805a02d0000'}}) do put(game+sig[1],unhex(sig[2])) end
    local managers={[0x3326a70]=0x200000,[0x3326ce0]=0x300000,[0x3326640]=0x500000,[0x347ce28]=0x600000}
    for _,spec in ipairs({{0x200000,0x20,0x38,0x210000},{0x300000,0x30,0x48,0x310000},{0x500000,0x18,0x30,0x510000}}) do
        local m,mo,ro,reg=unpack(spec);indices[m+mo]=2;put(m+ro,ptr(reg));put(reg+16,ptr(0x700000))
    end
    put(0x700000,weapon);put(0x200050,ptr(0x220000));put(0x220008,word(0x800))
    local avatar=string.rep('A',8)..word(7)..word(0)..word(124)..'\1\0\0\0'
    put(0x510000+8,ptr(0x710000));put(0x710000,avatar)
    if override then indices[0x300070]=3;put(0x3000b0,ptr(0x320000));put(0x320000+3*1232+0x4b0,word(2660))
    else
        put(owner+0xf12bd8,ptr(0x800000));local first=((0xb6aff219%730)*(4294967296%730)+0x5568767f%730)%730
        put(0x800000+first*16,weapon:sub(1,8)..word(4)..word(0));put(0x800000+730*16+4*1232+0x4b0,word(2660))
    end
    put(0x500038,ptr(0x520000));put(0x520000+2*224,word(2660)..string.rep('\0',28))
    put(0x520000+224,string.rep('\0',32))
    put(0x600000+0x429c,string.rep('\0',24))
    local e={game=game,owner=owner,weapon_id=42,weapon=weapon,avatar_id=7,avatar=avatar,read=read,pointer=pointer,
        lookup=function(a,id) if a==0x500018 and id==7 then return 1 end;return indices[a] end,
        global=function(rva) return assert(managers[rva]) end}
    return {put=put,guards=guards,e=e,run=function() local row={};reader(e,row);return row end}
end
test('both effective entity overrides and resource templates identify the native pending bolt',function()
    for _,override in ipairs({false,true}) do
        local s=reader_fixture(override);local row=s.run()
        assert(row.eruptor_bolt_verified and row.eruptor_needs_bolt and row.eruptor_bolt_ability==2660)
        assert(row.eruptor_active_ability==2660 and not row.eruptor_action_active and row.eruptor_gameplay_input)
        assert(row.eruptor_player_action_active==false)
        assert(row.eruptor_config_source==(override and 'entity_override' or 'resource_template'))
        assert(s.guards[0x220008] and s.guards[0x520000+2*224] and s.guards[0x600000+0x429c])
    end
end)
test('cleared bolt flags, running actions and every open UI screen are decoded independently',function()
    local s=reader_fixture(true);s.put(0x220008,word(0x100));s.put(0x520000+2*224+16,'\1')
    s.put(0x600000+0x429c+20,word(1));local row=s.run()
    assert(row.eruptor_bolt_verified and not row.eruptor_needs_bolt and row.eruptor_action_active)
    assert(not row.eruptor_gameplay_input)
    s.put(0x520000+224,word(2764));s.put(0x520000+224+16,'\1');row=s.run()
    assert(row.eruptor_player_active_ability==2764 and row.eruptor_player_action_active)
end)
test('old builds and changed native signatures disable only the optional bolt reader',function()
    local s=reader_fixture(true);s.put(s.e.game+0x108,word(0x6aa96b14));local row=s.run()
    assert(not row.eruptor_bolt_verified and row.eruptor_bolt_status=='unsupported_build')
    s=reader_fixture(true);s.put(s.e.game+0x777786,'\0');row=s.run()
    assert(not row.eruptor_bolt_verified and row.eruptor_bolt_status=='unsupported_layout')
end)
test('foreign components, unknown bolt abilities, corrupt action flags and UI depth fail closed',function()
    local s=reader_fixture(true);s.put(0x700000,string.rep('\0',24));assert(not pcall(s.run))
    s=reader_fixture(true);s.put(0x320000+3*1232+0x4b0,word(2661));local row=s.run()
    assert(not row.eruptor_bolt_verified and row.eruptor_bolt_status=='unverified_bolt_ability')
    s=reader_fixture(true);s.put(0x520000+2*224+16,'\2');assert(not pcall(s.run))
    s=reader_fixture(true);s.put(0x600000+0x429c+20,word(6));assert(not pcall(s.run))
end)

local function input_fixture()
    local now,focused,fire,r,fail_up,fail_down,events=1000,true,false,false,false,false,{}
    local state={ticks=0,elapsed=0}
    local user={GetForegroundWindow=function() return ffi.cast('void *',1) end,
        GetWindowThreadProcessId=function(_,p) p[0]=focused and 123 or 999 end,
        GetAsyncKeyState=function(k) return ((k==1 and fire) or (k==0x52 and r)) and -32768 or 0 end,
        SendInput=function(n,input,size)
            assert(n==1 and size==40);input=ffi.cast('const uint8_t *',input)
            local kind=tonumber(ffi.cast('const uint32_t *',input)[0])
            local flags=tonumber(ffi.cast('const uint32_t *',input+(kind==0 and 20 or 12))[0])
            assert((kind==0 and (flags==2 or flags==4)) or (kind==1 and (flags==8 or flags==10)))
            events[#events+1]={kind,flags}
            return ((flags==4 and fail_up) or (flags==2 and fail_down)) and 0 or 1
        end}
    local kernel={GetCurrentProcess=function() return nil end,GetCurrentProcessId=function() return 123 end,
        GetTickCount64=function() return now end}
    local shim=setmetatable({load=function(n) return n=='user32' and user or kernel end},{__index=ffi})
    local code=assert(source:match('(local function read_api%(%).-)%\nlocal function context_reader'))
    local factory=assert(loadstring(code..'\nreturn read_api()'))
    setfenv(factory,setmetatable({require=function() return shim end,bit=bit,state=state,debug_emit=function() end},{__index=_G}))
    return {api=factory(),events=events,state=state,time=function(v) now=v;state.ticks=state.ticks+1 end,
        focus=function(v) focused=v end,fire=function(v) fire=v end,r=function(v) r=v end,
        fail_up=function(v) fail_up=v end,fail_down=function(v) fail_down=v end}
end
test('mouse tap spans frames, releases after 80ms and cannot turn into R or another tap in its release frame',function()
    local s=input_fixture();local api=s.api;assert(api.send_bolt() and api.own_bolt_active())
    assert(not api.send_bolt() and not api.send_reload());s.time(1070);api.release_bolt();assert(#s.events==1)
    s.time(1081);assert(api.release_bolt() and not api.own_bolt_active());assert(s.events[2][2]==4)
    assert(not api.send_bolt() and not api.send_reload());s.time(1090);assert(api.send_reload())
    assert(not api.send_bolt());s.time(1180);api.release_reload();assert(not api.send_bolt())
    s.time(1190);assert(api.send_bolt());assert(s.events[#s.events][2]==2)
end)
test('held player inputs and loss of focus never cause synthetic left-down or physical left-up',function()
    local s=input_fixture();s.fire(true);assert(not s.api.send_bolt());s.fire(false);s.r(true)
    assert(not s.api.send_bolt());s.r(false);s.focus(false);assert(not s.api.send_bolt() and #s.events==0)
    s.focus(true);assert(s.api.send_bolt());s.focus(false);assert(s.api.release_bolt(true))
    assert(#s.events==2 and s.events[2][2]==4)
end)
test('failed mouse down creates no owned press; failed up remains owned and is retried',function()
    local s=input_fixture();s.fail_down(true);assert(not s.api.send_bolt() and not s.api.own_bolt_active())
    s.fail_down(false);assert(s.api.send_bolt());s.time(1081);s.fail_up(true)
    assert(not s.api.release_bolt() and s.api.own_bolt_active());assert(not s.api.send_bolt() and not s.api.send_reload())
    s.fail_up(false);assert(s.api.release_bolt() and not s.api.own_bolt_active());assert(not s.api.send_bolt())
end)
test('synthetic bolt press is not a player attack edge; real player press remains an edge',function()
    local s=input_fixture();local input=assert(source:match('(local function input_probe%(%).-)\nlocal function truly_empty'))
    local factory=assert(loadstring(input..'\nreturn input_probe'))
    setfenv(factory,setmetatable({api=s.api,state=s.state,bit=bit,emit=function() end},{__index=_G}))
    local probe=factory();s.state.elapsed=1;probe();assert(s.api.send_bolt())
    s.fire(true);probe();assert(s.state.last_lmb_press_at==nil)
    s.fire(false);s.api.release_bolt(true);probe()
    s.state.elapsed=2;s.fire(true);probe();assert(s.state.last_lmb_press_at==2)
end)
test('real update starts a guarded tap, forwards the old update and releases input at shutdown',function()
    local s=input_fixture();local state=s.state;state.latest_row=scenario().row
    local settings={eruptor_auto_bolt=true,tactical_reload=false}
    local forwarded,closed=false,false
    local globals={update=function(dt,arg) assert(dt==.016 and arg=='arg');forwarded=true;return 'previous',arg end,
        shutdown=function(arg) closed=true;return 'closed',arg end}
    local lifecycle=assert(source:match('(local original_update =.-)\nreturn state'))
    local factory=assert(loadstring(policies..'\n'..controller..'\n'..lifecycle..'\nreturn _G.update,_G.shutdown'))
    setfenv(factory,setmetatable({_G=globals,api=s.api,state=state,reload_settings=settings,setup_ok=true,
        DEBUG=false,bit=bit,PERIODIC_CHECK_INTERVALS={.2,.5,1},
        sync_mod_options=function() end,input_probe=function() end,
        snapshot=function() state.latest_at=state.elapsed end,context_reader=function() return state.latest_row end,
        auto_reload_step=function() end,continuous_reload_step=function() end,
        process_reload_delay=function() end,maintain_fire_interrupt=function() end,emit=function() end}, {__index=_G}))
    local update,shutdown=factory();local a,b=update(.016,'arg')
    assert(forwarded and a=='previous' and b=='arg' and s.api.own_bolt_active())
    a,b=shutdown('arg');assert(closed and a=='closed' and b=='arg' and not s.api.own_bolt_active())
    assert(#s.events==2 and s.events[1][2]==2 and s.events[2][2]==4)
end)
print(count..' Eruptor bolt tests passed')
