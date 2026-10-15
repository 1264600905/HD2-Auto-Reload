-- Exercise the actual controller functions with synthetic observations.
local file = assert(io.open('src/auto_reload.lua', 'rb'))
local source = file:read('*a'); file:close()
local built = assert(io.open('build/auto_reload_entry.lua', 'rb'))
local generated = built:read('*a'); built:close()
local input_code = assert(source:match('(local function input_probe%(%).-)\nlocal function truly_empty'))
local controller = assert(generated:match('(local function truly_empty.-)\nemit%(%\'START'))
local policies = assert(generated:match('(local CONTINUOUS_RELOAD_INTERVAL_SECONDS =.-)\nlocal state ='))
local tests = 0
local function scenario(tactical_enabled, settings)
    local row = {context_status='context_observed', ammo_path='weapon_rounds',
        current_weapon_resource='safe', selected_entity_id=1, weapon_owned=true,
        rounds_magazine_count=0, rounds_chambered=false, weapon_context='on_foot'}
    local state = {elapsed=0, ticks=0, latest_row=row, latest_at=0, keys={}}
    local sent, logs, fresh, focused, own_down = 0, {}, row, true, false
    local raw_keys, gamepad_fire = {}, false
    local send_ok, interrupted, on_refresh = true, false, nil
    local interrupt_flags = {}
    local api = {key_state=function(code) return raw_keys[code] or 0 end, game_focused=function() return focused end,
        fire_held=function() return gamepad_fire or require('bit').band(raw_keys[0x01] or 0, 0x8000) ~= 0 end,
        own_reload_active=function() return own_down end,
        send_reload=function(interrupt_fire, defer_while_firing)
            if defer_while_firing and (gamepad_fire or require('bit').band(raw_keys[0x01] or 0, 0x8000) ~= 0) then
                return false, 'per_round_fire_held'
            end
            interrupt_flags[#interrupt_flags+1] = interrupt_fire == true
            if not send_ok then return false,'keyup_frame_pending' end
            sent=sent+1; local was_interrupted=interrupted; interrupted=false
            return true,'test',was_interrupted
        end}
    local selected_policies = policies
    -- Keep generic magazine click-timing coverage independent of SG-8P's
    -- production policy, which now correctly requires an empty magazine.
    selected_policies = selected_policies:gsub('local tactical_rules = {',
        "local tactical_rules = {\n    ['timing_fixture'] = {name='test timing', path='weapon_magazine', limit=8},", 1)
    local factory = assert(loadstring(selected_policies .. '\n' .. controller ..
        '\n' .. input_code .. '\nreturn auto_reload_step, rounds_empty, continuous_reload_step, input_probe'))
    settings = settings or {tactical_reload=tactical_enabled == true, configurable_timing=false}
    local environment = setmetatable({reload_settings=settings, state=state, api=api, DEBUG=false,
        bit=require('bit'), unsafe_resources={unsafe=true},
        context_reader=function() if on_refresh then on_refresh() end; return fresh end,
        emit=function(s) logs[#logs+1]=s end, debug_emit=function() end,
        scalar=tostring}, {__index=_G})
    setfenv(factory, environment)
    local step, empty, continuous, probe = factory()
    return {row=row, state=state, settings=settings, logs=logs, empty=empty,
        probe=function(t, r) state.elapsed=t; raw_keys[0x52]=r and -32768 or 0; probe() end, sent=function() return sent end,
        fresh=function(value) fresh=value end, focus=function(value) focused=value end,
        on_refresh=function(callback) on_refresh=callback end,
        logging=function(value) environment.DEBUG=value end,
        hold_fire=function(value) raw_keys[0x01]=value and -32768 or 0; state.keys.LMB=value end,
        hold_gamepad_fire=function(value) gamepad_fire=value end,
        own_key=function(value) own_down=value end,
        allow_send=function(value) send_ok=value end,
        interrupted_request=function() interrupted=true end,
        interrupt_flags=interrupt_flags,
        click=function(t) state.last_lmb_press_at=t; state.lmb_edge_time=t end,
        step=function(t) state.elapsed=t; state.latest_at=t; step() end,
        continuous_step=function(t) state.elapsed=t; state.latest_at=t; step(); continuous() end}
end
local function test(name, fn)
    fn(); tests=tests+1; print('PASS ' .. name)
end

test('AR-11 requests tactical reload at one magazine round, but not two', function()
    local s=scenario(true); s.row.current_weapon_resource='a8a91eb54892b6b2'
    s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.magazine_chamber_token=288; s.row.magazine_count=2
    s.step(0); assert(s.sent()==0)
    s.row.magazine_count=1; s.hold_gamepad_fire(true); s.step(.1)
    assert(s.sent()==1 and s.interrupt_flags[1])
    s.settings.tactical_reload=false; s.step(.2); assert(s.sent()==1)
    s.row.magazine_count=0; s.step(.3); assert(s.sent()==1)
    s.row.magazine_chamber_token=0; s.step(.4); assert(s.sent()==2)
end)

test('gamepad fire produces attack edges for empty stationary weapons', function()
    local s=scenario(); s.row.current_weapon_resource='11c27d3babb38956'
    s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.magazine_count=0; s.row.magazine_chamber_token=0
    s.probe(0); s.step(0); assert(s.sent()==0)
    s.hold_gamepad_fire(true); s.probe(.1); s.step(.1); assert(s.sent()==1)
    s.probe(.2); s.step(.2); assert(s.sent()==1)
    s.hold_gamepad_fire(false); s.probe(.3)
    s.hold_gamepad_fire(true); s.probe(.4); s.step(.4); assert(s.sent()==2)
    assert(not s.interrupt_flags[1] and not s.interrupt_flags[2])
end)

test('per-round weapons wait for gamepad release and recheck a resumed trigger before input', function()
    for _,tactical in ipairs({false,true}) do
        for _,mode in ipairs({1,2,3}) do
            local s=scenario(tactical,{tactical_reload=tactical,per_round_threshold=mode})
            s.row.current_weapon_resource='41eac4a03987faa0'
            s.row.rounds_magazine_capacity=8
            s.hold_gamepad_fire(true); s.continuous_step(0); assert(s.sent()==0)
            s.hold_gamepad_fire(false)
            s.on_refresh(function() s.hold_gamepad_fire(true) end)
            s.continuous_step(.1); assert(s.sent()==0)
            s.on_refresh(nil); s.hold_gamepad_fire(false)
            s.continuous_step(.2); assert(s.sent()>0)
            for _,interrupt in ipairs(s.interrupt_flags) do assert(not interrupt) end
        end
    end
end)
test('empty reload sends immediately and only once', function()
    local s=scenario(); s.step(0); assert(s.sent()==1); s.step(.99); assert(s.sent()==1)
    s.step(1); s.step(7); assert(s.sent()==1)
end)
local function empty_speargun(tactical_enabled)
    local s=scenario(tactical_enabled)
    s.row.current_weapon_resource='3828e2051aa9e897'
    s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.magazine_count=0; s.row.magazine_chamber_token=0
    return s
end

test('Speargun retries an accepted but unexecuted reload at bounded intervals', function()
    for _,tactical in ipairs({false,true}) do
        local s=empty_speargun(tactical)
        s.step(0); assert(s.sent()==1)
        s.step(.249); assert(s.sent()==1)
        s.step(.25); assert(s.sent()==2)
        s.step(.749); assert(s.sent()==2)
        s.step(.75); assert(s.sent()==3)
        s.step(1.749); assert(s.sent()==3)
        s.step(1.75); assert(s.sent()==4)
        s.step(8); s.step(30); assert(s.sent()==4)
        assert(s.state.speargun_retry_count==3 and not s.state.speargun_retry_at)
        assert(table.concat(s.logs,'\n'):find('reason=empty_retry',1,true))
        s.click(31); s.step(31); assert(s.sent()==5)
        assert(s.state.speargun_retry_count==0)
    end
end)

test('Speargun refill or a ready chamber cancels retries and rearms the next shot', function()
    for _,field in ipairs({'magazine_count','magazine_chamber_token'}) do
        local s=empty_speargun(); s.step(0); assert(s.sent()==1)
        s.row[field]=1; s.step(.25); s.step(2); assert(s.sent()==1)
        assert(not s.state.speargun_retry_at)
        s.row[field]=0; s.step(3); assert(s.sent()==2)
        s.step(3.25); assert(s.sent()==3)
    end
end)

test('Speargun retry rechecks fresh ammo and selection before input', function()
    for _,mode in ipairs({'refill','entity','slot','missing','seat'}) do
        local s=empty_speargun(); s.step(0)
        local fresh={}; for k,v in pairs(s.row) do fresh[k]=v end
        if mode=='refill' then fresh.magazine_count=1
        elseif mode=='entity' then fresh.selected_entity_id=2
        elseif mode=='slot' then fresh.selected_slot=2
        elseif mode=='seat' then fresh.weapon_context='vehicle' end
        if mode=='missing' then s.fresh(nil) else s.fresh(fresh) end
        s.step(.25); assert(s.sent()==1)
        assert(s.state.speargun_retry_count==0)
        s.fresh(s.row); s.step(.3); assert(s.sent()==2)
    end
end)

test('Speargun retries defer held keys and rejected sends without consuming attempts', function()
    local s=empty_speargun(); s.step(0)
    s.own_key(true); s.step(.25); assert(s.sent()==1)
    s.own_key(false); s.allow_send(false); s.step(.3); assert(s.sent()==1)
    assert(s.state.speargun_retry_count==0 and s.state.speargun_retry_at==.25)
    s.allow_send(true); s.step(.31); assert(s.sent()==2)
    assert(s.state.speargun_retry_count==1)
end)

test('Speargun focus loss and weapon changes discard pending retries', function()
    for _,mode in ipairs({'focus','resource','entity','unverified','ownership'}) do
        local s=empty_speargun(); s.step(0)
        if mode=='focus' then s.focus(false)
        elseif mode=='resource' then s.row.current_weapon_resource='other'; s.row.magazine_count=1
        elseif mode=='entity' then s.row.selected_entity_id=2; s.row.magazine_count=1
        elseif mode=='unverified' then s.row.magazine_verified=false
        elseif mode=='ownership' then s.row.weapon_owned=false end
        s.step(.25); assert(s.sent()==1)
        assert(not s.state.speargun_retry_at)
    end
end)

test('AMR waits for zero magazine rounds', function()
    local s=scenario(true); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.magazine_chamber_token=40
    s.row.current_weapon_resource='89c5493e08ca4207'
    s.row.magazine_count=2; assert(not s.empty(s.row))
    s.row.magazine_count=1; assert(not s.empty(s.row))
    s.row.magazine_count=0; assert(s.empty(s.row))
    s.row.current_weapon_resource='ordinary'
    assert(not s.empty(s.row))
    s.row.magazine_chamber_token=0; assert(s.empty(s.row))
end)
test('R-36 requests at zero magazine rounds without a bolt check', function()
    local s=scenario(true); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.current_weapon_resource='b6aff2195568767f'
    s.row.magazine_chamber_token=40
    s.row.magazine_count=1; assert(not s.empty(s.row))
    s.row.magazine_count=0; assert(s.empty(s.row))
end)
test('Sweeper and Evictor thresholds include a chambered round', function()
    local s=scenario(true); s.row.rounds_chambered=true; s.row.rounds_chamber_token=297
    s.row.current_weapon_resource='dcd1c835407ef7ba'
    s.row.rounds_magazine_count=4; assert(not s.empty(s.row))
    s.row.rounds_magazine_count=3; assert(s.empty(s.row))
    s.row.current_weapon_resource='006e44327bb953fe'
    s.row.rounds_magazine_count=2; assert(not s.empty(s.row))
    s.row.rounds_magazine_count=1; assert(s.empty(s.row))
end)

test('tactical switch gates zero-magazine reload rules', function()
    local off=scenario(); off.row.ammo_path='weapon_magazine'; off.row.magazine_verified=true
    off.row.current_weapon_resource='89c5493e08ca4207'; off.row.magazine_count=1
    off.row.magazine_chamber_token=259
    assert(not off.empty(off.row))
    off.row.magazine_count=0; assert(not off.empty(off.row))
    off.row.magazine_chamber_token=0; assert(off.empty(off.row))
    local on=scenario(true); on.row.ammo_path='weapon_magazine'; on.row.magazine_verified=true
    on.row.current_weapon_resource='89c5493e08ca4207'; on.row.magazine_count=0
    on.row.magazine_chamber_token=259; assert(on.empty(on.row))
end)

test('configured magazine families use exact player-held resource IDs', function()
    local s=scenario(true); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.magazine_count=11; s.row.magazine_chamber_token=259
    for _,id in ipairs({'84354339522c932d','a955c4ea6f6d4203',
        '4c786785c79d44e7','8a307bd1811a5fe9','dbb6c961c59fadc1',
        'b43235dbd493750c','1d5943301a29c940'}) do
        s.row.current_weapon_resource=id; assert(not s.empty(s.row),id)
        s.row.magazine_count=0; assert(s.empty(s.row),id)
        s.row.magazine_count=11
    end
    s.row.magazine_count=0
    for _,id in ipairs({'80f1a156d9fa1e36', -- JAR-5
        'a32621e3bde13379', -- AX/AR-23 Guard Dog
        '54d86057f5dacfb9'}) do -- AC-8 sentry
        s.row.current_weapon_resource=id; assert(not s.empty(s.row),id)
    end
    s.row.current_weapon_resource='05d8d8c073b9d502' -- SG-8P
    s.row.magazine_count=8; assert(not s.empty(s.row))
    s.row.magazine_count=9; assert(not s.empty(s.row))
    s.row.magazine_count=1; assert(not s.empty(s.row))
    s.row.magazine_count=0; assert(s.empty(s.row))
end)

test('Breakthrough tactical loading starts at five and stops above five', function()
    local s=scenario(true);s.row.current_weapon_resource='df51fe8d62f294be'
    s.row.weapon_context='vehicle';s.row._selection_bytes='seatA:gun0'
    s.row.rounds_magazine_count=6;s.continuous_step(0);assert(s.sent()==0)
    s.row.rounds_magazine_count=5;s.continuous_step(1);assert(s.sent()==1)
    s.row.rounds_magazine_count=6;s.continuous_step(1.22);assert(s.sent()==1)
    local off=scenario();off.row.current_weapon_resource='df51fe8d62f294be'
    off.row.rounds_magazine_count=5;off.continuous_step(0);off.continuous_step(1);assert(off.sent()==0)
    off.row.rounds_magazine_count=0;off.continuous_step(2);assert(off.sent()==1)
end)

test('tank cannons wait for empty and do not reload an unattended weapon', function()
    for _,enabled in ipairs({false,true}) do
        for _,id in ipairs({'1fa1f596769225c2','d58ae6a04edb10de'}) do
            local s=scenario(enabled);s.row.current_weapon_resource=id
            s.row.ammo_path='weapon_magazine';s.row.magazine_verified=true;s.row.magazine_chamber_token=0
            s.row.magazine_count=1;s.step(0);assert(s.sent()==0)
            s.row.magazine_count=0;s.step(1);assert(s.sent()==1)
            s.step(2);assert(s.sent()==1)
        end
    end
    local s=scenario(true);s.row.current_weapon_resource='df51fe8d62f294be'
    s.row.rounds_magazine_count=5;s.row.context_status='vehicle_role_unsupported'
    s.continuous_step(0);s.continuous_step(1);assert(s.sent()==0)
end)

test('changing seat or leaving a vehicle cancels the refreshed reload request', function()
    for _,change in ipairs({'seat','context'}) do
        local s=scenario(true);s.row.current_weapon_resource='df51fe8d62f294be'
        s.row.rounds_magazine_count=5;s.row.weapon_context='vehicle';s.row._selection_bytes='seatA:gun0'
        local fresh={};for k,v in pairs(s.row) do fresh[k]=v end
        if change=='seat' then fresh._selection_bytes='seatB:gun0' else fresh.weapon_context='on_foot' end
        s.fresh(fresh);s.continuous_step(0);s.continuous_step(1);assert(s.sent()==0)
    end
end)

test('new rounds thresholds use magazine count and AC-8 stays single request', function()
    local s=scenario(true); s.row.rounds_chambered=true; s.row.rounds_chamber_token=259
    s.row.current_weapon_resource='41eac4a03987faa0' -- SG-8
    s.row.rounds_magazine_count=8; assert(s.empty(s.row))
    s.row.rounds_magazine_count=9; assert(not s.empty(s.row))
    s.row.current_weapon_resource='a8cffb316f0b5c5f' -- AC-8
    s.row.rounds_magazine_count=2; assert(not s.empty(s.row))
    s.row.rounds_magazine_count=1; assert(not s.empty(s.row))
    s.row.rounds_magazine_count=0; assert(s.empty(s.row))
    s.continuous_step(0); assert(s.sent()==1)
    s.continuous_step(.99); assert(s.sent()==1)
    s.continuous_step(1); assert(s.sent()==1)
    s.continuous_step(1.2); assert(s.sent()==1)
end)

test('standing reload requires a fresh attack on real empty', function()
    local s=scenario(true); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.current_weapon_resource='9f80d67a12a7e40f' -- GR-8
    s.row.magazine_count=1; s.row.magazine_chamber_token=259
    s.state.keys.LMB=true; s.step(0); s.step(2); assert(s.sent()==0)
    s.row.magazine_count=0; s.row.magazine_chamber_token=0
    s.step(3); s.step(5); assert(s.sent()==0)
    s.state.lmb_edge_time=5.1; s.step(5.1); assert(s.sent()==1)
end)

test('LAS-98 requests only on a new attack after verified burned lock', function()
    local s=scenario(); s.row.ammo_path='weapon_heat'
    s.row.current_weapon_resource='d54b9505c0f72873'
    s.row.heat_verified=true; s.row.heat_requires_replacement=true
    s.row.heat_overheated=true; s.state.keys.LMB=true
    s.step(0); s.step(2); assert(s.sent()==0)
    s.state.lmb_edge_time=2.1; s.step(2.1); assert(s.sent()==1)
end)

test('MG-43 experimental reader uses empty attack only', function()
    local s=scenario(true); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.current_weapon_resource='11c27d3babb38956'
    s.row.magazine_count=0; s.row.magazine_chamber_token=0
    s.step(0); s.step(2); assert(s.sent()==0)
    s.state.lmb_edge_time=2.1; s.step(2.1); assert(s.sent()==1)
end)
test('continuous loading starts immediately and waits only for our key release', function()
    local s=scenario(true); s.row.current_weapon_resource='dcd1c835407ef7ba'
    s.row.rounds_chambered=true; s.row.rounds_chamber_token=297; s.row.rounds_magazine_count=3
    s.continuous_step(0); assert(s.sent()==1)
    s.own_key(true); s.continuous_step(.01); assert(s.sent()==1)
    s.own_key(false); s.continuous_step(.09); assert(s.sent()==2)
    s.row.rounds_magazine_count=4; s.continuous_step(.1); assert(s.sent()==2)
end)

test('manual R does not suppress continuous loading and fresh context is still checked', function()
    local s=scenario(true); s.row.current_weapon_resource='006e44327bb953fe'
    s.row.rounds_chambered=true; s.row.rounds_chamber_token=297; s.row.rounds_magazine_count=1
    s.state.keys.R=true; s.continuous_step(0); assert(s.sent()==1)
    s.fresh({}); s.continuous_step(.1); assert(s.sent()==1)
    s.fresh(s.row); s.continuous_step(.2); assert(s.sent()==2)
end)

test('one tactical round sends R in the observing update without a click', function()
    local s=scenario(true); s.row.current_weapon_resource='dcd1c835407ef7ba'
    s.row.rounds_chambered=true; s.row.rounds_chamber_token=259
    s.row.rounds_magazine_count=0 -- total ammo is one
    s.continuous_step(0); assert(s.sent()==1)
    local m=scenario(true); m.row.ammo_path='weapon_magazine'; m.row.magazine_verified=true
    m.row.current_weapon_resource='timing_fixture'; m.row.magazine_count=1
    m.row.magazine_chamber_token=259
    m.step(0); assert(m.sent()==1)
end)

test('one round requests immediately after a prior tactical request', function()
    local s=scenario(true); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.current_weapon_resource='timing_fixture'
    s.row.magazine_count=8; s.row.magazine_chamber_token=259
    s.click(0); s.step(0); s.step(.101); assert(s.sent()==1)
    s.click(.2); s.step(.2); assert(s.sent()==2); s.row.magazine_count=1
    s.step(.21); assert(s.sent()==3)
    s.step(.3); s.step(1); assert(s.sent()==3)
end)

test('one-round request waits for our key release and rearms on ammo change', function()
    local s=scenario(true); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.current_weapon_resource='timing_fixture'
    s.row.magazine_count=1; s.row.magazine_chamber_token=259
    s.own_key(true); s.step(0); assert(s.sent()==0)
    s.own_key(false); s.step(.081); assert(s.sent()==1)
    s.step(1); assert(s.sent()==1)
    s.row.magazine_count=9; s.step(2)
    s.row.magazine_count=1; s.step(3); assert(s.sent()==2)
end)

test('fresh ammo dropping to zero still requests immediately', function()
    local s=scenario(true); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.current_weapon_resource='timing_fixture'
    s.row.magazine_count=1; s.row.magazine_chamber_token=259
    local fresh={}; for k,v in pairs(s.row) do fresh[k]=v end
    fresh.magazine_count=0; s.fresh(fresh)
    s.step(0); s.step(.1); assert(s.sent()==1)
end)

test('manual R does not suppress the one-round tactical request', function()
    local s=scenario(true); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.current_weapon_resource='timing_fixture'
    s.row.magazine_count=1; s.row.magazine_chamber_token=259
    s.state.keys.R=true; s.step(0); assert(s.sent()==1)
    s.state.keys.R=false; s.step(.1); assert(s.sent()==1)
end)

test('zero-limit tactical rules request immediately and retry on a new attack', function()
    for _,id in ipairs({'b6aff2195568767f', '89c5493e08ca4207'}) do
        local s=scenario(true); s.row.ammo_path='weapon_magazine'
        s.row.magazine_verified=true; s.row.current_weapon_resource=id
        s.row.magazine_count=0; s.row.magazine_chamber_token=259
        s.step(0); assert(s.sent()==1, id)
        s.step(.5); assert(s.sent()==1, id)
        s.click(.6); s.step(.6); assert(s.sent()==2, id)
        s.step(.7); assert(s.sent()==2, id)
    end
end)
test('zero-limit request ignores manual R but rejects a changed fresh count', function()
    local manual=scenario(true); manual.row.ammo_path='weapon_magazine'
    manual.row.magazine_verified=true; manual.row.current_weapon_resource='89c5493e08ca4207'
    manual.row.magazine_count=0; manual.row.magazine_chamber_token=259
    manual.state.keys.R=true; manual.step(0)
    manual.state.keys.R=false; manual.step(.1); assert(manual.sent()==1)
    local stale=scenario(true); stale.row.ammo_path='weapon_magazine'
    stale.row.magazine_verified=true; stale.row.current_weapon_resource='89c5493e08ca4207'
    stale.row.magazine_count=0; stale.row.magazine_chamber_token=259
    local fresh={}; for k,v in pairs(stale.row) do fresh[k]=v end
    fresh.magazine_count=1; stale.fresh(fresh); stale.step(0); assert(stale.sent()==0)
    stale.fresh(stale.row); stale.step(.1); assert(stale.sent()==1)
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
    local s=scenario(); s.row.current_weapon_resource='9f80d67a12a7e40f'
    s.state.lmb_edge_time=.9; s.step(1); assert(s.sent()==0)
end)
test('fresh selection mismatch rejects stale request', function()
    local s=scenario(); s.fresh({}); s.step(0); s.step(3); assert(s.sent()==0)
end)
test('failed fresh read rejects request', function()
    local s=scenario(); s.fresh(nil); s.step(0); s.step(3); assert(s.sent()==0)
end)
test('focus and ownership inhibit input', function()
    for _,mode in ipairs({'focus','owned'}) do
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
    s.row.magazine_count=0; s.row.magazine_chamber_token=0
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
test('burned heat sink requests immediately even while firing', function()
    for _,slot in ipairs({1,2,3}) do
        local s=scenario(); s.row.ammo_path='weapon_heat'; s.row.selected_slot=slot
        s.row.heat_verified=true; s.row.heat_requires_replacement=true; s.row.heat_overheated=true
        s.state.keys.LMB=true; s.state.lmb_edge_time=0
        s.step(0); assert(s.sent()==1); s.step(.16); s.step(.99); assert(s.sent()==1)
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
        local fresh={}; for k,v in pairs(s.row) do fresh[k]=v end
        fresh[field]=false; s.fresh(fresh); s.step(2); assert(s.sent()==0)
    end
end)

test('manual R does not suppress burned heat reload', function()
    local s=scenario(); s.row.ammo_path='weapon_heat'
    s.row.heat_verified=true; s.row.heat_requires_replacement=true; s.row.heat_overheated=true
    s.state.keys.R=true; s.step(0); s.step(.5); s.state.keys.R=false
    s.step(2); s.step(5); assert(s.sent()==1)
    s.state.lmb_edge_time=6; s.step(6); assert(s.sent()==2)
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

test('explicit attack retries without a two second cooldown', function()
    local s=scenario(); s.step(0); s.step(3)
    s.state.lmb_edge_time=3.5; s.step(3.5); assert(s.sent()==2)
    s.state.lmb_edge_time=5.1; s.step(5.1); assert(s.sent()==3)
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

test('M105 manual R then firing to zero never disables automatic requests', function()
    local s=scenario(true); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.current_weapon_resource='a6a735accb4a327f'; s.row.magazine_chamber_token=276
    s.row.magazine_count=10; s.step(0); assert(s.sent()==0)
    s.row.magazine_count=7; s.step(.3); assert(s.sent()==0)
    s.probe(.8,true); s.step(.8); s.probe(1.6,false); s.step(1.6)
    s.row.magazine_count=1; s.click(2); s.step(2); assert(s.sent()==1)
    s.row.magazine_count=0; s.step(3); assert(s.sent()==2)
    s.row.magazine_chamber_token=0; s.click(4); s.step(4); assert(s.sent()==3)
end)

test('release-frame deferral does not consume an immediate attack retry', function()
    local s=scenario(true); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.current_weapon_resource='a6a735accb4a327f'; s.row.magazine_count=0
    s.row.magazine_chamber_token=0; s.step(0); assert(s.sent()==1)
    s.allow_send(false); s.click(.1); s.step(.1)
    assert(s.sent()==1 and s.state.last_request==0)
    s.allow_send(true); s.step(.116); assert(s.sent()==2)
    s.step(.132); assert(s.sent()==2)
end)

test('manual or startup held R never changes request state', function()
    local s=scenario(); s.probe(0,true); s.step(0); assert(s.sent()==1)
    s.probe(.5,true); s.step(.5); assert(s.state.last_request==0)
    s.probe(.6,false); s.click(.6); s.step(.6); assert(s.sent()==2)
end)

test('one-round fast rules fire in the threshold update even during rapid clicks', function()
    for _,entry in ipairs({{'84354339522c932d',1}, {'a955c4ea6f6d4203',1},
        {'5fecab819f96a3e8',1}, {'4ba41b6f9f405cc2',1}, {'be70ee0d8d44028e',1},
        {'8a307bd1811a5fe9',1}, {'05e4e5c2db6e44a2',1}, {'3575aabc5f1f9326',1},
        {'4d58c77087b774c5',1}, {'a6a735accb4a327f',1}, {'b43235dbd493750c',1}}) do
        local s=scenario(true); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
        s.row.current_weapon_resource=entry[1]; s.row.magazine_chamber_token=259
        s.row.magazine_count=entry[2]+1
        s.click(0); s.step(0); s.click(.03); s.step(.03); assert(s.sent()==0)
        s.row.magazine_count=entry[2]; s.click(.04); s.step(.04); assert(s.sent()==1,entry[1])
        s.step(.05); assert(s.sent()==1)
        s.row.magazine_count=0; s.step(.06); assert(s.sent()==2)
    end
end)

test('fast rule accepts fresh ammo falling below the observed threshold', function()
    local s=scenario(true); s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.current_weapon_resource='84354339522c932d'; s.row.magazine_count=1
    local fresh={}; for k,v in pairs(s.row) do fresh[k]=v end
    fresh.magazine_count=0; s.fresh(fresh); s.step(0); assert(s.sent()==1)
end)

test('new weapon is not delayed by previous weapons request', function()
    local s=scenario(); s.step(0); assert(s.sent()==1)
    s.row.selected_entity_id=2; s.step(.01); assert(s.sent()==2)
end)

local function configured_scenario(tactical, delay, postpones)
    return scenario(tactical, {tactical_reload=tactical == true,
        shooting_postpones=postpones ~= false, per_round_threshold=1, ac8_threshold=1})
end

local function configured_magazine(resource, count, delay, postpones)
    local s=configured_scenario(true, delay, postpones)
    s.row.ammo_path='weapon_magazine'; s.row.magazine_verified=true
    s.row.magazine_chamber_token=0; s.row.magazine_count=count
    s.row.current_weapon_resource=resource
    return s
end

test('menu tactical toggle changes both threshold and continuous eligibility', function()
    local s=configured_magazine('84354339522c932d',1,0)
    s.settings.tactical_reload=false; s.step(0); assert(s.sent()==0)
    s.settings.tactical_reload=true; s.step(.1); assert(s.sent()==1)
    local c=configured_scenario(false,0); c.row.current_weapon_resource='41eac4a03987faa0'
    c.row.rounds_magazine_count=8; c.continuous_step(0); assert(c.sent()==0)
    c.settings.tactical_reload=true; c.continuous_step(.1); assert(c.sent()==1)
    c.settings.tactical_reload=false; c.continuous_step(.3); assert(c.sent()==1)
end)

test('per-round last-round mode counts the chamber and triggers immediately', function()
    local s=configured_scenario(true); s.settings.per_round_threshold=2
    s.row.current_weapon_resource='dcd1c835407ef7ba'; s.row.rounds_chambered=true
    s.row.rounds_chamber_token=262; s.row.rounds_magazine_count=1
    s.continuous_step(0); assert(s.sent()==0) -- two total rounds
    s.row.rounds_magazine_count=0; s.continuous_step(.01); assert(s.sent()==1)
    s.continuous_step(.02); assert(s.sent()==1)
end)

test('per-round first-shot mode includes the chamber and stops at full total capacity', function()
    for _,capacity in ipairs({7,12,20}) do
        local s=configured_scenario(true); s.settings.per_round_threshold=3
        s.row.current_weapon_resource='dcd1c835407ef7ba'; s.row.rounds_chambered=true
        s.row.rounds_chamber_token=262; s.row.rounds_magazine_capacity=capacity
        s.row.rounds_magazine_count=capacity-1; s.continuous_step(0); assert(s.sent()==0)
        s.continuous_step(1); assert(s.sent()==0)
        s.row.rounds_magazine_count=capacity-2; s.continuous_step(1.01); assert(s.sent()==1)
        s.own_key(true); s.continuous_step(1.02); assert(s.sent()==1)
        s.own_key(false); s.continuous_step(1.09); assert(s.sent()==2)
        s.row.rounds_magazine_count=capacity-1; s.continuous_step(1.1); assert(s.sent()==2)
    end
    local missing=configured_scenario(true); missing.settings.per_round_threshold=3
    missing.row.current_weapon_resource='41eac4a03987faa0'; missing.row.rounds_magazine_count=7
    missing.continuous_step(0); assert(missing.sent()==0)
end)

test('first-shot total count handles an empty chamber and weapons without a chamber', function()
    for _,chambered in ipairs({true,false}) do
        local s=configured_scenario(true); s.settings.per_round_threshold=3
        s.row.current_weapon_resource='41eac4a03987faa0'; s.row.rounds_chambered=chambered
        s.row.rounds_chamber_token=chambered and 0 or 999
        s.row.rounds_magazine_capacity=8; s.row.rounds_magazine_count=8
        s.continuous_step(0); assert(s.sent()==0)
        s.row.rounds_magazine_count=7; s.continuous_step(.1); assert(s.sent()==1)
    end
    local unknown=configured_scenario(true); unknown.settings.per_round_threshold=3
    unknown.row.current_weapon_resource='dcd1c835407ef7ba'; unknown.row.rounds_chambered=true
    unknown.row.rounds_magazine_capacity=7; unknown.row.rounds_magazine_count=6
    unknown.continuous_step(0); assert(unknown.sent()==0)
end)

test('per-round fire has priority in every threshold mode and with tactical reload off', function()
    for _,tactical in ipairs({true,false}) do
        for _,mode in ipairs({1,2,3}) do
            local s=configured_scenario(tactical); s.settings.per_round_threshold=mode
            s.row.current_weapon_resource='dcd1c835407ef7ba'; s.row.rounds_chambered=true
            s.row.rounds_magazine_capacity=7; s.row.rounds_chamber_token=tactical and 262 or 0
            s.row.rounds_magazine_count=tactical and (mode==1 and 2 or mode==2 and 0 or 5) or 0
            s.hold_fire(true); s.continuous_step(0); s.continuous_step(2)
            assert(s.sent()==0 and not s.state.attempted)
            s.hold_fire(false); s.continuous_step(2.01)
            assert(s.sent()==1 and s.interrupt_flags[1]==false)
            if tactical and mode~=2 then
                s.hold_fire(true); s.continuous_step(3); assert(s.sent()==1)
                s.hold_fire(false); s.continuous_step(3.01); assert(s.sent()==2)
            end
        end
    end
end)

test('every configured per-round weapon defers held fire but AC8 and magazine weapons keep their policy', function()
    for _,resource in ipairs({'7b75e5132ffd4ca6','e6d932be83729076','41eac4a03987faa0',
        '4f749e2ee26f532d','4e310b1fe4c52b52','d323de60855898ac','dcd1c835407ef7ba',
        '90ddc374f4e3d756','006e44327bb953fe','c780bcd79547da0f','df51fe8d62f294be'}) do
        local s=configured_scenario(false); s.row.current_weapon_resource=resource
        s.hold_fire(true); s.continuous_step(0); assert(s.sent()==0,resource)
        s.hold_fire(false); s.continuous_step(.1)
        assert(s.sent()==1 and s.interrupt_flags[1]==false,resource)
    end
    local ac8=configured_scenario(true); ac8.row.current_weapon_resource='a8cffb316f0b5c5f'
    ac8.row.rounds_magazine_count=1; ac8.hold_fire(true); ac8.continuous_step(0)
    assert(ac8.sent()==1 and ac8.interrupt_flags[1]==true)
    local magazine=configured_magazine('84354339522c932d',1,0)
    magazine.hold_fire(true); magazine.step(0)
    assert(magazine.sent()==1 and magazine.interrupt_flags[1]==true)
end)

test('firing resumed during the fresh context read postpones both per-round request paths', function()
    for _,mode in ipairs({1,2}) do
        local s=configured_scenario(true); s.settings.per_round_threshold=mode
        s.row.current_weapon_resource='dcd1c835407ef7ba'; s.row.rounds_chambered=true
        s.row.rounds_chamber_token=262; s.row.rounds_magazine_count=mode==1 and 2 or 0
        s.on_refresh(function() s.hold_fire(true) end)
        s.continuous_step(0); assert(s.sent()==0 and not s.state.attempted)
        s.on_refresh(nil); s.hold_fire(false); s.continuous_step(.1)
        assert(s.sent()==1 and s.interrupt_flags[1]==false)
    end
end)

test('per-round deferral is discarded after refill, focus loss or a changed fresh selection', function()
    for _,change in ipairs({'refill','fresh_refill','focus','missing','identity'}) do
        local s=configured_scenario(true); s.settings.per_round_threshold=3
        s.row.current_weapon_resource='dcd1c835407ef7ba'; s.row.rounds_chambered=true
        s.row.rounds_chamber_token=262; s.row.rounds_magazine_count=5; s.row.rounds_magazine_capacity=7
        s.hold_fire(true); s.continuous_step(0); assert(s.sent()==0)
        local fresh={}; for k,v in pairs(s.row) do fresh[k]=v end
        if change=='refill' then s.row.rounds_magazine_count=6
        elseif change=='fresh_refill' then fresh.rounds_magazine_count=6; s.fresh(fresh)
        elseif change=='focus' then s.focus(false)
        elseif change=='missing' then s.row.context_status='unresolved'
        else fresh.selected_entity_id=2; s.fresh(fresh) end
        s.hold_fire(false); s.continuous_step(.1); assert(s.sent()==0,change)
    end
end)

test('per-round diagnostics log full ammo and fire deferral on changes without repeated full-state lines', function()
    local s=configured_scenario(true); s.settings.per_round_threshold=3; s.logging(true)
    s.row.current_weapon_resource='dcd1c835407ef7ba'; s.row.rounds_chambered=true
    s.row.rounds_chamber_token=262; s.row.rounds_magazine_count=6; s.row.rounds_magazine_capacity=7
    s.row.rounds_selected_magazine=0; s.row.rounds_config_source='entity_override'
    local function diagnostic_lines()
        local lines={}; for _,line in ipairs(s.logs) do
            if line:find('PER_ROUND_STATE',1,true) then lines[#lines+1]=line end
        end; return lines
    end
    s.continuous_step(0); s.continuous_step(1)
    local lines=diagnostic_lines(); assert(#lines==1 and s.sent()==0)
    for _,field in ipairs({'total=7','capacity=7','limit=6','basis=total','eligible=false',
        'chamber_token=262','config_source=entity_override','action=outside_threshold'}) do
        assert(lines[1]:find(field,1,true),field)
    end
    s.row.rounds_magazine_count=5; s.hold_fire(true); s.continuous_step(2); s.continuous_step(3)
    lines=diagnostic_lines(); assert(#lines==2 and s.sent()==0)
    assert(lines[2]:find('action=wait_for_fire_release',1,true))
    s.hold_fire(false); s.continuous_step(3.01)
    lines=diagnostic_lines(); assert(#lines==3 and s.sent()==1)
    assert(lines[3]:find('action=reload_eligible',1,true))
    s.logging(false); s.row.rounds_magazine_count=6; s.continuous_step(4)
    assert(#diagnostic_lines()==3 and s.sent()==1)
    s.logging(true); s.continuous_step(5); assert(#diagnostic_lines()==4 and s.sent()==1)
end)

test('per-round defaults are unchanged and do not affect magazine or AC8 policies', function()
    local s=configured_scenario(true); s.row.current_weapon_resource='41eac4a03987faa0'
    s.row.rounds_magazine_count=9; s.continuous_step(0); assert(s.sent()==0)
    s.row.rounds_magazine_count=8; s.continuous_step(.01); assert(s.sent()==1)
    for _,mode in ipairs({1,2,3}) do
        local m=configured_magazine('84354339522c932d',1,0)
        m.settings.per_round_threshold=mode; m.step(0); assert(m.sent()==1)
    end
end)

test('AC8 one and five round tactical modes remain single-request reloads', function()
    for _,mode in ipairs({1,2}) do
        local s=configured_scenario(true);s.settings.ac8_threshold=mode
        s.row.current_weapon_resource='a8cffb316f0b5c5f'
        local threshold=mode==1 and 0 or 5
        s.row.rounds_magazine_count=threshold+1;s.continuous_step(0);assert(s.sent()==0)
        s.row.rounds_magazine_count=threshold;s.continuous_step(.01);assert(s.sent()==1)
        s.continuous_step(.1);s.continuous_step(2);assert(s.sent()==1)
    end
end)

test('AC8 no tactical or tactical master off requires a fresh fire press after true empty', function()
    for _,tactical in ipairs({false,true}) do
        local s=configured_scenario(tactical);s.settings.ac8_threshold=tactical and 3 or 1
        s.row.current_weapon_resource='a8cffb316f0b5c5f';s.row.rounds_chambered=true
        s.row.rounds_chamber_token=10;s.row.rounds_magazine_count=0
        s.click(0);s.step(0);assert(s.sent()==0)
        s.row.rounds_chamber_token=0;s.step(1);s.step(2);assert(s.sent()==0)
        s.click(2.1);s.step(2.1);assert(s.sent()==1 and s.interrupt_flags[1]==false)
    end
end)

test('retired delays and the renamed preference never delay or disable fire release', function()
    for _,preference in ipairs({true,false}) do
        local s=configured_magazine('84354339522c932d',1,5,preference)
        s.settings.reload_delay=5;s.settings.configurable_timing=true
        s.click(0);s.step(0);assert(s.sent()==1 and s.interrupt_flags[1]==true)
        local empty=configured_scenario(false,5,preference)
        empty.step(0);assert(empty.sent()==1)
    end
end)

test('MG206 never requests at 70 rounds or during a loaded-chamber magazine replacement', function()
    for _,resource in ipairs({'2152d5147b0ac418','cd00bdc1149c2928'}) do
        for _,tactical in ipairs({true,false}) do
            for _,menu in ipairs({true,false}) do
                local s=menu and configured_scenario(tactical,.2) or scenario(tactical)
                s.row.current_weapon_resource=resource; s.row.ammo_path='weapon_magazine'
                s.row.magazine_verified=true; s.row.magazine_chamber_token=275
                for index,count in ipairs({100,77,75,70,65,0}) do
                    s.row.magazine_count=count; s.click(index); s.step(index); s.step(index+.25)
                    assert(s.sent()==0,resource..' rounds='..count)
                end
                s.row.magazine_chamber_token=0; s.step(7); s.step(8); assert(s.sent()==0)
                s.click(8.1); s.step(8.1)
                assert(s.sent()==1)
            end
        end
    end
end)

test('fire interruption excludes stationary and vehicle reloads', function()
    for _,resource in ipairs({'11c27d3babb38956','9f80d67a12a7e40f','2152d5147b0ac418',
        'cd00bdc1149c2928','26e40437ea275296','25aa2fd4643cf4ee','cc786f6491fe7e65',
        'd54b9505c0f72873','e8d5f49ad7780e54'}) do
        local s=scenario(); s.row.current_weapon_resource=resource
        s.step(0); assert(s.sent()==0)
        s.click(.1); s.step(.1)
        assert(s.sent()==1 and s.interrupt_flags[1]==false,resource)
    end
    local s=scenario(); s.row.weapon_context='vehicle'; s.step(0)
    assert(s.sent()==1 and s.interrupt_flags[1]==false)
    local c=scenario(); c.step(0); assert(c.interrupt_flags[1]==true)
end)

test('an interrupted request gets only two delayed retries', function()
    local s=configured_magazine('84354339522c932d',1,0)
    s.interrupted_request(); s.step(0); assert(s.sent()==1)
    s.step(.999); assert(s.sent()==1)
    s.own_key(true); s.step(1); assert(s.sent()==1)
    s.own_key(false); s.allow_send(false); s.step(1.1); assert(s.sent()==1)
    s.allow_send(true); s.step(1.2); assert(s.sent()==2)
    s.step(3.199); assert(s.sent()==2)
    s.step(3.201); assert(s.sent()==3)
    s.step(10); s.step(30); assert(s.sent()==3 and s.state.interrupted_retry_at==nil)
    local ordinary=scenario(); ordinary.step(0); ordinary.step(3)
    assert(ordinary.sent()==1 and ordinary.state.interrupted_retry_at==nil)
end)

test('interruption and retries are cancelled by recovery, identity or focus', function()
    for _,mode in ipairs({'refill','partial','identity','focus','missing'}) do
        local s=configured_magazine('84354339522c932d',1,0)
        s.interrupted_request(); s.step(0)
        s.state.attack_interrupted=true
        if mode=='refill' then s.row.magazine_count=30
        elseif mode=='partial' then s.row.magazine_count=2
        elseif mode=='identity' then s.row.selected_entity_id=2; s.row.magazine_count=30
        elseif mode=='focus' then s.focus(false)
        else s.row.context_status='unresolved' end
        s.step(.2)
        assert(s.state.attack_interrupted==nil and s.state.interrupted_retry_at==nil,mode)
    end
end)

test('mouse release precedes R in the same update and never injects a mouse press', function()
    local ffi=require('ffi')
    local now, focused, held, failed, fail_r = 1000,true,true,false,false
    local events, state = {},{ticks=0,elapsed=0}
    local user={GetForegroundWindow=function() return ffi.cast('void *',1) end,
        GetWindowThreadProcessId=function(_,owner) owner[0]=focused and 123 or 999 end,
        GetAsyncKeyState=function(code) return code==1 and held and -32768 or 0 end,
        SendInput=function(_,input,size)
            assert(size==40); input=ffi.cast('const uint8_t *',input)
            local kind=tonumber(ffi.cast('const uint32_t *',input)[0])
            local flags=tonumber(ffi.cast('const uint32_t *',input+(kind==0 and 20 or 12))[0])
            if kind==0 then assert(flags==4); events[#events+1]='mouse_up'; return failed and 0 or 1 end
            assert(kind==1 and (flags==8 or flags==10))
            events[#events+1]=flags==8 and 'R_down' or 'R_up'
            return flags==8 and fail_r and 0 or 1
        end}
    local kernel={GetCurrentProcess=function() return nil end,GetCurrentProcessId=function() return 123 end,
        GetTickCount64=function() return now end}
    local shim=setmetatable({load=function(name) return name=='user32' and user or kernel end},{__index=ffi})
    local code=assert(source:match('(local function read_api%(%).-)%\nlocal function context_reader'))
    local factory=assert(loadstring(code..'\nreturn read_api()'))
    setfenv(factory,setmetatable({require=function() return shim end,bit=require('bit'),
        debug_emit=function() end,state=state},{__index=_G}))
    local api=factory()
    focused=false; assert(not api.send_reload(true) and #events==0)
    focused=true; failed=true; assert(not api.send_reload(true) and state.attack_interrupted==nil)
    failed=false; fail_r=true
    assert(not api.send_reload(true) and events[2]=='mouse_up' and events[3]=='R_down')
    assert(state.attack_interrupted==true and state.ticks==0 and now==1000)
    fail_r=false; held=false
    local ok,_,interrupted=api.send_reload(true)
    assert(ok and interrupted and events[4]=='R_down' and state.attack_interrupted==nil)
    now=1081; state.ticks=1; assert(api.release_reload() and events[5]=='R_up')
    state.ticks=2; held=true; assert(api.send_reload(false) and events[6]=='R_down')
    now=1162; state.ticks=3; assert(api.release_reload())
    state.ticks=4
    assert(api.send_reload(true) and events[8]=='mouse_up' and events[9]=='R_down')
    now=1243; state.ticks=5; assert(api.release_reload())
    state.ticks=6; local previous=#events
    local allowed,detail=api.send_reload(false,true)
    assert(not allowed and detail=='per_round_fire_held' and #events==previous)
    held=false; assert(api.send_reload(false,true) and events[previous+1]=='R_down')
end)

test('scan-code press spans frames and failed keyup is retried', function()
    local ffi = require('ffi')
    local now, focused, fail_up, events = 1000, true, false, {}
    local stuck_r=false
    local user = {
        GetForegroundWindow=function() return ffi.cast('void *', 1) end,
        GetWindowThreadProcessId=function(_, owner) owner[0]=focused and 123 or 999 end,
        GetAsyncKeyState=function() return stuck_r and -32768 or 0 end,
        SendInput=function(count, input, size)
            assert(count==1 and size==40)
            input=ffi.cast('const uint8_t *',input)
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
        bit=require('bit'), debug_emit=function() end, state={ticks=0,elapsed=0}},{__index=_G}))
    local api=factory()
    local function next_frame() getfenv(factory).state.ticks=getfenv(factory).state.ticks+1 end
    assert(api.key_state(1)==0 and not api.own_reload_active())
    assert(api.send_reload()); assert(#events==1 and events[1]==8 and api.own_reload_active())
    now=1070; assert(api.release_reload()); assert(#events==1)
    now=1081; fail_up=true; assert(not api.release_reload()); assert(events[2]==10)
    assert(not api.send_reload())
    fail_up=false; assert(api.release_reload()); assert(events[3]==10 and not api.own_reload_active())
    focused=false; assert(not api.send_reload()); assert(#events==3)
    focused=true; assert(not api.send_reload()); assert(#events==3)
    next_frame(); assert(api.send_reload()); focused=false
    assert(api.release_reload(true)); assert(events[5]==10)
    focused=true; assert(not api.send_reload()); assert(#events==5)
    next_frame(); stuck_r=true; fail_up=true
    assert(not api.send_reload()); assert(events[6]==10 and not api.own_reload_active())
    fail_up=false; assert(not api.send_reload())
    assert(events[7]==10 and not api.own_reload_active())
    stuck_r=false; assert(not api.send_reload()); assert(#events==7)
    next_frame(); now=now+16; assert(api.send_reload())
    assert(events[8]==8 and api.own_reload_active())
end)
print(string.format('%d tests passed',tests))
