-- End-to-end synthetic memory fixture for the migrated player/weapon/Heat chain.
local ffi=require('ffi')
local function file(path) local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local source=file('build/auto_reload_entry.lua')
local code=assert(source:match('(local bit =.-)\nlocal api, game'))
local maps=assert(source:match('(%-%- Embedded by scripts/build.py.-)\nlocal function snapshot'))
local function word(n) return ffi.string(ffi.new('uint32_t[1]',n),4) end
local function ptr(n) return ffi.string(ffi.new('uint64_t[1]',n),8) end
local function unhex(s) return (s:gsub('%s',''):gsub('..',function(p)return string.char(tonumber(p,16))end)) end
local heat=unhex(file('data/WeaponHeatComponent.25327279.map.hex'))
local key,index
for o=0,#heat-16,16 do
    local k=heat:sub(o+1,o+8)
    if k~=string.rep('\0',8) then
        key=k;local n=ffi.new('uint32_t[1]');ffi.copy(n,heat:sub(o+9,o+12),4);index=tonumber(n[0]);break
    end
end
local function fixture()
    local bytes,guards={},{}
    local function put(a,s) for i=1,#s do bytes[a+i-1]=s:byte(i) end end
    local function read(a,n)
        local t={};for i=0,n-1 do if not bytes[a+i] then return nil end;t[#t+1]=string.char(bytes[a+i]) end
        return table.concat(t)
    end
    local function pointer(s)
        if not s then return nil end;local n=ffi.new('uint64_t[1]');ffi.copy(n,s,8)
        n=tonumber(n[0]);if n>=65536 then return n end
    end
    local next_map=0x9000000
    local function map(a,k,v)
        local base=next_map;next_map=next_map+0x100
        put(a,ptr(base)..word(8)..word(0xffffffff)..word(1))
        put(base,string.rep(word(0xffffffff)..word(0xffffffff),8))
        if k then put(base+(k%8)*8,word(k)..word(v)) end
    end
    local function entity(resource,id,unit,owned)
        return resource..word(id)..word(0)..word(unit)..string.char(owned and 1 or 0)..'\0\0\0'
    end
    local game,pm,owner,inv,driver,hm=0x100000,0x200000,0x4000000,0x300000,0x400000,0x500000
    for rva,value in pairs({[0x3326468]=pm,[0x346bf98]=owner,[0x3326738]=inv,[0x3326660]=driver,[0x3326d48]=hm}) do put(game+rva,ptr(value)) end
    put(pm+0x84,word(1)..word(1));put(pm+0xe8,ptr(0x210000))
    put(0x210000,entity(string.rep('P',8),5,123,true));map(pm+0xd0,5,0);put(pm+0x3a8,word(123))
    map(owner+0xf22ec8,123,1);map(owner+0xf1aeb0,42,2)
    local avatar=entity(string.rep('A',8),7,123,true)
    local weapon=entity(key,42,456,true)
    put(owner+0xf32f18+24,avatar);put(owner+0xf32f18+48,weapon)
    map(inv+0x28,7,0);put(inv+0x14,word(1));put(inv+0x40,ptr(0x310000));put(0x310000,ptr(owner+0xf32f18+24))
    put(inv+0x50,ptr(0x320000));put(0x320000,string.rep('\0',48));put(0x320000,word(42));put(0x32001c,word(1))
    map(driver+0x28,42,0);put(driver+0x40,ptr(0x410000));put(0x410000,ptr(owner+0xf32f18+48))
    put(driver+0x50,ptr(0x420000));put(0x420000,word(0x200)..string.rep('\0',36))
    map(hm+0x28,42,2);map(hm+0x68,nil,nil);put(hm+0x40,ptr(0x510000));put(0x510010,ptr(owner+0xf32f18+48))
    put(hm+0x58,ptr(0x520000));put(0x520018,word(2)..word(0)..'\1\0\0\0')
    put(owner+0xf12cc8,ptr(0x600000));put(0x600000,heat)
    local cfg=0x600000+#heat+index*0x250;put(cfg,string.rep('\0',0x250));put(cfg+0x50,'\1');put(cfg+0x90,'\1')
    put(game+0x764efa,unhex('4c8b15471ebc02'));put(game+0x764f79,unhex('8bc8498b4258488d1449807c9008000f94c0'))
    local factory=assert(loadstring(code..'\n'..maps..'\nreturn context_reader'))
    setfenv(factory,setmetatable({unsafe_resources={},emit=function()end},{__index=_G}))
    local reader=factory()
    return {put=put,read=read,api={read=read,pointer=pointer},
        run=function(api)return reader(api or {read=read,pointer=pointer},game)end,
        weapon_address=owner+0xf32f18+48,avatar_address=owner+0xf32f18+24}
end
local s=fixture();local row=assert(s.run())
assert(row.context_status=='context_observed' and row.heat_verified and row.heat_overheated and row.heat_requires_replacement)
assert(row.selected_slot==1 and row.selected_entity_id==42 and row.memory_bytes<32768)
print('PASS full local player -> avatar -> inventory -> driver -> heat chain')
s.put(0x320000+4,word(42));s.put(0x32001c,word(2));assert(s.run().selected_slot==2)
s.put(0x320000+8,word(42));s.put(0x32001c,word(3));assert(s.run().selected_slot==3)
print('PASS heat chain for main, secondary and support slots')
s=fixture();s.put(s.weapon_address+20,'\0');assert(s.run().context_status=='weapon_not_owned')
s=fixture();s.put(s.avatar_address+16,word(999));assert(s.run().context_status=='avatar_unit_mismatch')
s=fixture();s.put(0x510010,ptr(s.avatar_address));assert(not pcall(s.run))
print('PASS foreign ownership, wrong avatar unit and cross-entity heat registry rejected')
s=fixture();local original=s.api.read;local count=0
s.api.read=function(a,n)
    if a==0x320000 and n==48 then count=count+1;if count==2 then s.put(0x32001c,word(2)) end end
    return original(a,n)
end
local changed,reason=s.run(s.api);assert(changed==nil and reason=='context_changed_during_read')
print('PASS selection changed during guard re-read discards entire snapshot')
