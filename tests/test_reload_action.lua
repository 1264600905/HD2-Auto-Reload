-- The new guarded reader only; no process access or game calls.
local ffi=require('ffi')
local f=assert(io.open('src/auto_reload.lua','rb'));local source=f:read('*a');f:close()
local code=assert(source:match('(local function read_reload_action.-)\nlocal function read_eruptor_bolt_component'))
local function word(n) return ffi.string(ffi.new('uint32_t[1]',n),4) end
local function ptr(n) return ffi.string(ffi.new('uint64_t[1]',n),8) end
local function unhex(s) return (s:gsub('..',function(h) return string.char(tonumber(h,16)) end)) end
local function u32(s,o) local n=ffi.new('uint32_t[1]');ffi.copy(n,s:sub(o+1,o+4),4);return tonumber(n[0]) end
local function hex(s) return (s:gsub('.',function(c) return string.format('%02x',c:byte()) end)) end
local factory=assert(loadstring(code..'\nreturn read_reload_action'))
setfenv(factory,setmetatable({u32=u32,hex=hex},{__index=_G}))
local reader=factory()
local function fixture(override,active,current)
    local memory={}
    local function put(a,s) for i=1,#s do memory[a+i-1]=s:byte(i) end end
    local function read(a,n)
        local s={};for i=0,n-1 do
            local value=assert(memory[a+i],string.format('unmapped %x',a+i))
            s[#s+1]=string.char(value)
        end
        return table.concat(s)
    end
    local game,manager,actions,owner=0x10000000,0x20000000,0x30000000,0x40000000
    local weapon=word(0x1234)..word(1)..word(10)..string.rep('\0',12)
    local avatar=word(0x5678)..word(1)..word(20)..string.rep('\0',12)
    put(game+0x3c,word(0x100));put(game+0x108,word(0x6ab3b43f))
    for offset,sig in code:gmatch("{(0x%x+), '(%x+)'}") do put(game+tonumber(offset),unhex(sig)) end
    put(manager+0x38,ptr(manager+0x1000));put(manager+0x1000,ptr(manager+0x2000));put(manager+0x2000,weapon)
    local config
    if override then put(manager+0xa0,ptr(manager+0x3000));config=manager+0x3000+80
    else
        local entries=owner+0x200000;put(owner+0xf12800,ptr(entries))
        local slot=(4294967296+0x1234)%498
        put(entries+slot*16,weapon:sub(1,8)..word(2)..word(0))
        config=entries+0x1f20+160
    end
    put(config+4,word(1001))
    put(actions+0x30,ptr(actions+0x1000));put(actions+0x1000,ptr(actions+0x2000));put(actions+0x2000,avatar)
    put(actions+0x38,ptr(actions+0x3000))
    put(actions+0x3000,word(current or 1001)..string.rep('\0',12)..string.char(active and 1 or 0)..string.rep('\0',15))
    local e={read=read,game=game,owner=owner,weapon_id=10,weapon=weapon,avatar_id=20,avatar=avatar,
        global=function(rva) return rva==0x3326a70 and manager or rva==0x3326640 and actions or error('unexpected global') end,
        pointer=function(a) local n=ffi.new('uint64_t[1]');ffi.copy(n,read(a,8),8);return tonumber(n[0]) end,
        lookup=function(a,key)
            if a==manager+0x20 then assert(key==10);return 0 end
            if a==manager+0x60 then return override and 1 or nil end
            if a==actions+0x18 then assert(key==20);return 0 end
            error('unexpected map')
        end}
    return e,put,manager
end
local count=0
local function test(name,fn) fn();count=count+1;print('PASS '..name) end
test('entity override and resource template identify the actual reload action',function()
    for _,override in ipairs({false,true}) do
        local e=fixture(override,true);local row={};reader(e,row)
        assert(row.reload_state_verified and row.reload_action_active and row.reload_ability==1001)
    end
end)
test('an inactive or different player action is not reported as a reload',function()
    for _,case in ipairs({{false,1001},{true,1002}}) do
        local e=fixture(true,case[1],case[2]);local row={};reader(e,row)
        assert(row.reload_state_verified and not row.reload_action_active)
    end
end)
test('wrong weapon identity cannot supply a verified reload state',function()
    local e,put,manager=fixture(true,true);put(manager+0x2000,string.rep('\0',24))
    local row={};assert(not pcall(reader,e,row) and not row.reload_state_verified)
end)
print(count..' reload action reader tests passed')
