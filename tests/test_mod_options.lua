-- Optional API binding and, with arg[1], the real ModOptionsMenu source.
local source=assert(io.open('src/mod_options.lua','rb'))
local options=source:read('*a'); source:close()
local tests=0
local function test(name,fn) fn(); tests=tests+1; print('PASS '..name) end
local function binding(tactical,menu)
    local globals={ModOptionsMenu=menu}
    local state={elapsed=5,identity='old',attempted=true,empty_since=1,request_at=2,
        last_request=2,immediate_count=3,tactical_window_since=1,tactical_click_tier=4,
        tactical_sent_generation=2,reload_wait_since=1,reload_pending_attack=2,
        continuous_identity='old',continuous_probe_at=2,speargun_retry_at=6,speargun_retry_count=1}
    local logs={}
    local factory=assert(loadstring(options..'\nreturn sync_mod_options, reload_settings'))
    setfenv(factory,setmetatable({_G=globals,state=state,ENABLE_TACTICAL_RELOAD=tactical==true,
        emit=function(line) logs[#logs+1]=line end},{__index=_G}))
    local sync,settings=factory()
    return {sync=sync,settings=settings,state=state,logs=logs,globals=globals}
end
local function mock(saved,refused)
    local menu={api=1,specs={},values=saved or {},calls=0}
    menu.register_option=function(id,spec)
        menu.calls=menu.calls+1
        if refused==id or refused=='all' then return false,'full' end
        menu.specs[id]=spec
        if menu.values[id]==nil then menu.values[id]=spec.default end
        return true
    end
    menu.get=function(id) return menu.values[id] end
    return menu
end
local TACTICAL='liu.auto_reload.tactical_reload'
local DELAY='liu.auto_reload.reload_delay'
local SHOOTING='liu.auto_reload.shooting_postpones'

test('missing or incompatible menu preserves build defaults and original timers',function()
    for _,tactical in ipairs({false,true}) do
        local b=binding(tactical)
        b.sync(); assert(b.settings.tactical_reload==tactical and not b.settings.configurable_timing)
        assert(b.state.identity=='old' and b.state.speargun_retry_at==6 and #b.logs==0)
        b.globals.ModOptionsMenu={api=2}; b.sync()
        assert(not b.settings.configurable_timing)
    end
end)

test('late menu registers three Chinese options once in one stable category',function()
    local b=binding(false); b.sync()
    local menu=mock(); b.globals.ModOptionsMenu=menu; b.sync(); b.sync()
    assert(menu.calls==3 and b.settings.configurable_timing)
    assert(menu.specs[TACTICAL].type=='toggle' and menu.specs[TACTICAL].default==false)
    assert(menu.specs[DELAY].type=='slider' and menu.specs[DELAY].min==0 and
        menu.specs[DELAY].max==5 and menu.specs[DELAY].step==.05)
    assert(menu.specs[SHOOTING].default==true)
    for _,spec in pairs(menu.specs) do
        assert(spec.mod=='自动换弹' and spec.mod_id=='liu.auto_reload' and #spec.description>0)
    end
    assert(#b.logs==1)
end)

test('saved values load before gameplay and apply false toggles correctly',function()
    local b=binding(true,mock({[TACTICAL]=false,[DELAY]=1.25,[SHOOTING]=false}))
    b.sync(); assert(b.settings.tactical_reload==false and b.settings.reload_delay==1.25)
    assert(b.settings.shooting_postpones==false and b.settings.configurable_timing)
    assert(b.state.identity==nil and not b.state.attempted and b.state.empty_since==nil)
    assert(b.state.last_request==nil and b.state.tactical_click_tier==nil)
    assert(b.state.reload_pending_attack==nil and b.state.speargun_retry_at==nil)
    assert(b.state.continuous_identity==nil)
end)

test('only applied edits change settings and unchanged polls do not cancel waits',function()
    local menu=mock(); local b=binding(false,menu); b.sync()
    b.state.identity='current'; b.state.reload_wait_since=7
    menu.pending={[DELAY]=2}; b.sync()
    assert(b.settings.reload_delay==0 and b.state.reload_wait_since==7)
    menu.values[DELAY]=2; menu.values[TACTICAL]=true; menu.values[SHOOTING]=false; b.sync()
    assert(b.settings.reload_delay==2 and b.settings.tactical_reload and not b.settings.shooting_postpones)
    assert(b.state.identity==nil and b.state.reload_wait_since==nil and #b.logs==2)
    b.state.identity='new'; b.state.reload_wait_since=9; b.sync()
    assert(b.state.identity=='new' and b.state.reload_wait_since==9 and #b.logs==2)
end)

test('registration refusal keeps defaults and logs once without retrying each frame',function()
    local menu=mock({[TACTICAL]=true,[DELAY]=2},'all'); local b=binding(false,menu)
    b.sync(); b.sync(); assert(menu.calls==3 and #b.logs==3)
    assert(not b.settings.tactical_reload and b.settings.reload_delay==0 and not b.settings.configurable_timing)
    assert(b.state.identity=='old')
    local partial=mock({[TACTICAL]=true},DELAY); b=binding(false,partial); b.sync()
    assert(b.settings.tactical_reload and not b.settings.configurable_timing)
end)

test('bad saved values and failing API functions do not corrupt settings',function()
    local menu=mock(); local b=binding(false,menu); b.sync()
    for _,value in ipairs({-1,6,math.huge,-math.huge,0/0,'1',true}) do
        menu.values[DELAY]=value; b.sync(); assert(b.settings.reload_delay==0)
    end
    menu.values[TACTICAL]='true'; menu.values[SHOOTING]=0; b.sync()
    assert(not b.settings.tactical_reload and b.settings.shooting_postpones)
    menu.get=function() error('read failure') end; b.sync(); assert(b.settings.reload_delay==0)
    menu=mock(); menu.register_option=function() error('registration failure') end
    b=binding(true,menu); b.sync(); b.sync()
    assert(b.settings.tactical_reload and not b.settings.configurable_timing and #b.logs==3)
end)

test('replacement menu gets its own registrations and saved values',function()
    local b=binding(false,mock()); b.sync()
    local replacement=mock({[DELAY]=.75,[TACTICAL]=true,[SHOOTING]=false})
    b.globals.ModOptionsMenu=replacement; b.sync(); b.sync()
    assert(replacement.calls==3 and b.settings.reload_delay==.75 and b.settings.tactical_reload)
    assert(not b.settings.shooting_postpones)
end)

test('built addon binds options at startup or later and forwards the update chain',function()
    local previous={menu=_G.ModOptionsMenu,loader=_G.CowboyBingusModLoader,
        update=_G.update,state=_G.LiuAutoReloadRounds,print=print}
    local lines={}
    _G.CowboyBingusModLoader={open_log=function() return {write=function() end,flush=function() end} end}
    _G.print=function(line) lines[#lines+1]=line end
    for _,early in ipairs({true,false}) do
        local menu=mock({[TACTICAL]=true,[DELAY]=.75,[SHOOTING]=false})
        local calls=0
        _G.ModOptionsMenu=early and menu or nil; _G.LiuAutoReloadRounds=nil
        _G.update=function(dt,extra) calls=calls+1; assert(dt==.1 and extra=='forwarded'); return 'previous' end
        local state=dofile('build/auto_reload_entry.lua')
        assert(state.revision=='auto-reload-0.6.7' and menu.calls==(early and 3 or 0))
        _G.ModOptionsMenu=menu
        assert(update(.1,'forwarded')=='previous' and update(.1,'forwarded')=='previous')
        assert(calls==2 and menu.calls==3 and state.ticks==2)
    end
    _G.ModOptionsMenu,_G.CowboyBingusModLoader,_G.update,_G.LiuAutoReloadRounds,_G.print=
        previous.menu,previous.loader,previous.update,previous.state,previous.print
    assert(table.concat(lines,'\n'):find('OPTIONS_APPLIED tactical_reload=true reload_delay=0.75 shooting_postpones=false',1,true))
end)

-- The optional real-menu check uses an isolated caller-provided values folder.
-- No game update is executed and no input is sent.
if arg and arg[1] then
    local root=arg[1]
    local directory=assert(arg[2],'supply a dedicated test values directory')
    local Text=dofile(root..'/src/bingus_text.lua')
    _G.mom_text={module=Text,locales={en=dofile(root..'/locales/en.lua'),bundled={}}}
    _G.mom_files=setmetatable({}, {__index=function(files,name)
        local chunk=assert(loadfile(root..'/src/'..name..'.lua')); rawset(files,name,chunk); return chunk
    end})
    local function upvalue(fn,wanted)
        for i=1,80 do local name,value=debug.getupvalue(fn,i)
            if name==wanted then return value end
            if name==nil then break end
        end
        error('missing upvalue '..wanted)
    end
    local function fresh_menu()
        _G.ModOptionsMenu,_G.update,_G.BingusTranslations,_G.BingusRuntime=nil,function() end,nil,nil
        Text.registry().steam_language='en'
        _G.CowboyBingusModLoader={log_directory=directory,open_log=function()
            return {write=function() end,flush=function() end}
        end}
        dofile(root..'/src/mod_options_menu.lua')
        return assert(ModOptionsMenu),upvalue(update,'step')
    end
    test('real MOM registers, snaps, saves and restores all three auto reload settings',function()
        local path=directory..'/ModOptionsMenu.values'
        local file=assert(io.open(path,'wb')); file:write(''); file:close()
        os.remove(path..'.bak')
        local menu,step=fresh_menu(); local b=binding(false,menu); b.sync()
        local state=upvalue(menu.register_option,'state')
        assert(state.option_count==3 and #state.mods==1 and state.mods[1].id=='liu.auto_reload')
        assert(state.options[DELAY].label=='换弹延迟（秒）')
        assert(menu.set(TACTICAL,true) and menu.set(DELAY,1.23) and menu.set(SHOOTING,false))
        b.sync(); assert(b.settings.tactical_reload and math.abs(b.settings.reload_delay-1.25)<1e-6)
        assert(not b.settings.shooting_postpones)
        upvalue(step,'save_values')()
        menu=fresh_menu(); b=binding(false,menu); b.sync()
        assert(b.settings.tactical_reload and b.settings.reload_delay==1.25 and not b.settings.shooting_postpones)
        for _,suffix in ipairs({'','.bak','.tmp'}) do os.remove(path..suffix) end
    end)
end
print(tests..' options integration tests passed')
