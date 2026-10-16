local f=assert(io.open('src/mod_options.lua','rb'));local source=f:read('*a');f:close()
local count=0
local function test(name,fn) fn();count=count+1;print('PASS '..name) end
local T='liu.auto_reload.tactical_reload'
local S='liu.auto_reload.shooting_postpones'
local P='liu.auto_reload.per_round_threshold'
local A='liu.auto_reload.ac8_threshold'
local D='liu.auto_reload.reload_delay'
local L='liu.auto_reload.logging'
local B='liu.auto_reload.eruptor_auto_bolt'
local C='liu.auto_reload.periodic_check'
local function binding(tactical,menu)
    local globals={ModOptionsMenu=menu}
    local state={revision='auto-reload-0.6.9',identity='old',attempted=true,empty_since=1,attack_interrupted=true,
        interrupted_retry_at=2,speargun_retry_at=3,continuous_identity='old',per_round_debug_key='old',
        pending_reload={due_at=1},fire_interrupt_identity='old'}
    local logs={}
    local factory=assert(loadstring(source..'\nreturn sync_mod_options,reload_settings'))
    setfenv(factory,setmetatable({_G=globals,state=state,ENABLE_TACTICAL_RELOAD=tactical==true,
        emit=function(line) logs[#logs+1]=line end},{__index=_G}))
    local sync,settings=factory()
    return {sync=sync,settings=settings,state=state,logs=logs,globals=globals}
end
local function mock(values,refused)
    local menu={api=1,version=3,specs={},values=values or {},calls=0}
    menu.register_option=function(id,spec)
        menu.calls=menu.calls+1;if refused==id or refused=='all' then return false,'refused' end
        menu.specs[id]=spec;if menu.values[id]==nil then menu.values[id]=spec.default end;return true
    end
    menu.get=function(id) return menu.values[id] end
    return menu
end
test('without a menu defaults stay intact and timing has no retired menu override',function()
    for _,enabled in ipairs({false,true}) do
        local b=binding(enabled);b.sync()
        assert(b.settings.tactical_reload==enabled and b.settings.reload_delay==nil)
        assert(b.settings.per_round_threshold==1 and b.settings.ac8_threshold==1 and #b.logs==0)
        assert(b.settings.eruptor_auto_bolt==true)
    end
end)
test('seven bilingual options register once and remain visible with tactical reload off',function()
    local menu=mock();local b=binding(false,menu);b.sync();b.sync()
    assert(menu.calls==7 and menu.specs[D]==nil and #b.logs==1)
    assert(menu.specs[B].default==true and menu.specs[B].type=='toggle')
    assert(menu.specs[B].label=='爆裂铳自动拉栓/Eruptor Auto Bolt')
    assert(menu.specs[L].visible_if==nil and menu.specs[L].default==false)
    assert(menu.specs[T].visible_if==nil and menu.specs[T].type=='toggle')
    assert(menu.specs[P].type=='choice' and menu.specs[A].type=='choice')
    assert(menu.specs[S].label=='换弹不阻止开火/Reload Does Not Block Firing')
    for id,spec in pairs(menu.specs) do
        assert(spec.label:find('/',1,true) and spec.mod=='自动换弹/Auto Reload')
        assert(spec.visible_if==nil)
        for _,choice in ipairs(spec.choices or {}) do assert(choice:find('/',1,true)) end
    end
end)
test('saved tactical and shooting flags survive; old delay is ignored',function()
    local b=binding(true,mock({[T]=false,[S]=false,[D]=5,[P]=3,[A]=2}))
    b.sync();assert(not b.settings.tactical_reload and not b.settings.shooting_postpones)
    assert(b.settings.per_round_threshold==3 and b.settings.ac8_threshold==2 and b.settings.reload_delay==nil)
    assert(b.state.identity==nil and b.state.attack_interrupted==nil and b.state.interrupted_retry_at==nil)
    assert(b.state.speargun_retry_at==nil and b.state.continuous_identity==nil)
    assert(b.state.per_round_debug_key==nil and b.state.pending_reload==nil)
    assert(b.state.fire_interrupt_identity==nil)
end)
test('only applied values reset controller state and choices are validated',function()
    local menu=mock();local b=binding(false,menu);b.sync();b.state.identity='current'
    menu.pending={[T]=true};b.sync();assert(b.state.identity=='current')
    menu.values[T]=true;menu.values[P]=2;menu.values[A]=3;b.sync()
    assert(b.settings.tactical_reload and b.settings.per_round_threshold==2 and b.settings.ac8_threshold==3)
    assert(b.state.identity==nil);b.state.identity='current';b.sync();assert(b.state.identity=='current')
    for _,value in ipairs({0,4,1.5,math.huge,0/0,'1',true}) do
        menu.values[P]=value;menu.values[A]=value;b.sync()
        assert(b.settings.per_round_threshold==2 and b.settings.ac8_threshold==3)
    end
end)
test('late menus, refused registrations and older menus preserve safe defaults',function()
    local b=binding(false);b.sync();local menu=mock();b.globals.ModOptionsMenu=menu;b.sync()
    assert(menu.calls==7)
    b=binding(true,mock({[P]=3},'all'));b.sync();b.sync()
    assert(b.settings.tactical_reload and b.settings.per_round_threshold==1 and #b.logs==8)
    assert(b.settings.eruptor_auto_bolt)
    menu=mock({[T]=false,[P]=3,[A]=2});b=binding(true,menu);b.sync()
    assert(menu.calls==7 and not b.settings.tactical_reload)
    assert(b.settings.per_round_threshold==3 and b.settings.ac8_threshold==2 and #b.logs==1)
end)

test('Eruptor switch preserves saved false, validates booleans and cancels pending bolt requests',function()
    local menu=mock({[B]=false});local b=binding(true,menu);b.sync()
    assert(not b.settings.eruptor_auto_bolt and b.settings.tactical_reload)
    b.state.bolt_identity='old';b.state.bolt_requested_at=1;b.state.bolt_attempts=2
    menu.values[B]=true;b.sync()
    assert(b.settings.eruptor_auto_bolt and b.state.bolt_identity==nil)
    assert(b.state.bolt_requested_at==nil and b.state.bolt_attempts==nil)
    menu.values[B]=0;b.sync();assert(b.settings.eruptor_auto_bolt)
    menu.values[T]=false;b.sync();assert(b.settings.eruptor_auto_bolt)
end)
test('logging changes do not rearm or cancel the active reload',function()
    local menu=mock();local b=binding(false,menu);b.sync();b.state.identity='current'
    b.state.interrupted_retry_at=2
    b.state.pending_reload={due_at=3}
    b.state.fire_interrupt_identity='current'
    menu.values[L]=true;b.sync()
    assert(b.settings.logging and b.state.identity=='current' and b.state.interrupted_retry_at==2)
    assert(b.state.pending_reload and b.state.pending_reload.due_at==3)
    assert(b.state.fire_interrupt_identity=='current')
    menu.values[L]=false;b.sync()
    assert(not b.settings.logging and b.state.identity=='current')
end)
test('logging off performs no file open, write, flush or console print',function()
    local f=assert(io.open('src/auto_reload.lua','rb'));local main=f:read('*a');f:close()
    local logging=assert(main:match('(local logger =.-)%-%- MOD_OPTIONS_INSERT'))
    local opens,writes,flushes,prints=0,0,0,0
    local env={DEBUG=false,_G={CowboyBingusModLoader={open_log=function()
        opens=opens+1;return {write=function() writes=writes+1 end,flush=function() flushes=flushes+1 end}
    end}},print=function() prints=prints+1 end}
    setmetatable(env,{__index=_G})
    local factory=assert(loadstring(logging..'\nreturn emit,debug_emit'));setfenv(factory,env)
    local emit,debug_emit=factory();emit('off');debug_emit('off')
    assert(opens==0 and writes==0 and flushes==0 and prints==0)
    env.DEBUG=true;emit('on');debug_emit('on')
    assert(opens==1 and writes==2 and flushes==2 and prints==1)
    env.DEBUG=false;emit('off');debug_emit('off')
    assert(opens==1 and writes==2 and flushes==2 and prints==1)
    env.DEBUG=true;emit('on again');assert(opens==1 and writes==3)
end)
if arg and arg[1] then
    local root,directory=arg[1],assert(arg[2],'isolated test folder required')
    local Text=dofile(root..'/src/bingus_text.lua')
    _G.mom_text={module=Text,locales={en=dofile(root..'/locales/en.lua'),bundled={}}}
    _G.mom_files=setmetatable({}, {__index=function(files,name)
        local chunk=assert(loadfile(root..'/src/'..name..'.lua'));rawset(files,name,chunk);return chunk
    end})
    local function fresh_menu()
        _G.ModOptionsMenu,_G.update,_G.BingusTranslations,_G.BingusRuntime=nil,function() end,nil,nil
        _G.CowboyBingusModLoader={log_directory=directory,open_log=function()
            return {write=function() end,flush=function() end}
        end}
        dofile(root..'/src/mod_options_menu.lua');return assert(ModOptionsMenu)
    end
    local function upvalue(fn,name)
        for i=1,80 do local key,value=debug.getupvalue(fn,i)
            if key==name then return value end;if not key then break end
        end
        error('missing upvalue '..name)
    end
    test('real menu registers bilingual choices, saves them and restores them without the retired delay',function()
        local path=directory..'/ModOptionsMenu.values'
        local f=assert(io.open(path,'wb'));f:write(D..'\t5\n');f:close();os.remove(path..'.bak')
        local menu=fresh_menu();local b=binding(false,menu);b.sync()
        local state=upvalue(menu.register_option,'state')
        assert(state.option_count==7 and #state.mods==1 and state.options[D]==nil)
        local step=upvalue(update,'step')
        local mom=upvalue(upvalue(upvalue(step,'maintain_view'),'build_page'),'mom')
        local function assert_visible_options()
            local current_state=upvalue(menu.register_option,'state')
            local step=upvalue(update,'step')
            local mom=upvalue(upvalue(upvalue(step,'maintain_view'),'build_page'),'mom')
            for _,id in ipairs({T,L,S,P,A,B,C}) do
                assert(current_state.options[id].visible_if==nil)
                if type(mom.option_visible)=='function' then assert(mom.option_visible(current_state.options[id])) end
            end
        end
        assert(not b.settings.tactical_reload);assert_visible_options()
        mom.set_pending(T,true);assert_visible_options()
        mom.set_pending(T,false);assert_visible_options()
        mom.drop_pending()
        assert(menu.set(T,true) and menu.set(S,false) and menu.set(P,3) and menu.set(A,2) and menu.set(L,true) and menu.set(B,false))
        b.sync();assert(b.settings.per_round_threshold==3 and b.settings.ac8_threshold==2)
        local step=upvalue(update,'step');upvalue(step,'save_values')()
        menu=fresh_menu();b=binding(false,menu);b.sync()
        assert(b.settings.tactical_reload and not b.settings.shooting_postpones)
        assert(b.settings.per_round_threshold==3 and b.settings.ac8_threshold==2 and b.settings.reload_delay==nil)
        assert(b.settings.logging and not b.settings.eruptor_auto_bolt)
        assert(menu.set(T,false));b.sync()
        assert(not b.settings.tactical_reload and b.settings.per_round_threshold==3 and b.settings.ac8_threshold==2)
        assert_visible_options()
        for _,suffix in ipairs({'','.bak','.tmp'}) do os.remove(path..suffix) end
    end)
end
print(count..' options integration tests passed')
