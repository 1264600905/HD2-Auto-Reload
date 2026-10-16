-- Regression cases for the actual controller; all input is recorded locally.
local factory=assert(loadfile('tests/test_auto_reload.lua'))
setfenv(factory,setmetatable({AUTO_RELOAD_FIXTURE_ONLY=true},{__index=_G}))
local scenario=factory()
local function rifle(delay)
    local s=scenario(true,nil,delay or 100)
    s.row.current_weapon_resource='708ea298c82093d0'
    s.row.ammo_path='weapon_magazine';s.row.magazine_verified=true
    s.row.magazine_count=1;s.row.magazine_chamber_token=139
    return s
end
local count=0
local function test(name,fn) fn();count=count+1;print('PASS '..name) end

test('FIRE protection starts at the threshold before either bound of the R delay',function()
    for _,delay in ipairs({80,150}) do
        local s=rifle(delay);s.hold_gamepad_fire(true);s.step(0)
        assert(#s.windows==1 and s.windows[1]==0 and s.sent()==0 and s.draws()==1)
        s.step(delay/1000-.0001);assert(s.sent()==0 and #s.windows==1)
        s.step(delay/1000+.0001);assert(s.sent()==1 and s.requests[1].interrupt)
        assert(s.state.reload_episode.attempts==1 and #s.windows==1)
    end
end)

test('periodic checks cannot spam R and the two retries never reopen protection',function()
    local s=rifle();s.step(0);s.step(.1001)
    for _,t in ipairs({.2,.4,.6,.8,1.0}) do s.step(t,true) end
    assert(s.sent()==1 and s.draws()==1 and #s.windows==1)
    s.step(1.101,true);s.step(1.2011);assert(s.sent()==2 and not s.requests[2].interrupt)
    s.step(3.202,true);s.step(3.3021);assert(s.sent()==3 and not s.requests[3].interrupt)
    s.step(8,true);s.step(30,true)
    assert(s.sent()==3 and s.draws()==3 and #s.windows==1)
end)

test('a confirmed reload prevents retries for its full duration',function()
    local s=rifle();s.step(0);s.step(.1001)
    s.row.reload_state_verified=true;s.row.reload_action_active=true
    for _,t in ipairs({.2,1.2,2.2,4.2}) do s.step(t,true) end
    assert(s.sent()==1 and s.draws()==1 and #s.windows==1)
    s.row.reload_action_active=false;s.row.magazine_count=45;s.step(4.3)
    assert(not s.state.reload_episode and not s.state.pending_reload)
    s.row.magazine_count=1;s.step(5)
    assert(#s.windows==2 and s.windows[2]==5)
end)

test('manual reload already in progress is observed without stopping FIRE',function()
    local s=rifle();s.row.reload_state_verified=true;s.row.reload_action_active=true
    s.step(0);s.step(1,true)
    assert(s.sent()==0 and s.draws()==0 and #s.windows==0)
end)

test('reload starting during the final read cancels a queued R',function()
    local s=rifle();s.step(0)
    s.on_refresh(function() s.row.reload_state_verified=true;s.row.reload_action_active=true end)
    s.step(.1001)
    assert(s.sent()==0 and not s.state.pending_reload and #s.windows==1)
end)

test('a delayed or rejected first R cannot renew or outlive the protection window',function()
    local s=rifle();s.step(0);s.allow_send(false);s.step(.1001)
    s.allow_send(true);s.step(.6);s.step(.8,true)
    assert(s.sent()==0 and not s.state.pending_reload and #s.windows==1)
end)

test('fresh-context rejection happens before any FIRE interruption',function()
    local s=rifle();s.fresh({});s.step(0)
    assert(s.sent()==0 and s.draws()==0 and #s.windows==0 and not s.state.reload_episode)
end)

test('recovery and focus loss cancel the pending episode',function()
    for _,kind in ipairs({'ammo','focus'}) do
        local s=rifle();s.step(0)
        if kind=='ammo' then s.row.magazine_count=45 else s.focus(false) end
        s.step(.05);s.step(.2,true)
        assert(s.sent()==0 and not s.state.pending_reload and not s.state.reload_episode)
    end
end)
print(count..' tactical window regression tests passed')
