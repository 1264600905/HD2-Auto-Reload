-- Real merged-input adapter with recorded native/Windows calls only.
local ffi, bit = require('ffi'), require('bit')
local f=assert(io.open('src/auto_reload.lua','rb'));local source=f:read('*a');f:close()
local code=assert(source:match('(local function u32.-)\nlocal function context_reader'))
local function word(n) return ffi.string(ffi.new('uint32_t[1]',n),4) end
local function pointer(n) return ffi.string(ffi.new('uint64_t[1]',n),8) end
local function unhex(s) return (s:gsub('..',function(h) return string.char(tonumber(h,16)) end)) end
local game, owner = 0x10000000, 0x20000000
local signatures={
    {0x585b80,'83f90c771d4c8d0574a4a7ff8bc1418b9480a85b58004903d0ffe248c1e9208bc1c3'},
    {0xa45514,'49bd0200000009000000498bcde85a06b4ff4c8ba42480000000448bc849c1e1054738b421681b0000'},
    {0x12fde90,'40534883ec204c8bd14c8bca488bcae8dc7c28ff33db448bd8418bc1448bc3486bd0614c03da488b15638e020249c1e30543c6841328030000004b899c132c03000043899c1334030000'},
    {0x12fdf0e,'488b0d03f017020f28da41b802000000498bd14883c4205be925f3ffff'},
    {0x12fd250,'48895c240848896c2410488974241848897c24204154415641574883ec20488bf1458be0488bca488bdae8018928ff'},
    {0x12fd3b0,'48896c2418564883ec204c8bd94c8bca488bcae8b88728ff418bb3509b0a0041c1e110440fb7d033c0450bd1'},
    {0x12fd436,'418b4004488d0c4041c784cb387d0a0000000000488b5c2430488b7c2438488b6c24404883c4205ec3'},
    {0x12fa358,'83fa0241b60144887424300f94442431'},
    {0x12fb9e7,'440fb6742430807c2431000f84b50100004584f60f8413eaffff488bd3488bcee8a4190000'},
}
local function fixture()
    local bytes,events,keys={}, {}, {}
    local now,focused,fail_r,change_owner=1000,true,false,false
    local native_deadline, native_mode
    local state={ticks=0,elapsed=0}
    local function put(a,s) for i=1,#s do bytes[a+i-1]=s:byte(i) end end
    local user={GetForegroundWindow=function() return ffi.cast('void *',1) end,
        GetWindowThreadProcessId=function(_,p) p[0]=focused and 123 or 999 end,
        GetAsyncKeyState=function(k) return keys[k] and -32768 or 0 end,
        SendInput=function(_,input)
            input=ffi.cast('const uint8_t *',input)
            local mouse=ffi.cast('const uint32_t *',input)[0]==0
            local flags=tonumber(ffi.cast('const uint32_t *',input+(mouse and 20 or 12))[0])
            events[#events+1]=mouse and (flags==2 and 'mouse_down' or 'mouse_up') or flags==8 and 'R_down' or 'R_up'
            if mouse and flags==4 then keys[1]=false end
            return not mouse and flags==8 and fail_r and 0 or 1
        end}
    local kernel={GetCurrentProcess=function() end,GetCurrentProcessId=function() return 123 end,
        GetTickCount64=function() return now end}
    local shim=setmetatable({load=function(n) return n=='user32' and user or kernel end,
        cast=function(kind,value)
            if kind=='void (*)(void *, uint64_t, float)' then
                assert(value==game+0x12fde90)
                return function(input,action,duration)
                    assert(tonumber(ffi.cast('uintptr_t',input))==owner)
                    assert(tonumber(action)==0x900000002 and (duration==0 or duration==0.5))
                    events[#events+1]=duration==0 and 'consume_FIRE' or 'block_FIRE_500ms'
                    native_deadline=math.max(native_deadline or 0,now+duration*1000)
                    native_mode=2
                    put(owner+0x1c88,'\0')
                end
            elseif kind=='void (*)(void *, uint64_t, uint32_t, float)' then
                assert(value==game+0x12fd250)
                return function(input,action,mode,duration)
                    assert(tonumber(ffi.cast('uintptr_t',input))==owner and tonumber(action)==0x900000002)
                    assert(mode==1 and duration==0.5)
                    events[#events+1]='block_FIRE_500ms'
                    native_deadline=math.max(native_deadline or 0,now+duration*1000)
                    native_mode=mode
                end
            elseif kind=='void (*)(void *, uint64_t)' then
                assert(value==game+0x12fd3b0)
                return function(input,action)
                    assert(tonumber(ffi.cast('uintptr_t',input))==owner and tonumber(action)==0x900000002)
                    native_deadline,native_mode=nil,nil;events[#events+1]='release_FIRE_block'
                end
            end
            return ffi.cast(kind,value)
        end}, {__index=ffi})
    local factory=assert(loadstring(code..'\nreturn read_api()'))
    setfenv(factory,setmetatable({require=function(n) return n=='ffi' and shim or require(n) end,
        state=state,bit=bit,debug_emit=function() end},{__index=_G}))
    local api=factory()
    api.read=function(a,n)
        if a==owner+0x1c88 and change_owner then put(game+0x347cf18,pointer(owner+0x10000)) end
        local out={};for i=0,n-1 do if not bytes[a+i] then return nil end;out[#out+1]=string.char(bytes[a+i]) end
        return table.concat(out)
    end
    put(game+0x3c,word(0x100))
    put(game+0x100,string.rep('\0',8)..word(0x6ab3b43f)..string.rep('\0',0x50-12)..word(0x4744000)..string.rep('\0',12))
    for _,sig in ipairs(signatures) do put(game+sig[1],unhex(sig[2])) end
    put(game+0x347cf18,pointer(owner));put(owner+0x1c88,'\0')
    return {api=api,events=events,put=put,keys=keys,state=state,
        bind=function() return api.bind_fire_input(game) end,
        trigger=function(down) put(owner+0x1c88,down and '\1' or '\0') end,
        -- The real input update cancels mode 2 on physical release even before
        -- its deadline. Mode 1 keeps blocking until expiry or explicit release.
        game_update=function(milliseconds,held)
            now=milliseconds
            if native_deadline and (now>=native_deadline or (native_mode==2 and not held)) then
                native_deadline,native_mode=nil,nil
            end
            local down=held and not native_deadline
            put(owner+0x1c88,down and '\1' or '\0')
            return down
        end,
        native_deadline=function() return native_deadline end,
        focus=function(v) focused=v end,fail_r=function(v) fail_r=v end,
        change_owner=function() change_owner=true end,
        maintain=function(milliseconds) now=milliseconds;state.ticks=state.ticks+1;return api.update_fire_interrupt() end,
        frame=function() now=now+100;state.ticks=state.ticks+1;api.release_reload();state.ticks=state.ticks+1 end}
end
local count=0
local function test(name,fn) fn();count=count+1;print('PASS '..name) end

test('FIRE is stopped and blocked before the delayed R, with one fixed deadline',function()
    local s=fixture();s.bind();s.trigger(true)
    assert(s.api.begin_fire_interrupt())
    assert(table.concat(s.events,',')=='consume_FIRE,block_FIRE_500ms')
    assert(not s.game_update(1080,true));s.maintain(1080)
    assert(s.api.send_reload(true) and s.native_deadline()==1500)
    assert(table.concat(s.events,',')=='consume_FIRE,block_FIRE_500ms,R_down')
    s.frame();assert(s.api.send_reload(false))
    assert(s.native_deadline()==1500)
    assert(not s.game_update(1499,true));s.maintain(1499)
    assert(s.game_update(1500,true));s.maintain(1500)
    assert(not s.api.fire_interrupt_active() and s.events[#s.events]=='release_FIRE_block')
end)

test('releasing and pressing FIRE again cannot cancel the half-second block',function()
    local s=fixture();s.bind();assert(s.api.begin_fire_interrupt())
    for _,sample in ipairs({{1001,false},{1016,true},{1100,false},{1200,true},{1499,true}}) do
        assert(not s.game_update(sample[1],sample[2]));s.maintain(sample[1])
        assert(s.native_deadline()==1500)
    end
    assert(s.game_update(1500,true))
end)

test('mouse release precedes protection and R without any mouse press',function()
    local s=fixture();s.bind();s.keys[1]=true;s.trigger(true)
    assert(s.api.begin_fire_interrupt() and s.api.send_reload(true))
    assert(table.concat(s.events,',')=='consume_FIRE,mouse_up,block_FIRE_500ms,R_down')
end)

test('a quiet threshold protects a new fire press before R is sent',function()
    local s=fixture();s.bind();assert(s.api.begin_fire_interrupt())
    assert(s.events[1]=='block_FIRE_500ms')
    assert(not s.game_update(1001,true));s.maintain(1100)
    assert(s.api.send_reload(true) and s.native_deadline()==1500)
    assert(not s.game_update(1499,true) and s.game_update(1500,true))
end)

test('per-round reloads and automatic bolt still wait for held FIRE',function()
    local s=fixture();s.bind();s.trigger(true)
    local ok,why=s.api.send_reload(false,true)
    assert(not ok and why=='per_round_fire_held' and not s.api.send_bolt() and #s.events==0)
    s.trigger(false);assert(s.api.send_reload(false,true) and s.events[1]=='R_down')
end)

test('ordinary non-interrupting reload never creates a FIRE window',function()
    local s=fixture();s.bind();s.trigger(true);assert(s.api.send_reload(false))
    assert(s.api.fire_held() and not s.api.fire_interrupt_active() and table.concat(s.events,',')=='R_down')
end)

test('focus loss, held R and owned keys prevent beginning a window',function()
    local s=fixture();s.bind();s.focus(false);assert(not s.api.begin_fire_interrupt() and #s.events==0)
    s.focus(true);s.keys[0x52]=true;assert(not s.api.begin_fire_interrupt() and #s.events==0)
    s.keys[0x52]=false;assert(s.api.send_reload(false))
    assert(not s.api.begin_fire_interrupt() and #s.events==1)
end)

test('failed R keeps the existing window but cannot renew it',function()
    local s=fixture();s.bind();s.trigger(true);assert(s.api.begin_fire_interrupt());s.fail_r(true)
    assert(not s.api.send_reload(true) and s.api.fire_interrupt_active())
    assert(s.state.attack_interrupted==true)
    s.fail_r(false);s.maintain(1100)
    local ok,_,interrupted=s.api.send_reload(true)
    assert(ok and interrupted and s.native_deadline()==1500)
    assert(table.concat(s.events,',')=='consume_FIRE,block_FIRE_500ms,R_down,R_down')
end)

test('an initial R requires live protection and cannot reopen an expired window',function()
    local s=fixture();s.bind();local ok,why=s.api.send_reload(true)
    assert(not ok and why=='fire_window_expired' and #s.events==0)
    assert(s.api.begin_fire_interrupt());s.maintain(1500)
    ok,why=s.api.send_reload(true)
    assert(not ok and why=='fire_window_expired' and #s.events==2)
end)

test('focus loss and explicit cancellation release native protection',function()
    for _,kind in ipairs({'focus','cancel'}) do
        local s=fixture();s.bind();assert(s.api.begin_fire_interrupt())
        if kind=='focus' then s.focus(false);s.maintain(1100) else s.api.update_fire_interrupt(true) end
        assert(not s.api.fire_interrupt_active() and s.native_deadline()==nil)
        assert(s.events[#s.events]=='release_FIRE_block' and s.game_update(1101,true))
    end
end)

test('input owner changes stop maintenance without calling a stale owner',function()
    local s=fixture();s.bind();assert(s.api.begin_fire_interrupt());s.change_owner()
    local before=#s.events;local ok,why=s.maintain(1100)
    assert(not ok and why=='fire_input_owner_changed' and #s.events==before)
    assert(not s.api.fire_interrupt_active())
end)

test('signature mismatches retain the mouse fallback without native calls',function()
    for _,address in ipairs({game+0x108,game+0x585b80,game+0xa45514,game+0x12fde90,
        game+0x12fd250,game+0x12fd3b0,game+0x12fa358,game+0x12fb9e7}) do
        local s=fixture();s.put(address,'\255');assert(not pcall(s.bind));s.keys[1]=true
        assert(s.api.begin_fire_interrupt() and s.api.send_reload(true))
        assert(table.concat(s.events,',')=='mouse_up,R_down')
    end
end)

test('native diagnostics read mode and remaining time separately from physical FIRE',function()
    local s=fixture();s.bind();local entries=owner+0xb0000
    s.put(owner+0xa9b40,pointer(entries)..word(8)..word(0xffffffff)..word(1))
    s.put(entries+8,word(0x20009)..word(0));s.put(owner+0xa7d34,word(1))
    s.put(owner+0xa7d38,word(1)..word(2)..word(9)..word(0)..pointer(1500000))
    s.put(owner+0xa7d28,pointer(1120000))
    s.put(game+0x23c7ec0,ffi.string(ffi.new('float[1]',1000000),4))
    s.keys[1]=true;s.trigger(false)
    local mode,remaining=s.api.fire_block_status()
    assert(mode==1 and remaining==380 and s.api.fire_held() and not s.api.native_fire_held())
end)
print(count..' merged fire input tests passed')
