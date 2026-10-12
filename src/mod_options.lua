-- Optional Mod Options Menu API 1 integration. Timing is always immediate.
local reload_settings = {
    tactical_reload = ENABLE_TACTICAL_RELOAD,
    shooting_postpones = true, -- Existing saved preference; renamed only.
    per_round_threshold = 1,
    ac8_threshold = 1,
    logging = false,
}
local TACTICAL_OPTION = 'liu.auto_reload.tactical_reload'
local reload_options = {
    {key='tactical_reload', id=TACTICAL_OPTION, spec={
        type='toggle', label='战术换弹/Tactical Reload', default=ENABLE_TACTICAL_RELOAD,
        description='开启后使用战术阈值；关闭后仍保留打空自动换弹。/ Enables tactical thresholds; empty reload remains active when off.'}},
    {key='logging', id='liu.auto_reload.logging', spec={
        type='toggle', label='日志打印/Logging', default=false,
        description='开启后记录输入、弹药与换弹诊断；关闭后停止本模组日志输出。/ Records input, ammo and reload diagnostics when enabled; disables this mod logging when off.'}},
    {key='shooting_postpones', id='liu.auto_reload.shooting_postpones', spec={
        type='toggle', label='换弹不阻止开火/Reload Does Not Block Firing', default=true,
        description='逐发武器开火时暂停自动换弹，松手后补弹；此项不控制其他武器的主动松键。/ Per-round weapons wait for fire release; this preference does not control automatic fire release on other weapons.'}},
    {key='per_round_threshold', id='liu.auto_reload.per_round_threshold', spec={
        type='choice', label='逐发换弹武器换弹阈值/Per-round Reload Threshold', default=1,
        choices={'默认/Default', '最后一发/Last Round', '第一发/First Shot'},
        description='默认保留原阈值；最后一发按总余弹1发；第一发计入膛内弹。逐发武器松开火后才补弹。/ Default keeps each threshold; Last Round uses one total round; First Shot includes the chamber. Release fire to reload.'}},
    {key='ac8_threshold', id='liu.auto_reload.ac8_threshold', spec={
        type='choice', label='AC-8机炮换弹阈值/AC-8 Reload Threshold', default=1,
        choices={'1发战术换弹/Tactical at 1 Round', '5发战术换弹/Tactical at 5 Rounds', '不战术换弹/No Tactical Reload'},
        description='按弹匣余量触发；不战术换弹或关闭战术总开关后，须打空再按开火才换弹。/ Uses magazine rounds. No Tactical Reload, or the tactical switch off, requires a new fire press after empty.'}},
}
for _, option in ipairs(reload_options) do
    option.spec.mod, option.spec.mod_id = '自动换弹/Auto Reload', 'liu.auto_reload'
end

local options_menu, registered_options
local function reset_reload_settings_state()
    -- Applying settings cancels the old weapon's pending timers and retries.
    state.identity, state.empty_since, state.attempted = nil, nil, false
    state.request_at, state.last_request, state.immediate_count = nil, nil, nil
    state.lmb_edge_time, state.last_lmb_press_at = nil, nil
    state.critical_one_requested, state.critical_zero_requested = false, false
    state.tactical_sent_generation = nil
    state.continuous_identity, state.continuous_probe_at = nil, nil
    state.per_round_debug_key = nil
    state.speargun_retry_at, state.speargun_retry_count = nil, nil
    state.attack_interrupted = nil
    state.interrupted_retry_at, state.interrupted_retry_count, state.interrupted_ammo = nil, nil, nil
end

local function sync_mod_options()
    local menu = rawget(_G, 'ModOptionsMenu')
    if type(menu) ~= 'table' or menu.api ~= 1 or
        type(menu.register_option) ~= 'function' or type(menu.get) ~= 'function' then return end
    local changed, logging_changed = false, false
    if menu ~= options_menu then
        options_menu, registered_options = menu, {}
        for _, option in ipairs(reload_options) do
            local called, ok, reason = pcall(menu.register_option, option.id, option.spec)
            if called and ok == true then
                registered_options[option.key] = true
            else
                emit('OPTIONS_REGISTER_FAILED id=' .. option.id .. ' reason=' .. tostring(called and reason or ok))
            end
        end
    end
    -- get() exposes applied values only, also including changes from set().
    for _, option in ipairs(reload_options) do
        if registered_options[option.key] then
            local ok, value = pcall(menu.get, option.id)
            local valid = option.spec.type == 'toggle' and type(value) == 'boolean' or
                option.spec.type == 'choice' and type(value) == 'number' and value % 1 == 0 and
                value >= 1 and value <= #option.spec.choices
            if ok and valid and reload_settings[option.key] ~= value then
                reload_settings[option.key] = value
                if option.key == 'logging' then logging_changed = true else changed = true end
            end
        end
    end
    DEBUG = reload_settings.logging
    if changed then reset_reload_settings_state() end
    if logging_changed and DEBUG then emit('LOGGING_ENABLED revision=' .. state.revision) end
    if changed or logging_changed or not state.options_logged then
        state.options_logged = true
        emit('OPTIONS_APPLIED tactical_reload=' .. tostring(reload_settings.tactical_reload) ..
            ' reload_delay=0' ..
            ' shooting_postpones=' .. tostring(reload_settings.shooting_postpones) ..
            ' per_round_threshold=' .. tostring(reload_settings.per_round_threshold) ..
            ' ac8_threshold=' .. tostring(reload_settings.ac8_threshold))
    end
end
