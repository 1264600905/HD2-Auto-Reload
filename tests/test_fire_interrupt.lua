-- Controller routing and lifetime checks; no game process or real input calls.
local fixture=assert(loadfile('tests/test_auto_reload.lua'))
setfenv(fixture,setmetatable({AUTO_RELOAD_FIXTURE_ONLY=true},{__index=_G}))
local scenario=fixture()
local count=0
local function test(name,fn) fn();count=count+1;print('PASS '..name) end

test('AC8 never interrupts fire in one-round, five-round, empty and master-off modes',function()
    for _,mode in ipairs({1,2,3}) do
        for _,tactical in ipairs({false,true}) do
            local s=scenario(tactical,{tactical_reload=tactical,ac8_threshold=mode},100)
            s.row.current_weapon_resource='a8cffb316f0b5c5f'
            local attack_only=not tactical or mode==3
            s.row.rounds_magazine_count=not attack_only and mode==2 and 5 or 0
            s.row.rounds_chambered=not attack_only;s.row.rounds_chamber_token=attack_only and 0 or 259
            s.hold_gamepad_fire(true);s.click(0)
            s.continuous_step(0);assert(s.sent()==0)
            s.continuous_step(.1001);assert(s.sent()==1)
            assert(s.interrupt_flags[1]==false and s.state.fire_interrupt_identity==nil)
        end
    end
end)
test('all configured shell-loading families and underbarrels keep fire priority',function()
    for _,resource in ipairs({'7b75e5132ffd4ca6','e6d932be83729076','41eac4a03987faa0',
        '4f749e2ee26f532d','4e310b1fe4c52b52','d323de60855898ac','dcd1c835407ef7ba',
        '90ddc374f4e3d756','006e44327bb953fe','c780bcd79547da0f','df51fe8d62f294be',
        'b9c209b4f99b5335','unknown_underbarrel'}) do
        local s=scenario(false,nil,100);s.row.current_weapon_resource=resource
        if resource=='unknown_underbarrel' then s.row.weapon_mode='underbarrel' end
        s.hold_gamepad_fire(true);s.continuous_step(0);assert(s.draws()==0 and s.sent()==0,resource)
        s.hold_gamepad_fire(false);s.continuous_step(.1);s.continuous_step(.2001)
        assert(s.sent()==1 and s.interrupt_flags[1]==false and s.state.fire_interrupt_identity==nil,resource)
    end
end)

local f=assert(io.open('src/auto_reload.lua','rb'));local source=f:read('*a');f:close()
local identity=assert(source:match('(local function reload_identity.-)\nlocal function reload_request'))
local maintain=assert(source:match('(local function maintain_fire_interrupt.-)\nlocal function eruptor_bolt_step'))
local function context()
    local row={context_status='context_observed',weapon_owned=true,current_weapon_resource='rifle',
        selected_entity_id=1,selected_slot=1,_weapon_bytes='weapon',local_entity_id=1,
        weapon_context='on_foot',_selection_bytes='main',ammo_path='weapon_magazine'}
    local state={latest_row=row,elapsed=0,latest_at=0}
    local active,calls=true,{}
    local api={update_fire_interrupt=function(force) calls[#calls+1]=force;if force then active=false end end,
        fire_interrupt_active=function() return active end}
    local factory=assert(loadstring(identity..'\n'..maintain..'\nreturn reload_identity,maintain_fire_interrupt'))
    setfenv(factory,setmetatable({state=state,api=api,AC8_RESOURCE='a8cffb316f0b5c5f',
        per_round_weapon=function(r) return r.current_weapon_resource=='shells' end},{__index=_G}))
    local identify,step=factory();state.fire_interrupt_identity=identify(row)
    return {row=row,state=state,calls=calls,step=step,identify=identify,active=function() return active end}
end
test('the suppression window is maintained after ammo has recovered',function()
    local s=context();s.row.magazine_count=30;s.step()
    assert(s.calls[1]==false and s.active())
end)
test('weapon, avatar, seat and input-path changes cancel the window',function()
    for _,key in ipairs({'selected_entity_id','selected_slot','local_entity_id','current_weapon_resource',
        '_weapon_bytes','weapon_context','_selection_bytes','ammo_path'}) do
        local s=context();s.row[key]='changed';s.step()
        assert(s.calls[1]==true and not s.active() and s.state.fire_interrupt_identity==nil,key)
    end
end)
test('missing, stale, dead and unowned contexts stop suppression',function()
    for _,kind in ipairs({'missing','stale','death','unowned'}) do
        local s=context()
        if kind=='missing' then s.state.latest_row=nil
        elseif kind=='stale' then s.state.elapsed=.3
        elseif kind=='death' then s.row.context_status='waiting_for_avatar'
        else s.row.weapon_owned=false end
        s.step();assert(s.calls[1]==true and not s.active(),kind)
    end
end)
test('shell-loading and AC8 contexts cannot retain even an incorrectly attached window',function()
    for _,resource in ipairs({'shells','a8cffb316f0b5c5f'}) do
        local s=context();s.row.current_weapon_resource=resource
        s.state.fire_interrupt_identity=s.identify(s.row);s.step()
        assert(s.calls[1]==true and not s.active(),resource)
    end
end)
test('settings cancellation is observed on the next maintenance call',function()
    local s=context();s.state.fire_interrupt_identity=nil;s.step()
    assert(s.calls[1]==true and not s.active())
end)
print(count..' fire interruption routing tests passed')
