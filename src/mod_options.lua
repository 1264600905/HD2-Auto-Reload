-- Optional Mod Options Menu API 1 integration; either addon may load first.
-- Keep the original build-time timing when the menu is not installed.
local reload_settings = {
    tactical_reload = ENABLE_TACTICAL_RELOAD,
    reload_delay = 0,
    shooting_postpones = true,
    configurable_timing = false,
}
local reload_options = {
    {key='tactical_reload', id='liu.auto_reload.tactical_reload', spec={
        type='toggle', label='启用战术换弹', default=ENABLE_TACTICAL_RELOAD,
        description='开启后按各武器的弹药阈值提前换弹；关闭后仅空仓换弹。站桩换弹武器仍需空仓后重新点击射击。'}},
    {key='reload_delay', id='liu.auto_reload.reload_delay', spec={
        type='slider', label='换弹延迟（秒）', min=0, max=5, step=0.05, default=0,
        description='达到换弹条件后等待的时间，0 表示立即请求换弹。适用于普通、战术和散热器换弹。站桩武器从空仓后的射击点击开始计时。'}},
    {key='shooting_postpones', id='liu.auto_reload.shooting_postpones', spec={
        type='toggle', label='射击推迟下一次换弹', default=true,
        description='开启后，在换弹窗口内每次射击都会重新计算设置的延迟，包括按住射击的连续消耗。关闭后射击不重置等待时间。延迟为 0 时无额外等待。'}},
}
for _, option in ipairs(reload_options) do
    option.spec.mod, option.spec.mod_id = '自动换弹', 'liu.auto_reload'
end

local options_menu, registered_options
local function reset_reload_settings_state()
    -- Applying settings cancels the old weapon's pending timers and retries.
    state.identity, state.empty_since, state.attempted = nil, nil, false
    state.request_at, state.last_request, state.immediate_count = nil, nil, nil
    state.lmb_edge_time, state.last_lmb_press_at = nil, nil
    state.critical_one_requested, state.critical_zero_requested = false, false
    state.tactical_window_since, state.tactical_last_click_at = nil, nil
    state.tactical_seen_click_at, state.tactical_click_tier = nil, nil
    state.tactical_click_generation, state.tactical_sent_generation = nil, nil
    state.reload_window_since, state.reload_wait_since = nil, nil
    state.reload_seen_click_at, state.reload_previous_count = nil, nil
    state.reload_pending_attack, state.reload_shot_generation = nil, nil
    state.continuous_identity, state.continuous_probe_at = nil, nil
    state.speargun_retry_at, state.speargun_retry_count = nil, nil
end

local function sync_mod_options()
    local menu = rawget(_G, 'ModOptionsMenu')
    if type(menu) ~= 'table' or menu.api ~= 1 or
        type(menu.register_option) ~= 'function' or type(menu.get) ~= 'function' then return end
    local changed = false
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
        if registered_options.reload_delay and not reload_settings.configurable_timing then
            reload_settings.configurable_timing, changed = true, true
        end
    end
    -- get() exposes applied values only, also including changes from set().
    for _, option in ipairs(reload_options) do
        if registered_options[option.key] then
            local ok, value = pcall(menu.get, option.id)
            local valid = option.spec.type == 'toggle' and type(value) == 'boolean' or
                option.spec.type == 'slider' and type(value) == 'number' and
                value == value and value >= option.spec.min and value <= option.spec.max
            if ok and valid and reload_settings[option.key] ~= value then
                reload_settings[option.key], changed = value, true
            end
        end
    end
    if changed then
        reset_reload_settings_state()
        emit('OPTIONS_APPLIED tactical_reload=' .. tostring(reload_settings.tactical_reload) ..
            ' reload_delay=' .. tostring(reload_settings.reload_delay) ..
            ' shooting_postpones=' .. tostring(reload_settings.shooting_postpones) ..
            ' configurable_timing=' .. tostring(reload_settings.configurable_timing))
    end
end
