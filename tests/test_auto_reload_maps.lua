-- Test the generated full-fingerprint reader, including the bounded owner scan.
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
local mag=unhex(readfile('data/WeaponMagazineComponent.map.hex'))
local reload=unhex(readfile('data/WeaponReloadComponent.map.hex'))
local owner=0x100000
local owner_data=replace(string.rep('\0',0x3000),0x1078,p64(0x3000000)..p64(0x4000000))
local regions={
    [owner+0xf10000]=owner_data,
    [0x3000000]=mag..string.rep('M',#mag/16*160),
    [0x4000000]=reload..string.rep('R',#reload/16*80),
}
local function read(address,size)
    for base,data in pairs(regions) do
        local offset=address-base
        if offset>=0 and offset+size<=#data then return data:sub(offset+1,offset+size) end
    end
end
local state={elapsed=0}
local factory=assert(loadstring('local magazine_static_records\n'..chunk..'\nreturn magazine_static_records'))
setfenv(factory,setmetatable({api={read=read,pointer=pointer},resource=resource,u32=u32,state=state},{__index=_G}))
local reader=factory()
local guarded=0
local e={owner=owner,
    pointer=function(a,g) assert(g); guarded=guarded+1; return assert(pointer(read(a,8))) end,
    read=function(a,n,g) if g then guarded=guarded+1 end; return assert(read(a,n)) end}
local row={current_weapon_resource='02eecd0b1fa49630'}
local result=assert(reader(e,row))
assert(result.magazine==string.rep('M',160) and result.reload==string.rep('R',80))
assert(guarded==6)
print('PASS full maps, resource records, and pointer/entry guards')
-- Mutate outside the first fingerprint chunk: full-map comparison must fail.
regions[0x3000000]=replace(regions[0x3000000],6000,'\255')
assert(reader(e,row)==nil)
print('PASS non-prefix map mismatch denies verification')
assert(reader(e,{current_weapon_resource='00000000000000ff'})==nil)
print('PASS resource absent from maps is rejected')
