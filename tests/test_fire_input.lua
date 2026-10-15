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
}
local function fixture()
    local bytes,events,keys={}, {}, {}
    local now,focused,fail_r,change_owner=1000,true,false,false
    local state={ticks=0,elapsed=0}
    local function put(a,s) for i=1,#s do bytes[a+i-1]=s:byte(i) end end
    local user={GetForegroundWindow=function() return ffi.cast('void *',1) end,
        GetWindowThreadProcessId=function(_,p) p[0]=focused and 123 or 999 end,
        GetAsyncKeyState=function(k) return keys[k] and -32768 or 0 end,
        SendInput=function(_,input)
            input=ffi.cast('const uint8_t *',input)
            local mouse=ffi.cast('const uint32_t *',input)[0]==0
            local flags=tonumber(ffi.cast('const uint32_t *',input+(mouse and 20 or 12))[0])
            events[#events+1]=mouse and 'mouse_up' or flags==8 and 'R_down' or 'R_up'
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
                    assert(tonumber(action)==0x900000002 and duration==-1)
                    events[#events+1]='consume_FIRE'
                    put(owner+0x1c88,'\0')
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
    return {api=api,events=events,put=put,keys=keys,
        bind=function() return api.bind_fire_input(game) end,
        trigger=function(down) put(owner+0x1c88,down and '\1' or '\0') end,
        focus=function(v) focused=v end,fail_r=function(v) fail_r=v end,
        change_owner=function() change_owner=true end,
        frame=function() now=now+100;state.ticks=state.ticks+1;api.release_reload();state.ticks=state.ticks+1 end}
end
local count=0
local function test(name,fn) fn();count=count+1;print('PASS '..name) end
test('merged controller fire is consumed before R without sending a mouse event',function()
    local s=fixture();assert(s.bind());s.trigger(true);assert(s.api.fire_held())
    local ok,_,interrupted=s.api.send_reload(true)
    assert(ok and interrupted and table.concat(s.events,',')=='consume_FIRE,R_down')
    assert(not s.api.fire_held());s.frame();assert(s.events[3]=='R_up')
end)
test('per-round reload and automatic bolt wait for controller fire at the input boundary',function()
    local s=fixture();s.bind();s.trigger(true)
    local ok,why=s.api.send_reload(false,true)
    assert(not ok and why=='per_round_fire_held' and not s.api.send_bolt() and #s.events==0)
    s.trigger(false);assert(s.api.send_reload(false,true));assert(s.events[1]=='R_down')
end)
test('mouse fire retains the existing release while merged fire is cleared first',function()
    local s=fixture();s.bind();s.keys[1]=true;s.trigger(true)
    assert(s.api.send_reload(true))
    assert(table.concat(s.events,',')=='consume_FIRE,mouse_up,R_down')
end)
test('stationary reloads never consume held fire',function()
    local s=fixture();s.bind();s.trigger(true);assert(s.api.send_reload(false))
    assert(s.api.fire_held() and table.concat(s.events,',')=='R_down')
end)
test('focus, held R, our owned key and changed input owner prevent fire consumption',function()
    local s=fixture();s.bind();s.trigger(true);s.focus(false)
    assert(not s.api.send_reload(true) and #s.events==0)
    s.focus(true);s.keys[0x52]=true;assert(not s.api.send_reload(true) and s.events[1]=='R_up')
    s.keys[0x52]=false;s.frame();s.trigger(false);assert(s.api.send_reload())
    s.trigger(true);assert(not s.api.send_reload(true) and #s.events==2)
    s.frame();s.change_owner();local ok,why=s.api.send_reload(true)
    assert(not ok and why=='fire_input_owner_changed' and #s.events==3)
end)
test('failed R preserves the interruption marker for the next accepted request',function()
    local s=fixture();s.bind();s.trigger(true);s.fail_r(true);assert(not s.api.send_reload(true))
    s.fail_r(false);local ok,_,interrupted=s.api.send_reload(true)
    assert(ok and interrupted and table.concat(s.events,',')=='consume_FIRE,R_down,R_down')
end)
test('build or signature mismatch disables the native path and keeps keyboard fallback',function()
    for _,address in ipairs({game+0x108,game+0x150,game+0x585b80,game+0xa45514,
        game+0x12fde90,game+0x12fdf0e,game+0x12fd250}) do
        local s=fixture();s.put(address,'\255');assert(not pcall(s.bind));s.trigger(true)
        assert(not s.api.fire_held());s.keys[1]=true;assert(s.api.fire_held())
        assert(s.api.send_reload(true) and table.concat(s.events,',')=='mouse_up,R_down')
    end
end)
test('missing input owner never calls a native function',function()
    local s=fixture();s.bind();s.put(game+0x347cf18,pointer(0))
    assert(not s.api.fire_held() and s.api.send_reload(true))
    assert(table.concat(s.events,',')=='R_down')
end)
print(count..' merged fire input tests passed')
