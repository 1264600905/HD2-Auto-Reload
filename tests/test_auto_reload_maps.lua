-- Test complete per-component maps and resource records for build 25327279.
local ffi=require('ffi')
local function readfile(path) local f=assert(io.open(path,'rb')); local s=f:read('*a'); f:close(); return s end
local source=readfile('build/auto_reload_entry.lua')
local chunk=assert(source:match('(local static_magazine_map.-)\nstatic_component_snapshot ='))
local function pointer(s)
    if not s or #s<8 then return nil end
    local v=ffi.new('uint64_t[1]'); ffi.copy(v,s,8); local n=tonumber(v[0])
    if n>=65536 and n<0x800000000000 then return n end
end
local function u32(s,o) local v=ffi.new('uint32_t[1]'); ffi.copy(v,s:sub(o+1,o+4),4); return tonumber(v[0]) end
local function resource(s) local r=''; for i=8,1,-1 do r=r..string.format('%02x',s:byte(i)) end; return r end
local function p64(n) return ffi.string(ffi.new('uint64_t[1]',n),8) end
local function replace(s,o,value) return s:sub(1,o)..value..s:sub(o+#value+1) end
local function unhex(s) return (s:gsub('%s',''):gsub('..',function(p) return string.char(tonumber(p,16)) end)) end
local mag=unhex(readfile('data/WeaponMagazineComponent.25327279.map.hex'))
local heat=unhex(readfile('data/WeaponHeatComponent.25327279.map.hex'))
local rounds=unhex(readfile('data/WeaponRoundsComponent.25327279.map.hex'))
local owner=0x100000
local regions={
    [owner+0xf124a0]=p64(0x3000000),
    [owner+0xf12cc8]=p64(0x4000000),
    [owner+0xf12820]=p64(0x5000000),
    [0x3000000]=mag..string.rep('M',#mag/16*160),
    [0x4000000]=heat..string.rep('H',#heat/16*0x250),
    [0x5000000]=rounds..string.rep('R',#rounds/16*0x88),
}
local function read(address,size)
    for base,data in pairs(regions) do
        local offset=address-base
        if offset>=0 and offset+size<=#data then return data:sub(offset+1,offset+size) end
    end
end
local state={elapsed=0}
local factory=assert(loadstring('local magazine_static_records,component_static_record\n'..chunk..'\nreturn component_static_record'))
setfenv(factory,setmetatable({api={read=read,pointer=pointer},resource=resource,u32=u32,state=state},{__index=_G}))
local reader=factory()
local guarded=0
local e={owner=owner,
    pointer=function(a,g) assert(g); guarded=guarded+1; return assert(pointer(read(a,8))) end,
    read=function(a,n,g) if g then guarded=guarded+1 end; return assert(read(a,n)) end}
local function first_resource(map)
    for offset=0,#map-16,16 do
        local key=resource(map:sub(offset+1,offset+8))
        if key~='0000000000000000' then return key end
    end
end
for _,spec in ipairs({{'magazine',mag,160,'M',0x3000000}, {'heat',heat,0x250,'H',0x4000000}, {'rounds',rounds,0x88,'R',0x5000000}}) do
    local row={current_weapon_resource=first_resource(spec[2])}
    guarded=0
    local result=assert(reader(e,row,spec[1]))
    assert(result==string.rep(spec[4],spec[3]) and guarded==3)
    print('PASS '..spec[1]..' full map and resource record guards')
    local original=regions[spec[5]]
    local offset=#spec[2]-10
    regions[spec[5]]=replace(original,offset,string.char((original:byte(offset+1)+1)%256))
    assert(reader(e,row,spec[1])==nil)
    regions[spec[5]]=original
    assert(reader(e,{current_weapon_resource='00000000000000ff'},spec[1])==nil)
    print('PASS '..spec[1]..' non-prefix mutation and unknown resource rejected')
end
