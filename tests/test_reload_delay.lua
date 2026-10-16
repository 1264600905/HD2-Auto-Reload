-- Actual controller and generated sampler; inputs are recording stubs only.
local fixture = assert(loadfile('tests/test_auto_reload.lua'))
setfenv(fixture, setmetatable({AUTO_RELOAD_FIXTURE_ONLY=true}, {__index=_G}))
local scenario = fixture()
local count = 0
local function test(name, fn) fn(); count=count+1; print('PASS '..name) end
local function magazine(s, resource, rounds)
    s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.current_weapon_resource=resource or 'ordinary'
    s.row.magazine_count=rounds or 0; s.row.magazine_chamber_token=0
    return s
end
local function per_round(delay)
    local s=scenario(true,nil,delay)
    s.row.current_weapon_resource='41eac4a03987faa0'
    s.row.rounds_magazine_count=5; s.row.rounds_magazine_capacity=8
    return s
end

test('80 and 150 ms bounds are honored without an early press',function()
    for _,delay in ipairs({80,150}) do
        local s=magazine(scenario(false,nil,delay))
        s.step(0); s.step(delay/1000-.0001); assert(s.sent()==0 and s.draws()==1)
        s.step(delay/1000+.0001); assert(s.sent()==1)
        assert(s.state.last_reload_delay_ms==delay)
    end
end)
test('waiting keeps one draw and only completed sends set request flags',function()
    local s=magazine(scenario(true,nil,100),'a8a91eb54892b6b2',1)
    s.step(0)
    for frame=1,9 do s.step(frame/100) end
    assert(s.draws()==1 and s.sent()==0 and not s.state.attempted and s.state.immediate_count==nil)
    s.step(.1001); assert(s.sent()==1 and s.state.attempted and s.state.immediate_count==1)
    s.step(.15); assert(s.sent()==1 and s.draws()==1)
end)
test('all reload families pass through the shared delay',function()
    local cases={
        {'normal',function(s) magazine(s) end},
        {'tactical',function(s) magazine(s,'a8a91eb54892b6b2',1) end},
        {'attack only',function(s) magazine(s,'11c27d3babb38956');s.click(0) end},
        {'heat',function(s) s.row.ammo_path='weapon_heat';s.row.current_weapon_resource='d54b9505c0f72873';
            s.row.heat_verified=true;s.row.heat_requires_replacement=true;s.row.heat_overheated=true;s.click(0) end},
        {'shells',function(s) s.row.current_weapon_resource='41eac4a03987faa0';s.row.rounds_magazine_count=5 end},
        {'underbarrel',function(s) s.row.current_weapon_resource='unknown_underbarrel';s.row.weapon_mode='underbarrel' end},
        {'Bastion',function(s) magazine(s,'1fa1f596769225c2');s.row.weapon_context='vehicle' end},
        {'Maelstrom',function(s) magazine(s,'d58ae6a04edb10de');s.row.weapon_context='vehicle' end},
        {'vehicle machine gun',function(s) magazine(s,'085c1edb038ec24e');s.row.weapon_context='vehicle' end},
        {'vehicle shells',function(s) s.row.current_weapon_resource='df51fe8d62f294be';
            s.row.weapon_context='vehicle';s.row.rounds_magazine_count=5 end},
    }
    for _,case in ipairs(cases) do
        local s=scenario(true,nil,100);case[2](s)
        s.continuous_step(0);assert(s.sent()==0 and s.draws()==1,case[1])
        s.continuous_step(.099);assert(s.sent()==0,case[1])
        s.continuous_step(.1001);assert(s.sent()==1,case[1])
    end
end)
test('shell loading redraws after each accepted press and waits for key release',function()
    local values,index={80,150,133},0
    local s=per_round(function() index=index+1;return assert(values[index]) end)
    s.continuous_step(0);s.continuous_step(.0801);assert(s.sent()==1 and s.draws()==1)
    s.own_key(true);s.continuous_step(.12);assert(s.draws()==1)
    s.own_key(false);s.continuous_step(.16);assert(s.draws()==2)
    s.continuous_step(.30);assert(s.sent()==1)
    s.continuous_step(.3101);assert(s.sent()==2)
    s.continuous_step(.32);assert(s.draws()==3)
    s.continuous_step(.452);assert(s.sent()==2)
    s.continuous_step(.4531);assert(s.sent()==3)
    for _,request in ipairs(s.requests) do assert(not request.interrupt and request.defer) end
end)
test('normal and continuous paths cannot queue duplicate presses for one empty weapon',function()
    local s=per_round(100);s.row.rounds_magazine_count=0
    s.continuous_step(0);s.continuous_step(.05);assert(s.draws()==1)
    s.continuous_step(.1001);assert(s.sent()==1 and s.draws()==1)
end)
test('focus loss cancels the old deadline and focus regain starts a full new delay',function()
    local s=magazine(scenario(false,nil,100))
    s.step(0);s.focus(false);s.step(.05);assert(not s.state.pending_reload)
    s.focus(true);s.step(.06);s.step(.1001);assert(s.sent()==0 and s.draws()==2)
    s.step(.1601);assert(s.sent()==1)
end)
test('weapon, avatar, slot and vehicle seat changes cannot reuse the old deadline',function()
    for _,change in ipairs({'selected_entity_id','local_entity_id','selected_slot','_selection_bytes','weapon_context'}) do
        local s=magazine(scenario(false,nil,100));s.row._selection_bytes='seatA'
        s.step(0)
        s.row[change]=type(s.row[change])=='number' and 2 or 'changed'
        s.step(.05);s.step(.1001);assert(s.sent()==0 and s.draws()==2,change)
        s.step(.1501);assert(s.sent()==1,change)
    end
end)
test('death, invalid context and ownership loss discard pending input',function()
    for _,change in ipairs({'death','context','ownership'}) do
        local s=magazine(scenario(false,nil,100));s.step(0)
        if change=='death' then s.state.latest_row=nil
        elseif change=='context' then s.row.context_status='loading'
        else s.row.weapon_owned=false end
        s.step(.1001);assert(s.sent()==0 and not s.state.pending_reload,change)
    end
end)
test('ammo recovery cancels a pending empty reload',function()
    local s=magazine(scenario(false,nil,100));s.step(0)
    s.row.magazine_count=10;s.step(.05);s.step(.1001)
    assert(s.sent()==0 and not s.state.pending_reload)
    s.row.magazine_count=0;s.step(.11);s.step(.2101)
    assert(s.sent()==1 and s.draws()==2)
end)
test('firing during shell delay cancels it and release requires a new delay',function()
    local s=per_round(100);s.continuous_step(0)
    s.hold_gamepad_fire(true);s.continuous_step(.05);assert(not s.state.pending_reload)
    s.hold_gamepad_fire(false);s.continuous_step(.06);s.continuous_step(.1001)
    assert(s.sent()==0 and s.draws()==2)
    s.continuous_step(.1601);assert(s.sent()==1 and not s.interrupt_flags[1])
end)
test('resumed fire at the final read rejects the press and discards the elapsed timer',function()
    local s=per_round(100);s.continuous_step(0)
    s.on_refresh(function() s.hold_gamepad_fire(true) end)
    s.continuous_step(.1001);assert(s.sent()==0 and not s.state.pending_reload)
    s.on_refresh(nil);s.hold_gamepad_fire(false);s.continuous_step(.11)
    s.continuous_step(.20);assert(s.sent()==0)
    s.continuous_step(.2101);assert(s.sent()==1 and s.draws()==2)
end)
test('final context re-read rejects stale identities after the timer',function()
    local s=magazine(scenario(false,nil,100));s.step(0);s.fresh({})
    s.step(.1001);assert(s.sent()==0 and not s.state.pending_reload)
    s.fresh(s.row);s.step(.11);s.step(.2101);assert(s.sent()==1 and s.draws()==2)
end)
test('transient input rejection retries the same matured request without a new draw',function()
    local s=magazine(scenario(false,nil,100));s.step(0);s.allow_send(false)
    s.step(.1001);s.step(.11);assert(s.sent()==0 and s.draws()==1)
    s.allow_send(true);s.step(.12);assert(s.sent()==1 and s.draws()==1)
end)
test('a periodic retry remains queued on later non-periodic frames',function()
    local s=magazine(scenario(false,nil,100));s.step(0);s.step(.1001)
    s.step(.4,true);assert(s.sent()==1 and s.draws()==2)
    s.step(.45,false);s.step(.5001,false);assert(s.sent()==2)
end)
test('an attack-only trigger remains pending after its original click window',function()
    local s=magazine(scenario(false,nil,150),'11c27d3babb38956');s.click(0)
    s.step(0);s.step(.3);assert(s.sent()==1 and s.draws()==1)
end)
test('shell replenishment past the requested one-round threshold cancels that request',function()
    local s=scenario(true,{tactical_reload=true,per_round_threshold=2},100)
    s.row.current_weapon_resource='41eac4a03987faa0';s.row.rounds_magazine_count=1
    s.continuous_step(0);s.row.rounds_magazine_count=2;s.continuous_step(.05)
    s.continuous_step(.1001);assert(s.sent()==0 and not s.state.pending_reload)
end)
test('Speargun retries each receive a separate delay without consuming attempts early',function()
    local s=magazine(scenario(false,nil,100),'3828e2051aa9e897')
    s.step(0);s.step(.1001);assert(s.sent()==1 and s.state.speargun_retry_count==0)
    s.step(.351);assert(s.draws()==2 and s.sent()==1 and s.state.speargun_retry_count==0)
    s.step(.4511);assert(s.sent()==2 and s.state.speargun_retry_count==1)
end)
test('frame scheduling never sends early and records rather than hides overshoot',function()
    local s=magazine(scenario(false,nil,133));s.step(0)
    for frame=1,3 do s.step(frame/30) end
    assert(s.sent()==0);s.step(4/30);assert(s.sent()==1)
    assert(s.state.last_reload_delay_ms==133 and s.state.last_reload_wait_ms>=133)
end)
test('production sampler drives the controller with one bounded draw per request',function()
    local make_sampler=assert(loadfile('src/random_reload_delay.lua'))()
    local sample=make_sampler(133.5821611111111,306.24582071126537,20261016)
    local s=magazine(scenario(false,nil,sample))
    for iteration=1,100 do
        local now=iteration
        s.row.selected_entity_id=iteration;s.step(now)
        local delay=s.state.last_reload_delay_ms
        assert(delay>=80 and delay<=150 and delay%1==0)
        s.step(now+delay/1000-.000001);assert(s.sent()==iteration-1)
        s.step(now+delay/1000+.000001);assert(s.sent()==iteration)
    end
    assert(s.draws()==100)
end)
test('the actual update dispatches waiting reloads every frame without a periodic trigger',function()
    local file=assert(io.open('src/auto_reload.lua','rb'));local source=file:read('*a');file:close()
    local chunk=assert(source:match('(local original_update =.-)\nlocal original_shutdown'))
    local order,state,globals={}, {ticks=0}, {}
    local function mark(name) order[#order+1]=name end
    globals.update=function() mark('original');return 11,nil,33 end
    local api={now=function() return 1 end,game_focused=function() return true end,
        release_bolt=function() end,release_reload=function() end}
    local environment=setmetatable({_G=globals,state=state,api=api,setup_ok=true,DEBUG=false,
        reload_settings={},PERIODIC_CHECK_INTERVALS={},sync_mod_options=function() end,
        input_probe=function() end,snapshot=function() end,auto_reload_step=function(periodic)
            assert(not periodic);mark('auto') end,continuous_reload_step=function() mark('shells') end,
        process_reload_delay=function() mark('dispatch') end,maintain_fire_interrupt=function() mark('fire_window') end,
        eruptor_bolt_step=function() mark('bolt') end}, {__index=_G})
    local factory=assert(loadstring(chunk));setfenv(factory,environment);factory()
    local a,b,c=globals.update(.016)
    assert(a==11 and b==nil and c==33)
    assert(table.concat(order,',')=='fire_window,auto,shells,dispatch,bolt,original')
end)
print(count..' delayed reload tests passed')
