-- HD2-Addon: mods/liu/auto_reload_rounds

-- Auto Reload: read-only ammo, R/Eruptor input and guarded native fire consumption.
-- The entity/component layout is adapted from etxp/HD2-C4-Quick-Actions
-- (MIT); C4-specific action calls and all memory writes are deliberately removed.
local existing = rawget(_G, 'LiuAutoReloadRounds')
if existing then return existing end

local DEBUG = false -- Controlled by the in-game logging option.
local PERF = false -- Independent, low-frequency performance summaries.
local CONTINUOUS_RELOAD_INTERVAL_SECONDS = 0
local SPEARGUN_RESOURCE = '3828e2051aa9e897'
local SPEARGUN_RETRY_DELAYS = {0.25, 0.5, 1.0}
local INTERRUPTED_RETRY_DELAYS = {1.0, 2.0}
local ERUPTOR_RESOURCE = 'b6aff2195568767f'
local ERUPTOR_BOLT_ABILITY = 2660
local ERUPTOR_BOLT_RETRY_SECONDS = 1
local ERUPTOR_BOLT_MAX_ATTEMPTS = 3
-- RELOAD_CONFIG_INSERT
-- RANDOM_RELOAD_DELAY_INSERT
local state = {revision = 'auto-reload-1.0.10',
    ticks = 0, elapsed = 0, snapshots = 0,
    latest_row = nil,
    lmb_edge_time = nil, empty_since = nil, attempted = false, identity = nil,
    critical_one_requested = false, critical_zero_requested = false}
-- MG-43's earlier crash report remains unresolved. Its guarded Magazine
-- reader path is enabled experimentally at the user's request.
local unsafe_resources = {}
rawset(_G, 'LiuAutoReloadRounds', state)

local logger = rawget(_G, 'CowboyBingusModLoader')
local file, log_dirty, last_log_flush
local function ensure_log()
    if not file and logger and logger.open_log then
        local ok, result = pcall(logger.open_log, 'AutoReloadRounds.log')
        if ok then file = result end
    end
end

local function write_log(line, console)
    ensure_log()
    if console or not file then print('[AutoReload] ' .. line) end
    if file then
        pcall(function() file:write(line .. '\n') end)
        log_dirty = true
    end
end

local function flush_log(force)
    if not file or not log_dirty then return end
    if force or not last_log_flush or state.elapsed - last_log_flush >= 1 then
        pcall(function() file:flush() end)
        last_log_flush, log_dirty = state.elapsed, false
    end
end

local function emit(line)
    if DEBUG then write_log(line, true) end
end

local function debug_emit(line)
    if DEBUG then write_log(line, false) end
end

local perf_clock, perf_timer = os.clock, 'clock'
local function perf_begin()
    if not PERF then return end
    local now = perf_clock()
    state.performance = state.performance or {since=now, stages={}, counters={}}
    return now
end

local function perf_end(name, started)
    if not started or not PERF then return end
    local stages = state.performance.stages
    local stage = stages[name] or {calls=0, total=0, worst=0}
    local duration = (perf_clock() - started) * 1000
    stage.calls, stage.total = stage.calls + 1, stage.total + duration
    stage.worst = math.max(stage.worst, duration)
    stages[name] = stage
end

local function perf_count(name, amount)
    if not PERF then return end
    if not state.performance then perf_begin() end
    local counters = state.performance.counters
    counters[name] = (counters[name] or 0) + (amount or 1)
end

local function perf_report(force)
    local stats = state.performance
    if not stats then return end
    local seconds = perf_clock() - stats.since
    if seconds <= 0 or (not force and seconds < 5) then return end
    local update = stats.stages.update or {calls=0, total=0, worst=0}
    local counters = stats.counters
    write_log(string.format(
        'PERF_SUMMARY revision=%s timer=%s window_s=%.3f updates=%d self_ms_per_s=%.3f avg_update_ms=%.4f worst_update_ms=%.4f reads_per_s=%.1f bytes_per_s=%.1f map_checks=%d map_hits=%d layout_checks=%d context_failures=%d detailed_logging=%s context_status=%s resource=%s',
        state.revision, perf_timer, seconds, update.calls, update.total / seconds,
        update.total / math.max(1, update.calls), update.worst,
        (counters.reads or 0) / seconds, (counters.bytes or 0) / seconds,
        counters.map_checks or 0, counters.map_hits or 0, counters.layout_checks or 0,
        counters.context_failures or 0, tostring(DEBUG),
        tostring(state.latest_row and state.latest_row.context_status),
        tostring(state.latest_row and state.latest_row.current_weapon_resource)), true)
    local fields = {'PERF_STAGES', 'nested_static_in_context=true', 'nested_context_in_control=true'}
    for _, name in ipairs({'options', 'input', 'context', 'static', 'control'}) do
        local stage = stats.stages[name] or {calls=0, total=0, worst=0}
        fields[#fields + 1] = string.format('%s_calls=%d %s_ms_per_s=%.3f %s_worst_ms=%.4f',
            name, stage.calls, name, stage.total / seconds, name, stage.worst)
    end
    write_log(table.concat(fields, ' '), false)
    flush_log(true)
    state.performance = nil
end

-- MOD_OPTIONS_INSERT
local bit = require('bit')
local INVALID = 0xffffffff
-- Catalog IDs plus live local-player Wieldable/Seater observations.
local vehicle_resources = {
    ['1fa1f596769225c2'] = {seat_type=0x2b, seat_index=1, path='weapon_magazine'},
    ['d58ae6a04edb10de'] = {seat_type=0x2c, seat_index=1, path='weapon_magazine'},
    ['df51fe8d62f294be'] = {seat_type=0x0a, seat_index=0, path='weapon_rounds'},
    ['085c1edb038ec24e'] = {seat_type=0x1a, seat_index=4, path='weapon_magazine'},
}

local function u32(bytes, offset)
    assert(bytes and offset >= 0 and offset + 4 <= #bytes, 'short_u32')
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function capacity_from_config(config, selected)
    -- WeaponRounds magazine_capacity is a float vector at +0x48/+0x4c.
    local bits = u32(config, 0x48 + selected * 4)
    local exponent = math.floor(bits / 8388608) % 256
    if bits >= 2147483648 or exponent == 0 or exponent == 255 then return nil end
    local value = (1 + (bits % 8388608) / 8388608) * 2 ^ (exponent - 127)
    if value >= 1 and value <= 100000 and value % 1 == 0 then return value end
end

local hex_bytes = {}
for i = 0, 255 do hex_bytes[i] = string.format('%02x', i) end
local function hex(bytes)
    return (bytes:gsub('.', function(c) return hex_bytes[c:byte()] end))
end

local function resource(bytes)
    local a, b, c, d, e, f, g, h = bytes:byte(1, 8)
    return hex_bytes[h] .. hex_bytes[g] .. hex_bytes[f] .. hex_bytes[e] ..
        hex_bytes[d] .. hex_bytes[c] .. hex_bytes[b] .. hex_bytes[a]
end

local function product_low(a, b)
    return ((a % 65536) * (b % 65536) +
        ((math.floor(a / 65536) * (b % 65536) +
          (a % 65536) * math.floor(b / 65536)) % 65536) * 65536) % 4294967296
end

local function read_api()
    local ffi = require('ffi')
    local cdef_ok, cdef_error = pcall(ffi.cdef, [[
        void *GetModuleHandleA(const char *name);
        void *GetCurrentProcess(void);
        int ReadProcessMemory(void *, const void *, void *, size_t, size_t *);
        uint32_t GetCurrentProcessId(void);
        void *GetForegroundWindow(void);
        uint32_t GetWindowThreadProcessId(void *, uint32_t *);
        uint64_t GetTickCount64(void);
        short GetAsyncKeyState(int key);
    ]])
    debug_emit('DEBUG_FFI_CDEF once=true ok=' .. tostring(cdef_ok) ..
        (cdef_ok and '' or ' error=' .. tostring(cdef_error)))
    local kernel = ffi.load('kernel32')
    local user32 = ffi.load('user32')
    pcall(ffi.cdef, 'uint32_t __stdcall SendInput(uint32_t, const void *, int);')
    pcall(ffi.cdef, [[
        int QueryPerformanceCounter(int64_t *value);
        int QueryPerformanceFrequency(int64_t *value);
    ]])
    local send_input = ffi.cast(
        'uint32_t (__stdcall *)(uint32_t, const void *, int)', user32.SendInput)
    local get_async_key_state = user32.GetAsyncKeyState
    local process = kernel.GetCurrentProcess()
    local process_id = kernel.GetCurrentProcessId()
    -- Each read is copied to an immutable Lua string before the next call.
    local output, count = ffi.new('uint8_t[4096]'), ffi.new('size_t[1]')
    local pointer_value, window_owner = ffi.new('uintptr_t[1]'), ffi.new('uint32_t[1]')
    local counter, frequency = ffi.new('int64_t[1]'), ffi.new('int64_t[1]')
    pcall(function()
        if kernel.QueryPerformanceFrequency(frequency) ~= 0 and tonumber(frequency[0]) > 0 then
            local scale = tonumber(frequency[0])
            perf_timer = 'qpc'
            perf_clock = function()
                kernel.QueryPerformanceCounter(counter)
                return tonumber(counter[0]) / scale
            end
        end
    end)
    local api = {}
    function api.now() return tonumber(kernel.GetTickCount64()) / 1000 end
    function api.module(name)
        local handle = kernel.GetModuleHandleA(name)
        if handle == nil then return nil end
        return tonumber(ffi.cast('uintptr_t', handle))
    end
    function api.pointer(bytes)
        if not bytes or #bytes < 8 then return nil end
        ffi.copy(pointer_value, bytes, 8)
        local number = tonumber(pointer_value[0])
        if number and number >= 65536 and number < 0x800000000000 then return number end
    end
    function api.read(address, size)
        assert(type(address) == 'number' and address >= 65536 and
            address + size < 0x800000000000, 'bad_read_address')
        assert(size > 0 and size <= 4096, 'bad_read_size')
        if PERF then perf_count('reads'); perf_count('bytes', size) end
        count[0] = 0
        if kernel.ReadProcessMemory(process, ffi.cast('const void *', address),
            output, size, count) == 0 or tonumber(count[0]) ~= size then return nil end
        return ffi.string(output, size)
    end
    function api.game_focused()
        local window = user32.GetForegroundWindow()
        if window == nil then return false end
        if user32.GetWindowThreadProcessId(window, window_owner) == 0 then return false end
        return tonumber(window_owner[0]) == tonumber(process_id)
    end
    function api.key_state(code) return tonumber(get_async_key_state(code)) end
    local fire_game, consume_fire, block_fire, release_fire
    function api.bind_fire_input(base)
        -- Build 25480438: Avatar FIRE is {group=2, action=9}. This is the
        -- merged action used by the game, including Steam Input controllers.
        local pe = u32(assert(api.read(base + 0x3c, 4)), 0)
        assert(pe < 0x1000, 'fire_input_pe_offset_invalid')
        local header = assert(api.read(base + pe, 0x60))
        assert(u32(header, 8) == 0x6ab3b43f and u32(header, 0x50) == 0x4744000,
            'fire_input_build_unsupported')
        for _, sig in ipairs({
            {0x585b80, '83f90c771d4c8d0574a4a7ff8bc1418b9480a85b58004903d0ffe248c1e9208bc1c3'},
            {0xa45514, '49bd0200000009000000498bcde85a06b4ff4c8ba42480000000448bc849c1e1054738b421681b0000'},
            {0x12fde90, '40534883ec204c8bd14c8bca488bcae8dc7c28ff33db448bd8418bc1448bc3486bd0614c03da488b15638e020249c1e30543c6841328030000004b899c132c03000043899c1334030000'},
            {0x12fdf0e, '488b0d03f017020f28da41b802000000498bd14883c4205be925f3ffff'},
            {0x12fd250, '48895c240848896c2410488974241848897c24204154415641574883ec20488bf1458be0488bca488bdae8018928ff'},
            {0x12fd3b0, '48896c2418564883ec204c8bd94c8bca488bcae8b88728ff418bb3509b0a0041c1e110440fb7d033c0450bd1'},
            {0x12fd436, '418b4004488d0c4041c784cb387d0a0000000000488b5c2430488b7c2438488b6c24404883c4205ec3'},
            {0x12fa358, '83fa0241b60144887424300f94442431'},
            {0x12fb9e7, '440fb6742430807c2431000f84b50100004584f60f8413eaffff488bd3488bcee8a4190000'},
            {0xaa01f0, '48b90200000026000000'}, -- native Reload Tap, group 2/action 38
            {0xaa020b, '470fb6ac39b81c0000'}, -- reads the merged Reload Tap state
            {0x2643bf4, 'a1db404782222523'}, -- controller weapon selection actions 19/20
            {0x2643c00, '01342ff3ea37c4974bbd5bcd'}, -- weapon slots 1/2/3, actions 22..24
            {0x2643c1c, '36d68f6dbc0c8490'}, -- wheel/cycle actions 29/30
            {0x2643c40, 'f9cc130e'}, -- Reload Tap label identity
        }) do
            assert(hex(assert(api.read(base + sig[1], #sig[2] / 2))) == sig[2],
                string.format('fire_input_layout_mismatch_at_%x', sig[1]))
        end
        consume_fire = ffi.cast('void (*)(void *, uint64_t, float)', base + 0x12fde90)
        block_fire = ffi.cast('void (*)(void *, uint64_t, uint32_t, float)', base + 0x12fd250)
        release_fire = ffi.cast('void (*)(void *, uint64_t)', base + 0x12fd3b0)
        fire_game = base
        return true
    end
    local function native_fire_state()
        if not fire_game then return false end
        local input = api.pointer(api.read(fire_game + 0x347cf18, 8))
        if not input then return false end
        -- 0x328 + (2 * 97 + 9) * 32: current merged FIRE state.
        local bytes = api.read(input + 0x1c88, 1)
        return bytes ~= nil and bytes:byte(1) ~= 0, input
    end
    function api.fire_held()
        return bit.band(api.key_state(0x01), 0x8000) ~= 0 or native_fire_state()
    end
    function api.native_fire_held() return (native_fire_state()) end
    function api.fire_states()
        local mouse_down = bit.band(api.key_state(0x01), 0x8000) ~= 0
        if mouse_down and not DEBUG then return true end
        local native_down = native_fire_state()
        return mouse_down or native_down, native_down
    end
    function api.weapon_switch_pending()
        if not fire_game then return false end
        local input = api.pointer(api.read(fire_game + 0x347cf18, 8))
        if not input then return true end
        -- Actions 19..30 share one contiguous native input array.
        local values = api.read(input + 0x328 + (2 * 97 + 19) * 32, 353)
        if not values then return true end
        for _, offset in ipairs({0, 32, 96, 128, 160, 320, 352}) do
            if values:byte(offset + 1) ~= 0 then return true end
        end
        return false
    end
    function api.fire_block_status()
        if not fire_game then return end
        local input = api.pointer(api.read(fire_game + 0x347cf18, 8))
        if not input then return end
        local header = api.read(input + 0xa9b40, 20)
        if not header then return end
        local capacity = u32(header, 8)
        if capacity == 0 or capacity > 65536 or bit.band(capacity, capacity - 1) ~= 0 then return end
        local entries = api.pointer(header)
        if not entries then return end
        local key, empty, multiplier = 0x20009, u32(header, 12), u32(header, 16)
        for probe = 0, math.min(capacity, 128) - 1 do
            local entry = api.read(entries + ((product_low(key, multiplier) + probe) % capacity) * 8, 8)
            if not entry then return end
            if u32(entry, 0) == empty then return 0, 0 end
            if u32(entry, 0) == key then
                local index, count = u32(entry, 4), api.read(input + 0xa7d34, 4)
                if not count or index >= u32(count, 0) or u32(count, 0) > 1024 then return end
                local block = api.read(input + 0xa7d38 + index * 24, 24)
                local clock = api.read(input + 0xa7d28, 8)
                local scale_bytes = api.read(fire_game + 0x23c7ec0, 4)
                if not block or not clock or not scale_bytes or u32(block, 4) ~= 2 or u32(block, 8) ~= 9 then return end
                local scale = ffi.new('float[1]'); ffi.copy(scale, scale_bytes, 4)
                if scale[0] <= 0 then return end
                local expires = u32(block, 16) + u32(block, 20) * 4294967296
                local now = u32(clock, 0) + u32(clock, 4) * 4294967296
                return u32(block, 0), math.max(0, (expires - now) / tonumber(scale[0]) * 1000)
            end
        end
    end
    local release_at, released_tick, bolt_release_at, bolt_released_tick
    local reload_input
    local RELOAD_TAP = 0x2600000002
    local fire_interrupt_until, fire_interrupt_input, fire_interrupt_native, fire_debug_at
    function api.own_reload_active() return release_at ~= nil end
    function api.reload_input_pending() return reload_input ~= nil end
    function api.own_bolt_active() return bolt_release_at ~= nil end
    local function key_event(up)
        local input = ffi.new('uint8_t[40]')
        ffi.cast('uint32_t *', input)[0] = 1
        -- KEYEVENTF_SCANCODE; R is scan code 0x13. Keep keydown across frames.
        ffi.cast('uint16_t *', input + 10)[0] = 0x13
        ffi.cast('uint32_t *', input + 12)[0] = up and 10 or 8
        debug_emit(string.format('DEBUG_SENDINPUT_BEGIN tick=%d elapsed=%.3f action=%s',
            state.ticks, state.elapsed, up and 'keyup' or 'keydown'))
        local sent = tonumber(send_input(1, input, 40))
        debug_emit(string.format('DEBUG_SENDINPUT_END tick=%d elapsed=%.3f action=%s sent=%s',
            state.ticks, state.elapsed, up and 'keyup' or 'keydown', tostring(sent)))
        return sent == 1
    end
    function api.release_reload(force)
        -- R is a native Tap binding: keyup can create the reload event on the
        -- newly selected weapon. Cancel that event before releasing our key.
        local cancel = force or (release_at and api.weapon_switch_pending())
        if reload_input and (cancel or reload_input.cancelled) and
            (not reload_input.cancelled or api.now() >= reload_input.cancel_until) then
            if api.pointer(api.read(fire_game + 0x347cf18, 8)) == reload_input.input then
                consume_fire(ffi.cast('void *', reload_input.input), ffi.new('uint64_t', RELOAD_TAP), 0)
                block_fire(ffi.cast('void *', reload_input.input), ffi.new('uint64_t', RELOAD_TAP), 1, 0.5)
                reload_input.cancelled = true
                reload_input.cancel_until = api.now() + 0.5
                reload_input.clock = api.read(reload_input.input + 0xa7d28, 8)
                reload_input.frames = 0
                debug_emit('DEBUG_RELOAD_TAP_CANCEL tick=' .. state.ticks .. ' elapsed=' ..
                    string.format('%.3f', state.elapsed) .. ' mode=fixed_time max_ms=500')
            end
        end
        if release_at and (force or api.now() >= release_at) then
            -- Always release our key, even if focus has left the game.
            if key_event(true) then
                release_at, released_tick = nil, state.ticks
                if reload_input then
                    reload_input.clock = api.read(reload_input.input + 0xa7d28, 8)
                    reload_input.frames = 0
                end
                return true
            end
            return false
        end
        return true
    end
    function api.update_reload_input()
        if not reload_input or release_at then return end
        local input = api.pointer(api.read(fire_game + 0x347cf18, 8))
        if input ~= reload_input.input then reload_input = nil; return end
        local clock = api.read(input + 0xa7d28, 8)
        -- Count native input updates, not Lua callbacks, so repeated callbacks
        -- in one game frame cannot remove the guard before keyup is evaluated.
        if clock and clock ~= reload_input.clock then
            reload_input.clock = clock
            reload_input.frames = (reload_input.frames or 0) + 1
        end
        if (reload_input.frames or 0) < 2 then return end
        if reload_input.cancelled then
            consume_fire(ffi.cast('void *', input), ffi.new('uint64_t', RELOAD_TAP), 0)
            release_fire(ffi.cast('void *', input), ffi.new('uint64_t', RELOAD_TAP))
            debug_emit('DEBUG_RELOAD_TAP_DRAINED tick=' .. state.ticks .. ' elapsed=' ..
                string.format('%.3f', state.elapsed) .. ' native_updates=' .. reload_input.frames)
        end
        reload_input = nil
    end
    local function mouse_event(up, bolt)
        local input = ffi.new('uint8_t[40]')
        -- INPUT_MOUSE / LEFTDOWN or LEFTUP. Do not change aim or move the mouse.
        ffi.cast('uint32_t *', input + 20)[0] = up and 4 or 2
        local sent = tonumber(send_input(1, input, 40))
        debug_emit((bolt and (up and 'DEBUG_BOLT_RELEASE' or 'DEBUG_BOLT_PRESS') or 'DEBUG_RELEASE_ATTACK') ..
            ' tick=' .. state.ticks .. ' sent=' .. tostring(sent))
        return sent == 1
    end
    local function consume_native_fire(input, duration)
        if api.pointer(api.read(fire_game + 0x347cf18, 8)) ~= input then
            return false, 'fire_input_owner_changed'
        end
        consume_fire(ffi.cast('void *', input), ffi.new('uint64_t', 0x900000002), duration)
        debug_emit('DEBUG_CONSUME_FIRE tick=' .. state.ticks .. ' action=2:9 seconds=' .. duration)
        return true
    end
    local function block_native_fire(input)
        if api.pointer(api.read(fire_game + 0x347cf18, 8)) ~= input then
            return false, 'fire_input_owner_changed'
        end
        -- Mode 1 blocks until the deadline. consume_fire always installs mode 2,
        -- which the game cancels as soon as the physical input is released.
        block_fire(ffi.cast('void *', input), ffi.new('uint64_t', 0x900000002), 1, 0.5)
        debug_emit('DEBUG_BLOCK_FIRE tick=' .. state.ticks .. ' action=2:9 mode=1 seconds=0.5')
        return true
    end
    local function stop_fire_interrupt(reason)
        if fire_interrupt_native and
            api.pointer(api.read(fire_game + 0x347cf18, 8)) == fire_interrupt_input then
            release_fire(ffi.cast('void *', fire_interrupt_input), ffi.new('uint64_t', 0x900000002))
        end
        if fire_interrupt_until then
            debug_emit('DEBUG_FIRE_INTERRUPT_END tick=' .. state.ticks .. ' reason=' .. reason)
        end
        fire_interrupt_until, fire_interrupt_input, fire_interrupt_native, fire_debug_at = nil, nil, nil, nil
    end
    local function interrupt_fire_frame(expected_input, verify_owner)
        local down, input = native_fire_state()
        if verify_owner and (input ~= expected_input or (input and
            api.pointer(api.read(fire_game + 0x347cf18, 8)) ~= input)) then
            return false, 'fire_input_owner_changed'
        end
        local interrupted = false
        if down and not verify_owner then
            -- Clear the current shot before R. Never replace an active mode-1
            -- window with consume_fire's release-sensitive mode during maintenance.
            local ok, detail = consume_native_fire(input, 0)
            if not ok then return false, detail end
            interrupted = true
        end
        if bit.band(api.key_state(0x01), 0x8000) ~= 0 then
            if not mouse_event(true) then return false, 'attack_release_rejected' end
            interrupted = true
        end
        return true, nil, interrupted, input
    end
    function api.fire_interrupt_active()
        return fire_interrupt_until ~= nil and api.now() < fire_interrupt_until
    end
    function api.begin_fire_interrupt()
        if not api.game_focused() then return false, 'game_not_focused' end
        if api.weapon_switch_pending() then return false, 'weapon_switch_pending' end
        if release_at or reload_input or bolt_release_at then return false, 'input_release_pending' end
        if bit.band(api.key_state(0x52), 0x8000) ~= 0 then return false, 'player_reload_held' end
        if api.fire_interrupt_active() then return true end
        stop_fire_interrupt('expired')
        local ok, detail, interrupted, input = interrupt_fire_frame()
        if not ok then return false, detail end
        if interrupted then state.attack_interrupted = true end
        fire_interrupt_until, fire_interrupt_input = api.now() + 0.5, input
        if input then
            local armed, why = block_native_fire(input)
            fire_interrupt_native = armed
            if not armed then stop_fire_interrupt(why); return false, why end
        end
        debug_emit('DEBUG_FIRE_INTERRUPT_BEGIN tick=' .. state.ticks ..
            ' elapsed=' .. string.format('%.3f', state.elapsed) ..
            ' duration_ms=500 native=' .. tostring(fire_interrupt_native == true) .. ' mode=fixed_time phase=threshold')
        return true
    end
    function api.update_fire_interrupt(force)
        if force then
            stop_fire_interrupt('context_cancelled')
        end
        if not fire_interrupt_until then return true end
        if not api.game_focused() then
            stop_fire_interrupt('focus_lost')
            return true
        end
        if api.now() >= fire_interrupt_until then
            stop_fire_interrupt('expired')
            return true
        end
        local ok, detail = interrupt_fire_frame(fire_interrupt_input, true)
        if detail == 'fire_input_owner_changed' then
            stop_fire_interrupt(detail)
        end
        if DEBUG and fire_interrupt_until and (not fire_debug_at or api.now() - fire_debug_at >= 0.1) then
            fire_debug_at = api.now()
            local mode, remaining = api.fire_block_status()
            debug_emit(string.format('DEBUG_FIRE_BLOCK_STATE tick=%d elapsed=%.3f windows_lmb=%s merged_fire=%s mode=%s remaining_ms=%s',
                state.ticks, state.elapsed, tostring(bit.band(api.key_state(0x01), 0x8000) ~= 0),
                tostring(api.native_fire_held()), tostring(mode), remaining and string.format('%.1f', remaining) or 'nil'))
        end
        return ok, detail
    end
    function api.release_bolt(force)
        if bolt_release_at and (force or api.now() >= bolt_release_at) then
            if not mouse_event(true, true) then return false end
            bolt_release_at, bolt_released_tick = nil, state.ticks
        end
        return true
    end
    function api.send_bolt()
        if not api.game_focused() then return false, 'game_not_focused' end
        if api.fire_interrupt_active() then return false, 'fire_interrupt_active' end
        if release_at or reload_input or bolt_release_at or released_tick == state.ticks or
            bolt_released_tick == state.ticks then return false, 'input_release_pending' end
        if api.fire_held() or
            bit.band(api.key_state(0x52), 0x8000) ~= 0 then return false, 'player_input_held' end
        if not mouse_event(false, true) then return false, 'mouse_down_rejected' end
        bolt_release_at = api.now() + 0.08
        return true, 'mouse_down_accepted_not_bolt_confirmation'
    end
    function api.send_reload(interrupt_fire, defer_while_firing)
        if not api.game_focused() then return false, 'game_not_focused' end
        if api.weapon_switch_pending() then return false, 'weapon_switch_pending' end
        if bolt_release_at or bolt_released_tick == state.ticks then return false, 'bolt_press_pending' end
        if release_at then return false, 'key_release_pending' end
        if reload_input then return false, 'reload_tap_pending' end
        if released_tick == state.ticks then return false, 'keyup_frame_pending' end
        -- Recheck at the input boundary: firing can resume during the ammo read.
        if defer_while_firing and api.fire_held() then
            return false, 'per_round_fire_held'
        end
        -- A previous script can leave an injected R down across a reload.
        -- Always establish a released frame before a fresh automatic press.
        if bit.band(api.key_state(0x52), 0x8000) ~= 0 then
            if not key_event(true) then return false, 'stale_keyup_rejected' end
            released_tick = state.ticks
            -- Let the game observe keyup before retrying keydown next frame.
            return false, 'stale_key_released_retry_next_frame'
        end
        if interrupt_fire then
            if not api.fire_interrupt_active() then return false, 'fire_window_expired' end
            local ok, detail = interrupt_fire_frame(fire_interrupt_input, true)
            if not ok then return false, detail end
        end
        -- The controller already stopped FIRE before the random R delay.
        -- Sending or retrying R must never replace or extend that window.
        local input = api.pointer(api.read(fire_game + 0x347cf18, 8))
        if not input then return false, 'reload_input_unavailable' end
        if not key_event(false) then return false, 'keydown_rejected' end
        reload_input = {input=input}
        release_at = api.now() + 0.08
        local interrupted = interrupt_fire and state.attack_interrupted == true
        state.attack_interrupted = nil
        return true, interrupted and 'keydown_accepted_after_attack_release_not_reload_confirmation' or
            'keydown_accepted_release_after_80ms_not_reload_confirmation', interrupted
    end
    return api
end

local magazine_static_records, component_static_record

local function read_magazine_component(e, row)
    -- Build 25327279 ammo query 0x744d02..0x744db7. No game calls.
    if not e.layouts or not e.layouts.magazine then
        if PERF then perf_count('layout_checks') end
        assert(e.read(e.game + 0x744d02, 7) == '\x48\x8b\x2d\x3f\x19\xbe\x02',
            'magazine_native_signature_mismatch')
        assert(hex(e.read(e.game + 0x744d6c, 76)) ==
            '488b4d38488bdf48c1e30448035d48488b0cf9e8bce9daff80b89c000000007420488b4550488d0c7f807c880800750a837b08000f85b600000032c0e9b1000000833b000f9fc0e9a6000000',
            'magazine_native_layout_mismatch')
        if e.layouts then e.layouts.magazine = true end
    end
    local records = assert(magazine_static_records, 'magazine_maps_not_built')(e, row)
    if not records then row.ammo_status = 'magazine_static_identity_unverified'; return end
    local manager = e.global(0x3326648)
    local index = e.lookup(manager + 0x20, e.weapon_id, 65536)
    if not index then row.ammo_status = 'magazine_component_missing'; return end
    assert(index < 4096, 'magazine_component_index_invalid')
    local registry = e.pointer(manager + 0x38, true)
    assert(e.read(e.pointer(registry + index * 8, true), 24, true) == e.weapon,
        'magazine_component_identity_mismatch')
    local ammo = e.read(e.pointer(manager + 0x48, true) + index * 16, 16, true)
    local runtime = e.read(e.pointer(manager + 0x50, true) + index * 12, 12, true)
    local count, token = u32(ammo, 0), u32(ammo, 8)
    assert(count < 100000, 'magazine_count_invalid')
    row.magazine_count = count
    row.magazine_chamber_token = token
    row.magazine_chamber_blocked = runtime:byte(9) ~= 0
    row.magazine_template_chambered = records.magazine:byte(157) ~= 0
    row.magazine_verified = true
    row.reserve_native_max = u32(records.magazine, 0x94)
    row.reserve_count = u32(runtime, 0)
    assert(row.reserve_native_max <= 1000000 and row.reserve_count <= 1000000, 'magazine_reserve_invalid')
    row.reserve_verified, row.reserve_source = true, 'weapon'
    -- Require BOTH counters empty. This is conservative even if an entity
    -- configuration override changes the static template's chambered flag.
    -- A blocked chamber containing a round is not sufficient to request R.
    row.ammo_status = count == 0 and token == 0 and 'magazine_and_chamber_empty' or 'ammo_present'
    row.ammo_counter_semantics = 'native_magazine_count_and_chamber_token'
end

local function read_heat_component(e, row)
    -- Build 25327279: 0x764ee0 separates action inhibition from Heat +8.
    if not e.layouts or not e.layouts.heat then
        if PERF then perf_count('layout_checks') end
        assert(hex(e.read(e.game + 0x764efa, 7)) == '4c8b15471ebc02',
            'heat_native_manager_mismatch')
        assert(hex(e.read(e.game + 0x764f79, 18)) == '8bc8498b4258488d1449807c9008000f94c0',
            'heat_native_layout_mismatch')
        if e.layouts then e.layouts.heat = true end
    end
    local config = assert(component_static_record, 'heat_maps_not_built')(e, row, 'heat')
    if not config then row.ammo_status = 'heat_static_identity_unverified'; return end
    row.reserve_native_max = u32(config, 0x5c)
    local manager = e.global(0x3326d48)
    local index = e.lookup(manager + 0x28, e.weapon_id, 65536)
    if not index then row.ammo_status = 'heat_component_missing'; return end
    assert(index < 4096, 'heat_component_index_invalid')
    local registry = e.pointer(manager + 0x40, true)
    assert(e.read(e.pointer(registry + index * 8, true), 24, true) == e.weapon,
        'heat_component_identity_mismatch')
    local override = e.lookup(manager + 0x68, e.weapon_id, 65536)
    if override then
        assert(override < 4096, 'heat_override_index_invalid')
        config = e.read(e.pointer(manager + 0xa8, true) + override * 0x250, 0x250, true)
    end
    local runtime = e.read(e.pointer(manager + 0x58, true) + index * 12, 12, true)
    local locked = runtime:byte(9)
    assert(locked == 0 or locked == 1, 'heat_overheat_flag_invalid')
    assert(config:byte(0x51) <= 1 and config:byte(0x91) <= 1, 'heat_config_flags_invalid')
    row.heat_verified = true
    row.heat_overheated = locked == 1
    -- +0x90 prevents automatic cooling/lock clearing in 0x762f60.
    -- Cooling weapons must not discard a usable heat sink just for being hot.
    row.heat_requires_replacement = config:byte(0x51) == 1 and config:byte(0x91) == 1
    row.heat_spares = u32(runtime, 0)
    row.reserve_count = row.heat_spares
    assert(row.reserve_native_max <= 1000000 and row.reserve_count <= 1000000, 'heat_reserve_invalid')
    row.reserve_verified, row.reserve_source = true, 'weapon'
    row.heat_value_bits = hex(runtime:sub(5, 8))
    row.heat_config_source = override and 'entity_override' or 'resource_template'
    row.ammo_status = row.heat_overheated and
        (row.heat_requires_replacement and 'heat_sink_burned_out' or 'heat_cooling_lock') or 'heat_ready'
end

local function read_backpack_reserves(e, row)
    -- Ordinary weapons use their own counter. Zero-capacity support weapons
    -- can instead draw clips from the local avatar's ammunition backpack.
    if row.reserve_verified ~= true or row.reserve_native_max ~= 0 or row.weapon_context == 'vehicle' then return end
    row.reserve_count, row.reserve_source = 0, 'none'
    if row.weapon_mode ~= 'main' then return end
    local inventory = e.global(0x3326738)
    local ii = e.lookup(inventory + 0x28, e.avatar_id, 65536)
    if not ii then return end
    assert(ii < u32(e.read(inventory + 0x14, 4, true), 0) and ii < 4096, 'reserve_inventory_index_invalid')
    assert(e.read(e.pointer(e.pointer(inventory + 0x40, true) + ii * 8, true), 24, true) == e.avatar,
        'reserve_inventory_owner_mismatch')
    local slots = e.read(e.pointer(inventory + 0x50, true) + ii * 48, 16, true)
    if u32(slots, 8) ~= e.weapon_id then return end
    local id = u32(slots, 12)
    if id == 0 or id == INVALID then return end
    row.reserve_verified, row.reserve_source = false, 'backpack'
    if not e.layouts or not e.layouts.backpack then
        if PERF then perf_count('layout_checks') end
        for _, sig in ipairs({
            {0x88085a, '4c8b15875daa02'},
            {0x8808ea, '498b42508b04c8'},
            {0x508e9f, '4c8b90c02bf100'},
            {0x508f11, '4869c1e80000004805002b0000'},
        }) do
            if hex(e.read(e.game + sig[1], #sig[2] / 2)) ~= sig[2] then return end
        end
        if e.layouts then e.layouts.backpack = true end
    end
    local bi = e.lookup(e.owner + 0xf1aeb0, id, 1048576)
    if not bi then return end
    assert(bi < 1048576, 'reserve_backpack_entity_index_invalid')
    local backpack = e.read(e.owner + 0xf32f18 + bi * 24, 24, true)
    assert(u32(backpack, 8) == id and bit.band(backpack:byte(21), 3) == 1,
        'reserve_backpack_identity_mismatch')
    row.reserve_backpack_id = id
    row.reserve_identity = tostring(id) .. ':' .. backpack
    local target = {current_weapon_resource=resource(backpack)}
    local item = component_static_record(e, target, 'item')
    if not item then return end
    row.reserve_backpack_class = u32(item, 0x80)
    if row.reserve_backpack_class ~= 17 and row.reserve_backpack_class ~= 18 then
        row.reserve_verified = true
        return
    end
    if not component_static_record(e, target, 'backpack') then return end
    local manager = e.global(0x33265e8)
    local index = e.lookup(manager + 0x20, id, 65536)
    if not index then return end
    assert(index < u32(e.read(manager + 0x10, 4, true), 0) and index < 4096, 'reserve_backpack_index_invalid')
    assert(e.read(e.pointer(e.pointer(manager + 0x38, true) + index * 8, true), 24, true) == backpack,
        'reserve_backpack_component_mismatch')
    row.reserve_count = u32(e.read(e.pointer(manager + 0x50, true) + index * 8, 4, true), 0)
    assert(row.reserve_count <= 1000000, 'backpack_reserve_invalid')
    row.reserve_verified = true
end

local function read_reload_action(e, row)
    -- Build 25480438: 0x776010 compares effective Reload config +4 against
    -- the wielder's active Ability. Read both identities; never call the game.
    if not e.layouts or not e.layouts.reload then
        if PERF then perf_count('layout_checks') end
        local pe = u32(e.read(e.game + 0x3c, 4), 0)
        if u32(e.read(e.game + pe + 8, 4), 0) ~= 0x6ab3b43f then return end
        for _, sig in ipairs({
            {0x776198, '8b7d0485ff0f84cefeffff8bd3e8b65c05003bc7'},
            {0x4fd25b, '458b4b68418b5b700fafd8'},
            {0x4fd2c2, '488d048048c1e004490383a0000000'},
            {0x4fce2f, '4c8b900028f100'},
            {0x4fce9e, '8b4808488d048948c1e0044805201f0000'},
            {0x7cbeea, '498b42384869c9e0000000807c011000'},
            {0x7cbf0d, '8b04014883c408c3'},
        }) do
            if hex(e.read(e.game + sig[1], #sig[2] / 2)) ~= sig[2] then return end
        end
        if e.layouts then e.layouts.reload = true end
    end
    local manager = e.global(0x3326a70)
    local index = e.lookup(manager + 0x20, e.weapon_id, 65536)
    if not index then return end
    assert(index < 4096, 'reload_component_index_invalid')
    assert(e.read(e.pointer(e.pointer(manager + 0x38, true) + index * 8, true), 24, true) == e.weapon,
        'reload_component_identity_mismatch')
    local override = e.lookup(manager + 0x60, e.weapon_id, 65536)
    local config
    if override then
        assert(override < 4096, 'reload_override_index_invalid')
        config = e.pointer(manager + 0xa0, true) + override * 80
    else
        local entries = e.pointer(e.owner + 0xf12800, true)
        local low, high = u32(e.weapon, 0), u32(e.weapon, 4)
        local first = ((high % 498) * (4294967296 % 498) + low % 498) % 498
        for probe = 0, 127 do
            local entry = e.read(entries + ((first + probe) % 498) * 16, 16, true)
            if entry:sub(1, 8) == e.weapon:sub(1, 8) then
                local template_index = u32(entry, 8)
                assert(template_index < 498, 'reload_template_index_invalid')
                config = entries + 0x1f20 + template_index * 80
                break
            end
            if u32(entry, 0) == 0 and u32(entry, 4) == 0 then break end
        end
    end
    if not config then return end
    local ability = u32(e.read(config + 4, 4, true), 0)
    local actions = e.global(0x3326640)
    local action_index = e.lookup(actions + 0x18, e.avatar_id, 65536)
    if not action_index then return end
    assert(action_index < 4096, 'reload_player_action_index_invalid')
    assert(e.read(e.pointer(e.pointer(actions + 0x30, true) + action_index * 8, true), 24, true) == e.avatar,
        'reload_player_identity_mismatch')
    local action = e.read(e.pointer(actions + 0x38, true) + action_index * 0xe0, 32, true)
    assert(action:byte(17) <= 1, 'reload_action_flag_invalid')
    row.reload_ability, row.reload_player_ability = ability, u32(action, 0)
    row.reload_action_active = ability ~= 0 and action:byte(17) == 1 and row.reload_player_ability == ability
    row.reload_state_verified = true
end

local function read_eruptor_bolt_component(e, row)
    -- Verified on build 25480438 only. Unsupported layouts disable this feature.
    if not e.layouts or not e.layouts.eruptor then
        if PERF then perf_count('layout_checks') end
        local pe = u32(e.read(e.game + 0x3c, 4), 0)
        if u32(e.read(e.game + pe + 8, 4), 0) ~= 0x6ab3b43f then
            row.eruptor_bolt_status = 'unsupported_build'; return
        end
        for _, signature in ipairs({
            {0x777786, '8bc8498b4350448534880f95c0'}, -- Reload flags, stride 4
            {0x77eaa4, '83b8b00400000074c2488b0dbc7fba0241b8000800008bd3e82f8cffff84c074aa'},
            {0x786d4e, 'e86d7bffff84c0745d8bd3e81283ffff'}, -- fire -> bolt action
            {0x50957f, '4c8b90d82bf100'}, -- effective WeaponData template map
            {0x5095f1, '4869c1d00400004805a02d0000'}, -- stride 1232, map bytes 11680
        }) do
            if hex(e.read(e.game + signature[1], #signature[2] / 2)) ~= signature[2] then
                row.eruptor_bolt_status = 'unsupported_layout'; return
            end
        end
        if e.layouts then e.layouts.eruptor = true end
    end
    local function component(rva, map_offset, registry_offset, entity_id, entity_bytes)
        local manager = e.global(rva)
        local index = e.lookup(manager + map_offset, entity_id or e.weapon_id, 65536)
        assert(index and index < 4096, 'eruptor_component_missing_or_invalid')
        assert(e.read(e.pointer(e.pointer(manager + registry_offset, true) + index * 8, true), 24, true) == (entity_bytes or e.weapon),
            'eruptor_component_identity_mismatch')
        return manager, index
    end
    local reload, reload_index = component(0x3326a70, 0x20, 0x38)
    local flags = u32(e.read(e.pointer(reload + 0x50, true) + reload_index * 4, 4, true), 0)
    local data = component(0x3326ce0, 0x30, 0x48)
    local override = e.lookup(data + 0x70, e.weapon_id, 65536)
    local config_address
    if override then
        assert(override < 4096, 'eruptor_config_index_invalid')
        config_address = e.pointer(data + 0xb0, true) + override * 1232
        row.eruptor_config_source = 'entity_override'
    else
        local table_address = e.pointer(e.owner + 0xf12bd8, true)
        local low, high = u32(e.weapon, 0), u32(e.weapon, 4)
        local first = ((high % 730) * (4294967296 % 730) + low % 730) % 730
        for probe = 0, 127 do
            local entry = e.read(table_address + ((first + probe) % 730) * 16, 16, true)
            if entry:sub(1, 8) == e.weapon:sub(1, 8) then
                local index = u32(entry, 8)
                assert(index < 730, 'eruptor_template_index_invalid')
                config_address = table_address + 730 * 16 + index * 1232
                break
            end
            if u32(entry, 0) == 0 and u32(entry, 4) == 0 then break end
        end
        assert(config_address, 'eruptor_config_missing')
        row.eruptor_config_source = 'resource_template'
    end
    local ability = u32(e.read(config_address + 0x4b0, 4, true), 0)
    if ability ~= 2660 then row.eruptor_bolt_status = 'unverified_bolt_ability'; return end
    local actions, action_index = component(0x3326640, 0x18, 0x30)
    local action = e.read(e.pointer(actions + 0x38, true) + action_index * 0xe0, 32, true)
    assert(action:byte(17) <= 1, 'eruptor_action_flag_invalid')
    -- Native reload can run on the wielder's Ability component (0x776010).
    assert(e.avatar_id and e.avatar, 'eruptor_avatar_missing')
    local player_actions, player_action_index = component(0x3326640, 0x18, 0x30, e.avatar_id, e.avatar)
    local player_action = e.read(e.pointer(player_actions + 0x38, true) + player_action_index * 0xe0, 32, true)
    assert(player_action:byte(17) <= 1, 'eruptor_player_action_flag_invalid')
    -- UI stack layout used by Mod Options Menu; fail closed for any open screen.
    local ui = e.global(0x347ce28)
    local stack = e.read(ui + 0x429c, 24, true)
    local depth = u32(stack, 20)
    assert(depth <= 5, 'eruptor_ui_stack_invalid')
    row.eruptor_reload_flags = flags
    row.eruptor_needs_bolt = bit.band(flags, 0x800) ~= 0
    row.eruptor_bolt_ability = ability
    row.eruptor_active_ability = u32(action, 0)
    row.eruptor_action_active = action:byte(17) == 1
    row.eruptor_player_action_active = player_action:byte(17) == 1
    row.eruptor_player_active_ability = u32(player_action, 0)
    row.eruptor_gameplay_input = depth == 0
    row.eruptor_bolt_verified = true
    row.eruptor_bolt_status = row.eruptor_needs_bolt and 'needs_bolt' or 'bolt_ready'
end

local function context_reader(api, game, extend)
    local addresses, values, guard_count, reads, bytes = {}, {}, 0, 0, 0
    local now = api.now and api.now()
    local cache
    if now then
        cache = api._auto_reload_cache
        if not cache or cache.game ~= game or now < cache.layout_at then
            cache = {game=game, layout_at=now, layouts={}, maps={}}
            api._auto_reload_cache = cache
        elseif now - cache.layout_at >= 1 then
            cache.layout_at, cache.layouts = now, {}
        end
    end
    local function read(address, size, guard)
        reads, bytes = reads + 1, bytes + size
        assert(reads <= 768 and bytes <= 32768, 'snapshot_budget')
        local result = assert(api.read(address, size), 'read_unavailable')
        assert(#result == size, 'short_read')
        if guard then
            guard_count = guard_count + 1
            addresses[guard_count], values[guard_count] = address, result
        end
        return result
    end
    local function pointer(address, guard)
        local result = assert(api.pointer(read(address, 8, guard)), 'pointer_unavailable')
        return result
    end
    local function global(rva) return pointer(game + rva, true) end
    local function lookup(address, key, limit)
        local header = read(address, 20, true)
        local count, empty, multiplier = u32(header, 8), u32(header, 12), u32(header, 16)
        assert(count <= limit and (count == 0 or bit.band(count, count - 1) == 0), 'unsupported_map')
        if count == 0 or key == empty or key == INVALID then return nil end
        local table_address = assert(api.pointer(header), 'map_pointer_unavailable')
        for probe = 0, math.min(count, 128) - 1 do
            local row = read(table_address + ((product_low(key, multiplier) + probe) % count) * 8, 8, true)
            local found, index = u32(row, 0), u32(row, 4)
            if found == key then return index ~= INVALID and index or nil end
            if found == empty then return nil end
        end
        error('map_probe_limit')
    end
    local function checked()
        for i = 1, guard_count do
            if read(addresses[i], #values[i]) ~= values[i] then return false end
        end
        return true
    end
    local function finish(row, reason)
        if not checked() then return nil, 'context_changed_during_read' end
        row.context_status = reason
        row.memory_reads, row.memory_bytes = reads, bytes
        return row
    end

    local row = {
        current_weapon = 'UNKNOWN', current_weapon_resource = 'UNKNOWN',
        selected_slot = 'UNKNOWN', selected_entity_id = 'UNKNOWN',
        ammo_path = 'UNKNOWN', ammo_status = 'unresolved',
    }
    local player_manager = global(0x3326468)
    local counts = read(player_manager + 0x84, 8, true)
    if u32(counts, 0) == 0 or u32(counts, 4) == 0 then
        return finish(row, 'waiting_for_local_player')
    end
    local player = read(pointer(player_manager + 0xe8, true), 24, true)
    if bit.band(player:byte(21), 1) == 0 then return finish(row, 'local_player_not_owned') end
    -- Native local-player registry and player-to-avatar accessor 0x606630.
    local player_index = lookup(player_manager + 0xd0, u32(player, 8), 64)
    if player_index ~= 0 then return finish(row, 'local_player_registry_mismatch') end
    local avatar_unit = u32(read(player_manager + 0x3a8, 4, true), 0)
    if avatar_unit == 0x7fff then return finish(row, 'waiting_for_avatar') end

    local owner = global(0x346bf98)
    if cache and cache.owner ~= owner then
        cache.owner, cache.maps, cache.layouts, cache.layout_at = owner, {}, {}, now
    end
    local entity_index = lookup(owner + 0xf22ec8, avatar_unit, 1048576)
    if not entity_index then return finish(row, 'avatar_map_missing') end
    assert(entity_index < 1048576, 'avatar_entity_index_invalid')
    local entity = read(owner + 0xf32f18 + entity_index * 24, 24, true)
    if u32(entity, 16) ~= avatar_unit then return finish(row, 'avatar_unit_mismatch') end
    if bit.band(entity:byte(21), 1) == 0 then return finish(row, 'avatar_not_owned') end
    local entity_id = u32(entity, 8)
    row.local_entity_id = entity_id

    -- Gunner/Pilot reload and passenger fire resolve local-avatar Wieldable
    -- slot 0 via 0x786920. Inventory can retain a different handheld selection.
    local seater = global(0x3326d78)
    local seat_index = lookup(seater + 0x20, entity_id, 65536)
    local weapon_id
    row.weapon_context = 'on_foot'
    if seat_index then
        assert(seat_index < u32(read(seater + 0x10, 4, true), 0) and seat_index < 256,
            'seater_index_invalid')
        assert(read(pointer(pointer(seater + 0x38, true) + seat_index * 8, true), 24, true) == entity,
            'seater_owner_mismatch')
        local seat_address = pointer(seater + 0x48, true) + seat_index * 64
        local seat = read(seat_address, 24, true)
        local seat_flags = read(seat_address + 0x30, 2, true)
        local seat_entity, role = u32(seat, 0), u32(seat, 8)
        -- Native code tests +0x30 and +0x31 as separate bytes. +0x31 can
        -- stay set throughout a stable passenger seat; it is not a transition.
        row.seat_transition, row.seat_passenger_flag = seat_flags:byte(1, 2)
        if row.seat_transition ~= 0 then
            return finish(row, 'vehicle_seat_transition')
        end
        if seat_entity ~= 0 and role ~= 0 then
            row.weapon_context = role == 3 and 'vehicle_passenger' or 'vehicle'
            row.seat_entity_id, row.seat_type, row.seat_role = seat_entity, u32(seat, 4), role
            row.seat_index = u32(seat, 0x14)
            if role ~= 2 and role ~= 3 and role ~= 4 then return finish(row, 'vehicle_role_unsupported') end
            local wield = global(0x3326420)
            local wield_index = lookup(wield + 0x30, entity_id, 65536)
            if not wield_index then return finish(row, 'vehicle_wield_missing') end
            assert(wield_index < 4096, 'wield_index_invalid')
            local selection = read(pointer(wield + 0x60, true) + wield_index * 0x1d0, 8, true)
            weapon_id = u32(selection, 0)
            row.selected_slot = role == 3 and 'passenger_primary' or 'vehicle_primary'
            row._selection_bytes = seat .. seat_flags .. selection
        end
    end
    if not weapon_id then
        local inventory = global(0x3326738)
        local inventory_index = lookup(inventory + 0x28, entity_id, 65536)
        local inventory_count = u32(read(inventory + 0x14, 4, true), 0)
        if not inventory_index or inventory_index >= inventory_count then return finish(row, 'inventory_missing') end
        if read(pointer(pointer(inventory + 0x40, true) + inventory_index * 8, true), 24, true) ~= entity then
            return finish(row, 'inventory_owner_mismatch')
        end
        local inventory_state = read(pointer(inventory + 0x50, true) + inventory_index * 48, 48, true)
        local slot = u32(inventory_state, 0x1c)
        row.selected_slot = slot
        local slot_offsets = {[1] = 0, [2] = 4, [3] = 8, [4] = 16, [5] = 16, [6] = 12}
        if not slot_offsets[slot] then return finish(row, 'no_selected_weapon') end
        weapon_id = u32(inventory_state, slot_offsets[slot])
    end
    row.weapon_mode = 'main'
    if row.weapon_context == 'on_foot' or row.weapon_context == 'vehicle_passenger' then
        -- The native handheld R path calls Wieldable slot 0 with prefer-alt
        -- enabled (0xA7CA42..0xA7CA59). +4 is the active alternate entity,
        -- not an extra magazine on the parent. This covers all underbarrels.
        local wield = global(0x3326420)
        local wield_index = lookup(wield + 0x30, entity_id, 65536)
        if not wield_index then return finish(row, 'handheld_wield_missing') end
        assert(wield_index < 4096, 'wield_index_invalid')
        local selection = read(pointer(wield + 0x60, true) + wield_index * 0x1d0, 8, true)
        local main, alternate = u32(selection, 0), u32(selection, 4)
        if main ~= weapon_id then return finish(row, 'handheld_selection_transition') end
        row._selection_bytes = (row._selection_bytes or '') .. selection
        if alternate ~= 0 and alternate ~= INVALID then
            row.parent_weapon_entity_id = main
            row.weapon_mode, weapon_id = 'underbarrel', alternate
        end
    end
    row.selected_entity_id = weapon_id
    if weapon_id == 0 or weapon_id == INVALID then return finish(row, 'selected_entity_missing') end

    local weapon_index = lookup(owner + 0xf1aeb0, weapon_id, 1048576)
    if not weapon_index then return finish(row, 'weapon_map_missing') end
    assert(weapon_index < 1048576, 'weapon_entity_index_invalid')
    local weapon = read(owner + 0xf32f18 + weapon_index * 24, 24, true)
    if u32(weapon, 8) ~= weapon_id then return finish(row, 'weapon_identity_mismatch') end
    row.current_weapon_resource = resource(weapon)
    row.current_weapon = row.current_weapon_resource
    row.weapon_owned = bit.band(weapon:byte(21), 1) ~= 0
    if row.weapon_context == 'vehicle' then
        local supported = vehicle_resources[row.current_weapon_resource]
        if not supported or supported.seat_type ~= row.seat_type or supported.seat_index ~= row.seat_index then
            return finish(row, 'vehicle_weapon_unsupported')
        end
    elseif vehicle_resources[row.current_weapon_resource] then
        return finish(row, 'vehicle_selection_unverified')
    end
    if unsafe_resources[row.current_weapon_resource] then return finish(row, 'unsafe_resource') end
    if not row.weapon_owned then return finish(row, 'weapon_not_owned') end

    local weapon_manager = global(0x3326660)
    local weapon_component = lookup(weapon_manager + 0x28, weapon_id, 65536)
    if not weapon_component then return finish(row, 'weapon_driver_missing') end
    assert(weapon_component < 4096, 'weapon_driver_index_invalid')
    if read(pointer(pointer(weapon_manager + 0x40, true) + weapon_component * 8, true), 24, true) ~= weapon then
        return finish(row, 'weapon_driver_identity_mismatch')
    end
    local driver_state = read(pointer(weapon_manager + 0x50, true) + weapon_component * 40, 40, true)
    local flags = u32(driver_state, 0)
    row.weapon_driver_flags = string.format('%08x', flags)
    if bit.band(flags, 0x80) ~= 0 then row.ammo_path = 'weapon_magazine'
    elseif bit.band(flags, 0x100) ~= 0 then row.ammo_path = 'weapon_rounds'
    elseif bit.band(flags, 0x400) ~= 0 then row.ammo_path = 'weapon_resource'
    elseif bit.band(flags, 0x200) ~= 0 then row.ammo_path = 'weapon_heat'
    else row.ammo_path = 'no_native_ammo_component' end
    if row.weapon_context == 'vehicle' and
        vehicle_resources[row.current_weapon_resource].path ~= row.ammo_path then
        return finish(row, 'vehicle_ammo_path_mismatch')
    end

    local e = {read=read, pointer=pointer, global=global, lookup=lookup,
        game=game, owner=owner, weapon_id=weapon_id, weapon=weapon,
        avatar_id=entity_id, avatar=entity, cache=cache, now=now,
        layouts=cache and cache.layouts}
    if row.ammo_path == 'weapon_rounds' then
        local rounds_manager = global(0x3326cf0)
        local rounds_index = lookup(rounds_manager + 0x28, weapon_id, 65536)
        if not rounds_index then return finish(row, 'rounds_component_missing') end
        assert(rounds_index < 4096, 'rounds_component_index_invalid')
        if read(pointer(pointer(rounds_manager + 0x40, true) + rounds_index * 8, true), 24, true) ~= weapon then
            return finish(row, 'rounds_component_identity_mismatch')
        end
        local rounds = read(pointer(rounds_manager + 0x50, true) + rounds_index * 24, 24, true)
        local runtime = read(pointer(rounds_manager + 0x58, true) + rounds_index * 20, 20, true)
        local selected = u32(runtime, 4)
        assert(selected <= 1, 'rounds_selected_magazine_invalid')
        row.rounds_selected_magazine = selected
        row.rounds_magazine_count = u32(rounds, 4 + selected * 4)
        row.rounds_chamber_token = u32(rounds, 0x10)
        row.rounds_chamber_blocked = runtime:byte(0x11) ~= 0
        row.ammo_counter_semantics = 'selected_magazine_only_not_backpack_or_chamber'
        row.ammo_status = row.rounds_magazine_count > 0 and 'magazine_nonempty' or 'magazine_empty'
        local config = component_static_record(e, row, 'rounds')
        if config then
            row.reserve_native_max = u32(config, 0x50)
            row.reserve_count = u32(runtime, 0)
            assert(row.reserve_native_max <= 1000000 and row.reserve_count <= 1000000, 'rounds_reserve_invalid')
            row.reserve_verified, row.reserve_source = true, 'weapon'
            local override = lookup(rounds_manager + 0x68, weapon_id, 65536)
            if override then
                assert(override < 4096, 'rounds_override_index_invalid')
                config = read(pointer(rounds_manager + 0xa8, true) + override * 0x88, 0x88, true)
                row.rounds_config_source = 'entity_override'
            else
                row.rounds_config_source = 'resource_template'
            end
        end
        if config then
            row.rounds_chambered = config:byte(0x69) ~= 0
            row.rounds_magazine_capacity = capacity_from_config(config, selected)
            if DEBUG then row.rounds_config_hex = hex(config) end
            if row.rounds_chambered then
                row.ammo_status = row.rounds_chamber_blocked and 'chamber_blocked' or
                    row.rounds_chamber_token == 0 and 'chamber_empty' or 'chamber_ready'
            end
        else
            row.rounds_config_source = 'missing'
        end
    elseif row.ammo_path == 'weapon_resource' then
        row.ammo_status = 'unsupported_resource_component'
    elseif row.ammo_path == 'weapon_heat' then
        read_heat_component(e, row)
    elseif row.ammo_path == 'weapon_magazine' then
        read_magazine_component(e, row)
    else
        row.ammo_status = 'unknown_ammo_path'
    end
    read_backpack_reserves(e, row)
    if (row.ammo_path == 'weapon_magazine' or row.ammo_path == 'weapon_heat') and
        (row.weapon_context == 'on_foot' or row.weapon_context == 'vehicle_passenger') then
        local ok = pcall(read_reload_action, e, row)
        if not ok then row.reload_state_verified = false end
    end
    if row.current_weapon_resource == 'b6aff2195568767f' and
        (row.weapon_context == 'on_foot' or row.weapon_context == 'vehicle_passenger') then
        local ok, reason = pcall(read_eruptor_bolt_component, e, row)
        if not ok then
            row.eruptor_bolt_verified = false
            row.eruptor_bolt_status = 'read_failed:' .. tostring(reason)
        end
    end
    if extend then extend(row) end
    row._weapon_bytes = weapon
    row._weapon_id = weapon_id
    row._game_owner = owner
    row.ammo_action_policy = row.ammo_path == 'weapon_heat' and (row.heat_verified and row.heat_requires_replacement and 'NATIVE_R_ONLY_CANDIDATE' or 'SKIP_COOLING_OR_UNVERIFIED_HEAT') or
        row.ammo_path == 'weapon_magazine' and (row.magazine_verified and 'NATIVE_R_ONLY_CANDIDATE' or 'SKIP_UNVERIFIED_MAGAZINE') or
        row.ammo_path == 'weapon_resource' and 'SKIP_UNSUPPORTED_RESOURCE' or
        row.ammo_path == 'no_native_ammo_component' and 'SKIP_UNKNOWN' or 'NATIVE_R_ONLY_CANDIDATE'
    return finish(row, 'context_observed')
end

local function verify_build(pe)
    assert(pe:sub(1, 4) == 'PE\0\0' and (
        (u32(pe, 8) == 0x6aa96b14 and u32(pe, 0x50) == 0x4770000) or
        (u32(pe, 8) == 0x6ab3b43f and u32(pe, 0x50) == 0x4744000)),
        'unsupported_game_build')
end

local function verify_layout(api, game)
    -- Internal instructions, not function entry points commonly hooked by mods.
    for _,signature in ipairs({
        {0x607200, '488b0561f2d10283b88400000000'}, -- local player global/count
        {0x6066ed, '8b9410a8030000'}, -- avatar unit, player index *32
        {0xfd9c93, '4c8b15fe224902'}, -- owner global
        {0xfd9cc5, '498b9ac82ef200'}, -- unit -> entity map
        {0xfd9d1c, '488d80e3651e00498d04c2'}, -- entity array stride/base
        {0xfd9d83, '498b9ab0aef100'}, -- entity id -> entity map
        {0x9a83e0, '4c8b1551e39702'}, -- inventory global
        {0x9a846f, '488d1440498b42504803d2448b4cd01c'}, -- selected inventory slot
        {0x745db6, '488b1da308be02'}, -- driver global
        {0x744dc2, '4c8b0d271fbe02'}, -- rounds global
        {0x4fddc2, '4869c088000000'}, -- rounds effective config stride
        {0x76307f, '44386f5074640f2f7760725e488b4658c644a80801'}, -- overheat latch set
        {0x7630ac, 'f30f1047640f2fc6723380bf9000000000752a488b4658c644a80800'}, -- latch clear
        {0x4bd05d, '4c8b1d149de602'}, -- Seater global
        {0x4bd090, '498b4338'}, -- Seater entity registry
        {0xa7d83c, '448be849c1e5064c036e48'}, -- Seater state stride/base
        {0xa7f67d, '488b0d9c6d8a02'}, -- Wieldable global in Pilot R path
        {0xa7e7da, '80783000'}, -- Seater transition is a single byte
        {0xa7ebe0, '488b0d39788a024533c9'}, -- passenger Wieldable slot 0
        {0x786945, '448b59384533c98b5940'}, -- Wieldable entity map
        {0x7869f3, '4969cbd00100004b8d04b648c1e0044903c18b0c01890a'}, -- slot stride/base, primary entity
        {0xa7ca42, '488b0dd7998a02488d55d0458b46104533c9c644242001e8c29ed0ff'}, -- handheld R prefers active alternate
        {0x7869c0, '807c243000448bd84d8b4a6074254969cbd00100004b8d04b648c1e0044903c1448b540104443b1548d2cf027405448912eba6'}, -- active alternate at Wieldable +4
    }) do
        assert(hex(assert(api.read(game + signature[1], #signature[2] / 2), 'layout_code_unavailable')) ==
            signature[2], string.format('unsupported_layout_at_%x', signature[1]))
    end
end

local api, game, next_reload_delay_ms
local setup_ok, setup_error = pcall(function()
    api = read_api()
    game = assert(api.module('game.dll'), 'game_module_missing')
    next_reload_delay_ms = make_random_reload_delay(133.5821611111111, 306.24582071126537,
        os.time() + math.floor(api.now() * 1000) + game % 2147483646)
    local dos = assert(api.read(game, 64), 'module_header_unavailable')
    assert(dos:sub(1, 2) == 'MZ', 'module_header_invalid')
    local pe_offset = u32(dos, 0x3c)
    assert(pe_offset < 0x1000, 'module_pe_offset_invalid')
    local pe = assert(api.read(game + pe_offset, 0x60), 'module_pe_unavailable')
    verify_build(pe)
    verify_layout(api, game)
    local fire_ok, fire_error = pcall(api.bind_fire_input, game)
    emit('FIRE_INPUT_SETUP verified=' .. tostring(fire_ok) ..
        (fire_ok and '' or ' reason=' .. tostring(fire_error)))
    emit(string.format('SETUP game_base=0x%X ammo_read_only=true', game))
    -- One known ammo query, identified by the reference project's native
    -- analysis. Capture for offline disassembly only; never execute these bytes.
    local query = api.read(game + 0x744c20, 0x660)
    if query then
        emit('AMMO_QUERY_CODE rva=0x744c20 bytes=' .. hex(query))
    else
        emit('AMMO_QUERY_CODE_UNAVAILABLE')
    end
end)
state.setup_ok, state.setup_error = setup_ok, setup_error
if not setup_ok then emit('SETUP_ERROR error=' .. tostring(setup_error)) end

local function scalar(value)
    if value == nil then return 'nil' end
    return tostring(value):gsub('[%s=]', '_')
end

local function log_row(row, error_message, phase)
    if not DEBUG then return end
    if error_message then
        emit(string.format('CTX_ERROR tick=%d elapsed=%.3f phase=%s error=%s',
            state.ticks, state.elapsed, phase or 'snapshot', scalar(error_message)))
        return
    end
    local fields = {
        'CTX', 'tick=' .. state.ticks, string.format('elapsed=%.3f', state.elapsed),
        'phase=' .. scalar(phase), 'status=' .. scalar(row.context_status),
        'slot=' .. scalar(row.selected_slot), 'entity=' .. scalar(row.selected_entity_id),
        'weapon_context=' .. scalar(row.weapon_context),
        'weapon_mode=' .. scalar(row.weapon_mode),
        'parent_weapon_entity=' .. scalar(row.parent_weapon_entity_id),
        'seat_entity=' .. scalar(row.seat_entity_id), 'seat_type=' .. scalar(row.seat_type),
        'seat_role=' .. scalar(row.seat_role), 'seat_index=' .. scalar(row.seat_index),
        'seat_transition=' .. scalar(row.seat_transition),
        'seat_passenger_flag=' .. scalar(row.seat_passenger_flag),
        'resource=' .. scalar(row.current_weapon_resource), 'weapon=' .. scalar(row.current_weapon),
        'owned=' .. scalar(row.weapon_owned), 'driver_flags=' .. scalar(row.weapon_driver_flags),
        'ammo_path=' .. scalar(row.ammo_path), 'ammo_status=' .. scalar(row.ammo_status),
        'policy=' .. scalar(row.ammo_action_policy), 'mag=' .. scalar(row.rounds_magazine_count),
        'magazine_count=' .. scalar(row.magazine_count),
        'magazine_chamber=' .. scalar(row.magazine_chamber_token),
        'magazine_blocked=' .. scalar(row.magazine_chamber_blocked),
        'reload_verified=' .. scalar(row.reload_state_verified),
        'reload_active=' .. scalar(row.reload_action_active),
        'reload_ability=' .. scalar(row.reload_ability),
        'player_ability=' .. scalar(row.reload_player_ability),
        'bolt_status=' .. scalar(row.eruptor_bolt_status),
        'bolt_flags=' .. scalar(row.eruptor_reload_flags),
        'bolt_action_active=' .. scalar(row.eruptor_action_active),
        'bolt_player_action_active=' .. scalar(row.eruptor_player_action_active),
        'bolt_gameplay_input=' .. scalar(row.eruptor_gameplay_input),
        'magazine_verified=' .. scalar(row.magazine_verified),
        'heat_verified=' .. scalar(row.heat_verified),
        'heat_overheated=' .. scalar(row.heat_overheated),
        'heat_requires_replacement=' .. scalar(row.heat_requires_replacement),
        'heat_spares=' .. scalar(row.heat_spares),
        'reserve_verified=' .. scalar(row.reserve_verified),
        'reserve_count=' .. scalar(row.reserve_count),
        'reserve_source=' .. scalar(row.reserve_source),
        'reserve_native_max=' .. scalar(row.reserve_native_max),
        'reserve_backpack=' .. scalar(row.reserve_backpack_id),
        'reserve_backpack_class=' .. scalar(row.reserve_backpack_class),
        'heat_value_bits=' .. scalar(row.heat_value_bits),
        'heat_config_source=' .. scalar(row.heat_config_source),
        'selected_mag=' .. scalar(row.rounds_selected_magazine),
        'capacity=' .. scalar(row.rounds_magazine_capacity),
        'chamber_token=' .. scalar(row.rounds_chamber_token),
        'chambered=' .. scalar(row.rounds_chambered),
        'chamber_blocked=' .. scalar(row.rounds_chamber_blocked),
        'resource_provider=' .. scalar(row.resource_provider),
        'resource_count=' .. scalar(row.resource_count),
        'counter_semantics=' .. scalar(row.ammo_counter_semantics),
        'config_source=' .. scalar(row.rounds_config_source),
        'data_status=' .. scalar(row.weapon_data_status),
        'function_types=' .. scalar(row.weapon_function_types),
        'weapon_state_flags=' .. scalar(row.weapon_state_flags),
        'reads=' .. scalar(row.memory_reads), 'bytes=' .. scalar(row.memory_bytes),
    }
    emit(table.concat(fields, ' '))
end

-- Exact build-specific Magazine/Rounds/Heat resource maps, independently
-- located through their native getters. Full map and record identity checks.
local static_component_snapshot = function() end
-- STATIC_COMPONENT_READER_INSERT

local function debug_near_empty(row)
    return DEBUG and type(row) == 'table' and
        ((type(row.rounds_magazine_count) == 'number' and row.rounds_magazine_count <= 1) or
         (type(row.magazine_count) == 'number' and row.magazine_count <= 1) or
         row.heat_overheated == true)
end

local function snapshot(phase)
    state.snapshots = state.snapshots + 1
    if not setup_ok then return end
    local trace = DEBUG and (state.empty_since ~= nil or debug_near_empty(state.latest_row))
    if trace then
        debug_emit(string.format('DEBUG_SNAPSHOT_BEGIN tick=%d elapsed=%.3f phase=%s',
            state.ticks, state.elapsed, phase))
    end
    local read_started = PERF and perf_begin()
    local ok, row, reason = pcall(context_reader, api, game)
    if read_started then
        perf_end('context', read_started)
        if not ok or not row then perf_count('context_failures') end
    end
    if trace or debug_near_empty(row) then
        debug_emit(string.format(
            'DEBUG_SNAPSHOT_END tick=%d elapsed=%.3f ok=%s status=%s resource=%s mag=%s chamber=%s',
            state.ticks, state.elapsed, tostring(ok),
            scalar(type(row) == 'table' and row.context_status or reason),
            scalar(type(row) == 'table' and row.current_weapon_resource),
            scalar(type(row) == 'table' and (row.magazine_count or row.rounds_magazine_count)),
            scalar(type(row) == 'table' and (row.magazine_chamber_token or row.rounds_chamber_token))))
    end
    if ok and row then
        state.latest_row = row
        state.latest_at = state.elapsed
        if not state.last_log or state.elapsed - state.last_log >= 0.5 then
            state.last_log = state.elapsed
            log_row(row, nil, phase)
        end
        if unsafe_resources[row.current_weapon_resource] then
            emit('UNSAFE_WEAPON_SKIP resource=' .. row.current_weapon_resource ..
                ' reason=' .. unsafe_resources[row.current_weapon_resource])
            return
        end
        local static_key = tostring(row._game_owner) .. ':' .. tostring(row.current_weapon_resource)
        state.static_seen = state.static_seen or {}
        if row.ammo_path == 'weapon_magazine' and not state.static_seen[static_key] then
            static_component_snapshot(row)
            state.static_seen[static_key] = true
            emit('MAGAZINE_READER resource=' .. row.current_weapon_resource ..
                ' verified=' .. tostring(row.magazine_verified))
        end
    else
        state.latest_row = nil
        log_row(nil, ok and reason or row, phase)
    end
end

local function input_probe()
    local keys = {LMB = 0x01, RMB = 0x02, R = 0x52, F8 = 0x77}
    state.keys = state.keys or {}
    for name, code in pairs(keys) do
        if DEBUG or name == 'LMB' or name == 'R' then
            local value = api.key_state(code) or 0
            local down = bit.band(value, 0x8000) ~= 0
            if state.keys[name] ~= down then
                state.keys[name] = down
                if DEBUG then
                    emit(string.format('INPUT tick=%d elapsed=%.3f name=%s down=%s raw=%d',
                        state.ticks, state.elapsed, name, tostring(down), value))
                    if name == 'F8' and down then
                        state.case_index = (state.case_index or 0) + 1
                        emit(string.format('CASE_MARKER index=%d tick=%d elapsed=%.3f',
                            state.case_index, state.ticks, state.elapsed))
                    end
                end
            end
        end
    end
    local down, native_down
    if api.fire_states then down, native_down = api.fire_states()
    else down = api.fire_held and api.fire_held() or state.keys.LMB == true end
    if DEBUG and api.native_fire_held then
        if native_down == nil then native_down = api.native_fire_held() end
        if state.native_fire_down ~= native_down then
            state.native_fire_down = native_down
            emit(string.format('INPUT tick=%d elapsed=%.3f name=FIRE_NATIVE down=%s',
                state.ticks, state.elapsed, tostring(native_down)))
        end
    end
    if state.fire_down ~= down then
        state.fire_down = down
        if down and not (api.own_bolt_active and api.own_bolt_active()) then
            state.lmb_edge_time, state.last_lmb_press_at = state.elapsed, state.elapsed
            state.lmb_edge_tick, state.lmb_edge_identity = state.ticks, state.identity
        end
        if DEBUG then
            emit('INPUT tick=' .. state.ticks .. ' elapsed=' .. string.format('%.3f', state.elapsed) ..
                ' name=FIRE down=' .. tostring(down))
        end
    end
end

local function truly_empty(row)
    if not row or row.context_status ~= 'context_observed' or
        row.current_weapon_resource == 'UNKNOWN' then return false end
    if row.ammo_path == 'weapon_magazine' then
        return row.magazine_verified == true and row.magazine_count == 0 and
            row.magazine_chamber_token == 0
    end
    if row.ammo_path == 'weapon_heat' then
        return row.heat_verified == true and row.heat_requires_replacement == true and
            row.heat_overheated == true
    end
    if row.ammo_path ~= 'weapon_rounds' then return false end
    if type(row.rounds_chambered) ~= 'boolean' then return false end
    if type(row.rounds_magazine_count) ~= 'number' then return false end
    if row.rounds_chambered then
        return row.rounds_magazine_count == 0 and
            (row.rounds_chamber_token == 0 or row.rounds_chamber_blocked == true)
    end
    return row.rounds_magazine_count == 0
end

local function reload_reserves_available(row)
    if not row or row.reserve_verified ~= true then return false end
    -- Verified mounted weapons without a native spare pool retain their
    -- existing vehicle reload rules; zero is not an empty carried reserve.
    if row.weapon_context == 'vehicle' and row.reserve_native_max == 0 then return true end
    return type(row.reserve_count) == 'number' and row.reserve_count > 0
end

local underbarrel_rounds_rule = {name='Underbarrel', path='weapon_rounds',
    limit=0, basis='total', continuous=true}

local function per_round_weapon(row)
    local rule = row and tactical_rules[row.current_weapon_resource]
    -- Identify the weapon independently of the tactical switch and mode.
    return (rule ~= nil and rule.path == row.ammo_path and rule.continuous == true) or
        (row ~= nil and row.weapon_mode == 'underbarrel' and row.ammo_path == 'weapon_rounds')
end

local AC8_RESOURCE = 'a8cffb316f0b5c5f'
local function attack_only_rule(row)
    if not row then return false end
    return attack_only_resources[row.current_weapon_resource] == true or
        (row.current_weapon_resource == AC8_RESOURCE and
            (not reload_settings.tactical_reload or reload_settings.ac8_threshold == 3))
end

local alternate_rules = {}
local function tactical_rule(row)
    if not reload_settings.tactical_reload or not row then return nil end
    local rule = tactical_rules[row.current_weapon_resource]
    if not rule and row.weapon_mode == 'underbarrel' and row.ammo_path == 'weapon_rounds' then
        -- Unknown underbarrel rounds default to empty reload; the existing
        -- Last Round / First Shot setting can opt into earlier shell loading.
        rule = underbarrel_rounds_rule
    end
    if not rule or rule.path ~= row.ammo_path then return nil end
    if row.current_weapon_resource == AC8_RESOURCE then
        if reload_settings.ac8_threshold == 3 then return nil end
        -- The chamber holds the last round; magazine 0 means one round remains.
        local limit = reload_settings.ac8_threshold == 2 and 5 or 0
        local key = AC8_RESOURCE .. ':' .. limit
        alternate_rules[key] = alternate_rules[key] or {name=rule.name, path=rule.path, limit=limit, immediate=true}
        return alternate_rules[key]
    end
    local mode = reload_settings.per_round_threshold or 1
    if not rule.continuous or mode == 1 then return rule end
    local limit, basis
    if mode == 2 then
        limit, basis = 1, 'total'
    elseif mode == 3 then
        local capacity = row.rounds_magazine_capacity
        if type(capacity) ~= 'number' or capacity < 1 then return nil end
        -- Compare the selected magazine PLUS its chamber against full capacity.
        -- A full capacity-1 magazine with one chambered round is already full.
        limit, basis = capacity - 1, 'total'
    else return rule end
    local key = row.current_weapon_resource .. ':' .. mode .. ':' .. limit
    alternate_rules[key] = alternate_rules[key] or {name=rule.name, path=rule.path,
        limit=limit, basis=basis, continuous=true}
    return alternate_rules[key]
end

local function tactical_ammo_count(row, rule)
    if not rule then return nil end
    if row.ammo_path == 'weapon_magazine' then
        if row.magazine_verified == true and type(row.magazine_count) == 'number' then
            return row.magazine_count
        end
    elseif row.ammo_path == 'weapon_rounds' and
        type(row.rounds_chambered) == 'boolean' and
        type(row.rounds_magazine_count) == 'number' then
        if rule.basis == 'total' then
            if not row.rounds_chambered then return row.rounds_magazine_count end
            if type(row.rounds_chamber_token) == 'number' then
                return row.rounds_magazine_count + (row.rounds_chamber_token ~= 0 and 1 or 0)
            end
        else
            return row.rounds_magazine_count
        end
    end
end

local function rounds_empty(row)
    if not row or row.context_status ~= 'context_observed' or
        row.current_weapon_resource == 'UNKNOWN' or not reload_reserves_available(row) then return false end
    if attack_only_rule(row) then return truly_empty(row) end
    local rule = tactical_rule(row)
    if rule == underbarrel_rounds_rule then return truly_empty(row) end
    if rule then
        local count = tactical_ammo_count(row, rule)
        if count ~= nil then return count <= rule.limit end
    end
    return truly_empty(row)
end

local function observed_round_count(row)
    if row.ammo_path == 'weapon_magazine' and row.magazine_verified == true and
        type(row.magazine_count) == 'number' and type(row.magazine_chamber_token) == 'number' then
        return row.magazine_count + (row.magazine_chamber_token ~= 0 and 1 or 0)
    elseif row.ammo_path == 'weapon_rounds' and type(row.rounds_magazine_count) == 'number' then
        if row.rounds_chambered == false then return row.rounds_magazine_count end
        if row.rounds_chambered == true and type(row.rounds_chamber_token) == 'number' then
            return row.rounds_magazine_count + (row.rounds_chamber_token ~= 0 and 1 or 0)
        end
    end
end

local function per_round_fire_held(row)
    return per_round_weapon(row) and (api.fire_held and api.fire_held() or
        bit.band(api.key_state(0x01) or 0, 0x8000) ~= 0)
end

local function log_per_round_state(row, rule, count, eligible)
    if not DEBUG or not per_round_weapon(row) then
        state.per_round_debug_key = nil
        return
    end
    local held = per_round_fire_held(row)
    local total = observed_round_count(row)
    local action = eligible and (held and 'wait_for_fire_release' or 'reload_eligible') or 'outside_threshold'
    local fields = {
        'resource=' .. scalar(row.current_weapon_resource),
        'entity=' .. scalar(row.selected_entity_id), 'slot=' .. scalar(row.selected_slot),
        'weapon_context=' .. scalar(row.weapon_context),
        'tactical=' .. tostring(reload_settings.tactical_reload),
        'mode=' .. scalar(reload_settings.per_round_threshold or 1),
        'selected_mag=' .. scalar(row.rounds_selected_magazine),
        'mag=' .. scalar(row.rounds_magazine_count),
        'chambered=' .. scalar(row.rounds_chambered),
        'chamber_token=' .. scalar(row.rounds_chamber_token),
        'chamber_blocked=' .. scalar(row.rounds_chamber_blocked),
        'total=' .. scalar(total), 'capacity=' .. scalar(row.rounds_magazine_capacity),
        'config_source=' .. scalar(row.rounds_config_source),
        'basis=' .. scalar(rule and (rule.basis or 'magazine')),
        'count=' .. scalar(count), 'limit=' .. scalar(rule and rule.limit),
        'eligible=' .. tostring(eligible), 'fire=' .. tostring(held), 'action=' .. action,
    }
    local key = table.concat(fields, ' ')
    if key ~= state.per_round_debug_key then
        state.per_round_debug_key = key
        emit(string.format('PER_ROUND_STATE tick=%d elapsed=%.3f ', state.ticks, state.elapsed) .. key)
    end
end

local function fresh_context_matches(row, fresh)
    return rounds_empty(fresh) and fresh.weapon_owned == true and
        fresh.selected_entity_id == row.selected_entity_id and
        fresh.selected_slot == row.selected_slot and
        fresh.ammo_path == row.ammo_path and
        fresh._weapon_bytes == row._weapon_bytes and
        fresh.weapon_context == row.weapon_context and
        fresh._selection_bytes == row._selection_bytes and
        fresh.reserve_identity == row.reserve_identity and
        fresh.local_entity_id == row.local_entity_id and
        fresh.current_weapon_resource == row.current_weapon_resource
end

local function reset_speargun_retries()
    state.speargun_retry_at, state.speargun_retry_count = nil, nil
    state.speargun_retry_identity = nil
end

local function reset_fire_interrupt()
    state.attack_interrupted = nil
    state.interrupted_retry_at, state.interrupted_retry_count, state.interrupted_ammo = nil, nil, nil
    state.interrupted_retry_identity = nil
end

local function reload_identity(row)
    return tostring(row.current_weapon_resource) .. ':' .. tostring(row.selected_entity_id) ..
        ':' .. tostring(row.selected_slot) .. ':' .. tostring(row._weapon_bytes) .. ':' .. tostring(row.local_entity_id) ..
        ':' .. tostring(row.weapon_context) .. ':' .. tostring(row._selection_bytes) .. ':' .. tostring(row.ammo_path) ..
        ':' .. tostring(row.reserve_identity)
end

local function interrupting_weapon(row)
    return row and (row.weapon_context == 'on_foot' or row.weapon_context == 'vehicle_passenger') and
        not attack_only_rule(row) and not per_round_weapon(row) and row.current_weapon_resource ~= AC8_RESOURCE
end

local function reload_request(reason, expected_tactical_count, delay_elapsed, expected_identity)
    if per_round_fire_held(state.latest_row) then return end
    debug_emit(string.format('DEBUG_RELOAD_ENTER tick=%d elapsed=%.3f reason=%s resource=%s',
        state.ticks, state.elapsed, reason,
        tostring(state.latest_row and state.latest_row.current_weapon_resource)))
    if state.attempted and reason ~= 'continuous_load' and reason ~= 'empty_attack' and reason ~= 'empty_retry' and reason ~= 'empty_periodic' and reason ~= 'interrupted_retry' and reason ~= 'tactical_idle' and
        reason ~= 'tactical_last_round' and reason ~= 'tactical_zero' and reason ~= 'tactical_immediate' then
        debug_emit('DEBUG_RELOAD_SKIP reason=already_attempted')
        return
    end
    local immediate = reason == 'tactical_last_round' or reason == 'tactical_zero' or
        reason == 'tactical_immediate' or reason == 'empty_immediate'
    local minimum_interval = immediate and 0 or CONTINUOUS_RELOAD_INTERVAL_SECONDS
    if state.last_request and state.elapsed - state.last_request < minimum_interval then
        debug_emit('DEBUG_RELOAD_SKIP reason=rate_limited')
        return
    end
    if not state.latest_row or unsafe_resources[state.latest_row.current_weapon_resource] then
        debug_emit('DEBUG_RELOAD_SKIP reason=missing_or_unsafe_context')
        return
    end
    if api.weapon_switch_pending and api.weapon_switch_pending() then
        state.pending_reload = nil
        debug_emit('DEBUG_RELOAD_SKIP reason=weapon_switch_pending')
        return
    end
    local identity = reload_identity(state.latest_row)
    local retry = reason == 'interrupted_retry' or reason == 'empty_retry' or reason == 'empty_periodic'
    if (retry and not expected_identity) or (expected_identity and expected_identity ~= identity) or
        (state.reload_episode and state.reload_episode.identity ~= identity) then
        state.pending_reload = nil
        debug_emit('DEBUG_RELOAD_SKIP reason=request_weapon_changed')
        return
    end
    if delay_elapsed and (not state.pending_reload or state.pending_reload.identity ~= identity) then return end
    if api.own_reload_active and api.own_reload_active() then return end
    local interrupt_fire = interrupting_weapon(state.latest_row)
    local episode = state.reload_episode
    if interrupt_fire and episode and episode.attempts > 0 then
        local retry_at = state.latest_row.current_weapon_resource == SPEARGUN_RESOURCE and
            state.speargun_retry_at or state.interrupted_retry_at
        -- Periodic checks and new fire edges cannot bypass the bounded retries.
        if not retry_at or state.elapsed < retry_at then return end
    end
    if not delay_elapsed and state.pending_reload then return end
    -- Verify selection/ammo both before stopping FIRE and before sending R.
    debug_emit(string.format('DEBUG_RELOAD_REFRESH_BEGIN tick=%d elapsed=%.3f',
        state.ticks, state.elapsed))
    local read_started = PERF and perf_begin()
    local ok_read, fresh = pcall(context_reader, api, game)
    if read_started then
        perf_end('context', read_started)
        if not ok_read or not fresh then perf_count('context_failures') end
    end
    debug_emit(string.format('DEBUG_RELOAD_REFRESH_END tick=%d elapsed=%.3f ok=%s status=%s',
        state.ticks, state.elapsed, tostring(ok_read),
        scalar(type(fresh) == 'table' and fresh.context_status or fresh)))
    if not ok_read or not fresh_context_matches(state.latest_row, fresh) or
        reload_identity(fresh) ~= identity then
        state.pending_reload = nil
        debug_emit('DEBUG_RELOAD_SKIP reason=fresh_context_rejected')
        return
    end
    if interrupt_fire and fresh.reload_state_verified and fresh.reload_action_active then
        state.pending_reload = nil
        return
    end
    if expected_tactical_count and
        (tactical_ammo_count(fresh, tactical_rule(fresh)) or math.huge) > expected_tactical_count then
        state.pending_reload = nil
        debug_emit('DEBUG_RELOAD_SKIP reason=last_round_changed')
        return
    end
    if not delay_elapsed then
        if interrupt_fire and not episode then
            local ok, detail = api.begin_fire_interrupt()
            if not ok then
                debug_emit('DEBUG_RELOAD_SKIP reason=' .. tostring(detail))
                return
            end
            episode = {identity=reload_identity(fresh), started_at=state.elapsed, attempts=0}
            state.reload_episode, state.fire_interrupt_identity = episode, episode.identity
        end
        if interrupt_fire and episode.attempts == 0 and not api.fire_interrupt_active() then return end
        local delay_ms = next_reload_delay_ms()
        state.pending_reload = {identity=reload_identity(fresh), reason=reason,
            expected_count=expected_tactical_count, generation=state.last_lmb_press_at or 0,
            started_at=state.elapsed, due_at=state.elapsed + delay_ms / 1000, delay_ms=delay_ms}
        state.last_reload_delay_ms = delay_ms
        emit(string.format('RELOAD_DELAY_QUEUED tick=%d elapsed=%.3f delay_ms=%d reason=%s mag=%s chamber=%s',
            state.ticks, state.elapsed, delay_ms, reason,
            tostring(fresh.magazine_count or fresh.rounds_magazine_count),
            tostring(fresh.magazine_chamber_token or fresh.rounds_chamber_token)))
        return
    end
    if interrupt_fire and (not episode or (episode.attempts == 0 and not api.fire_interrupt_active())) then
        state.pending_reload = nil
        debug_emit('DEBUG_RELOAD_SKIP reason=fire_window_expired_before_first_R')
        return
    end
    debug_emit(string.format('DEBUG_RELOAD_SEND_BEGIN tick=%d elapsed=%.3f',
        state.ticks, state.elapsed))
    local per_round = reason == 'continuous_load' or per_round_weapon(fresh)
    local ok, detail = api.send_reload(interrupt_fire and episode.attempts == 0, per_round)
    if not ok and (detail == 'per_round_fire_held' or detail == 'weapon_switch_pending') then
        state.pending_reload = nil
    end
    debug_emit(string.format('DEBUG_RELOAD_SEND_END tick=%d elapsed=%.3f ok=%s detail=%s',
        state.ticks, state.elapsed, tostring(ok), tostring(detail)))
    emit(string.format(
        'RELOAD_REQUEST tick=%d elapsed=%.3f reason=%s sent=%s detail=%s resource=%s mag=%s chamber=%s',
        state.ticks, state.elapsed, reason, tostring(ok), tostring(detail),
        tostring(fresh.current_weapon_resource),
        tostring(fresh.magazine_count or fresh.rounds_magazine_count),
        tostring(fresh.magazine_chamber_token or fresh.rounds_chamber_token)))
    if ok then
        if interrupt_fire then episode.attempts = episode.attempts + 1 end
        state.last_request_identity, state.reload_key_identity = identity, identity
        state.last_request = state.elapsed
        state.attempted = true; state.request_at = state.elapsed
        if interrupt_fire and fresh.current_weapon_resource ~= SPEARGUN_RESOURCE then
            state.interrupted_retry_count = episode.attempts - 1
            local delay = INTERRUPTED_RETRY_DELAYS[state.interrupted_retry_count + 1]
            state.interrupted_retry_at = delay and state.elapsed + delay or nil
            state.interrupted_retry_identity = identity
            state.interrupted_ammo = observed_round_count(fresh)
        end
        if fresh.current_weapon_resource == SPEARGUN_RESOURCE and truly_empty(fresh) then
            -- SendInput acceptance does not confirm that the game began loading.
            -- Retry this single-shot weapon only a finite number of times.
            state.speargun_retry_count = reason == 'empty_retry' and
                (state.speargun_retry_count or 0) + 1 or 0
            local delay = SPEARGUN_RETRY_DELAYS[state.speargun_retry_count + 1]
            state.speargun_retry_at = delay and state.elapsed + delay or nil
            state.speargun_retry_identity = identity
        end
    end
    return ok
end

local function auto_reload_step(periodic_check)
    local row = state.latest_row
    if not row or row.context_status ~= 'context_observed' or
        (row.ammo_path ~= 'weapon_rounds' and row.ammo_path ~= 'weapon_magazine' and row.ammo_path ~= 'weapon_heat') or row.weapon_owned ~= true or
        (row.ammo_path == 'weapon_heat' and (row.heat_verified ~= true or row.heat_requires_replacement ~= true)) or
        not state.latest_at or state.elapsed - state.latest_at > 0.25 or
        unsafe_resources[row.current_weapon_resource] or not api.game_focused() then
        state.identity, state.empty_since, state.attempted = nil, nil, false
        state.empty_tick = nil
        state.lmb_edge_time, state.request_at = nil, nil
        state.lmb_edge_tick, state.lmb_edge_identity, state.last_lmb_press_at = nil, nil, nil
        state.last_request_identity = nil
        state.switch_cancelled_identity, state.switch_cancelled_at, state.switch_cancelled_ammo = nil, nil, nil
        state.critical_one_requested = false
        state.critical_zero_requested = false
        state.tactical_sent_generation = nil
        state.per_round_debug_key = nil
        state.pending_reload = nil
        state.reload_episode = nil
        reset_speargun_retries()
        reset_fire_interrupt()
        return
    end
    local identity = reload_identity(row)
    if identity ~= state.identity or (state.reload_episode and state.reload_episode.identity ~= reload_identity(row)) then
        state.pending_reload = nil
        state.reload_episode = nil
        state.identity, state.empty_since, state.attempted = identity, nil, false
        state.empty_tick = nil
        state.request_at, state.last_request = nil, nil
        state.last_request_identity = nil
        state.switch_cancelled_identity, state.switch_cancelled_at, state.switch_cancelled_ammo = nil, nil, nil
        state.lmb_edge_time, state.last_lmb_press_at = nil, nil
        state.lmb_edge_tick, state.lmb_edge_identity = nil, nil
        state.continuous_identity, state.continuous_probe_at = nil, nil
        state.immediate_count = nil
        state.critical_one_requested = false
        state.critical_zero_requested = false
        state.tactical_sent_generation = nil
        reset_speargun_retries()
        reset_fire_interrupt()
        emit('WEAPON_CONTEXT resource=' .. tostring(row.current_weapon_resource) ..
            ' entity=' .. tostring(row.selected_entity_id) .. ' policy=' .. row.ammo_path)
    end
    if state.weapon_switch_pending then
        if state.pending_reload or state.reload_episode or state.attempted or
            state.interrupted_retry_at or state.speargun_retry_at then
            state.switch_cancelled_identity, state.switch_cancelled_at = identity, state.elapsed
            state.switch_cancelled_ammo = observed_round_count(row)
            emit('RELOAD_CANCELLED_WEAPON_SWITCH tick=' .. state.ticks .. ' elapsed=' ..
                string.format('%.3f', state.elapsed) .. ' resource=' .. tostring(row.current_weapon_resource))
        end
        state.pending_reload, state.reload_episode = nil, nil
        state.attempted, state.request_at = false, nil
        state.empty_since, state.empty_tick = nil, nil
        state.lmb_edge_time, state.last_lmb_press_at = nil, nil
        state.lmb_edge_tick, state.lmb_edge_identity = nil, nil
        reset_speargun_retries()
        reset_fire_interrupt()
        if api.update_fire_interrupt then api.update_fire_interrupt(true) end
        return
    end
    local rule = tactical_rule(row)
    local count = tactical_ammo_count(row, rule)
    local eligible = rounds_empty(row)
    local ammo = observed_round_count(row)
    log_per_round_state(row, rule, count, eligible)
    if state.switch_cancelled_identity == identity then
        local fired = state.last_lmb_press_at and state.last_lmb_press_at > state.switch_cancelled_at
        local consumed = ammo and state.switch_cancelled_ammo and ammo < state.switch_cancelled_ammo
        if eligible and not fired and not consumed then return end
        state.switch_cancelled_identity, state.switch_cancelled_at, state.switch_cancelled_ammo = nil, nil, nil
        state.immediate_count, state.critical_one_requested, state.critical_zero_requested = nil, false, false
        state.tactical_sent_generation = nil
    end
    if not eligible or (state.interrupted_ammo and ammo and ammo > state.interrupted_ammo) then
        reset_fire_interrupt()
    end
    if not eligible then state.reload_episode = nil end
    if not eligible then state.immediate_count = nil end
    if count ~= 1 then state.critical_one_requested = false end
    if not rule or rule.limit ~= 0 or count ~= 0 then
        state.critical_zero_requested = false
    end
    if eligible then
        if not state.empty_since then
            state.empty_since = state.elapsed
            state.empty_tick = state.ticks
            emit('EMPTY_BEGIN tick=' .. state.ticks .. ' elapsed=' .. string.format('%.3f', state.elapsed) ..
                ' resource=' .. tostring(row.current_weapon_resource) ..
                ' mag=' .. tostring(row.magazine_count or row.rounds_magazine_count) ..
                ' chamber=' .. tostring(row.magazine_chamber_token or row.rounds_chamber_token))
        end
        if interrupting_weapon(row) and row.reload_state_verified and row.reload_action_active then
            state.pending_reload = nil
            if state.reload_episode and not state.reload_episode.loading then
                state.reload_episode.loading = true
                emit('RELOAD_ACTION_CONFIRMED tick=' .. state.ticks ..
                    ' elapsed=' .. string.format('%.3f', state.elapsed) .. ' ability=' .. tostring(row.reload_ability))
            end
            return
        end
        if state.reload_episode then state.reload_episode.loading = false end
        if state.request_at and state.elapsed - state.request_at >= 8 then
            emit('RELOAD_UNCONFIRMED reason=still_empty_after_8_seconds retry=press_attack')
            state.request_at = nil
        end
        if state.interrupted_retry_at and state.elapsed >= state.interrupted_retry_at and
            not (api.own_reload_active and api.own_reload_active()) then
            reload_request('interrupted_retry', nil, false, state.interrupted_retry_identity)
            return
        end
        if row.current_weapon_resource == SPEARGUN_RESOURCE and truly_empty(row) and
            state.speargun_retry_at and state.elapsed >= state.speargun_retry_at and
            not (api.own_reload_active and api.own_reload_active()) then
            reload_request('empty_retry', nil, false, state.speargun_retry_identity)
            return
        end
        local attack_only = attack_only_rule(row)
        if not attack_only and rule and rule.immediate and count then
            local fresh_attack = state.last_lmb_press_at and state.last_request and
                state.last_lmb_press_at > state.last_request
            if (state.immediate_count == nil or count < state.immediate_count or fresh_attack or periodic_check) and
                not (api.own_reload_active and api.own_reload_active()) then
                reload_request('tactical_immediate', count)
            end
            return
        end
        if not attack_only and rule and rule.limit == 0 and count == 0 then
            -- Zero-limit rules request immediately. A later attack press can
            -- retry when the game did not load; periodic checks can also retry.
            local fresh_attack = state.last_lmb_press_at and state.last_request and
                state.last_lmb_press_at > state.last_request
            if (not state.critical_zero_requested or fresh_attack or periodic_check) and
                not (api.own_reload_active and api.own_reload_active()) then
                reload_request('tactical_zero', 0)
            end
            return
        end
        if not attack_only and count == 1 then
            -- Give the final round priority over attack and idle timers. An
            -- accepted R is enough until the next periodic check; a failed
            -- press can retry after our previous key has been released.
            if (not state.critical_one_requested or periodic_check) and
                not (api.own_reload_active and api.own_reload_active()) then
                reload_request('tactical_last_round', 1)
            end
            return
        end
        if not attack_only and count and count > 1 and count <= rule.limit then
            -- Magazine weapons request per click or periodic check; per-round
            -- weapons continue in continuous_reload_step without a click delay.
            local generation = state.last_lmb_press_at or 0
            if not rule.continuous and
                (state.tactical_sent_generation ~= generation or periodic_check) then
                reload_request('tactical_idle')
            end
            return
        end
        if state.lmb_edge_time and state.elapsed - state.lmb_edge_time <= 0.25 and
            state.lmb_edge_identity == identity and state.lmb_edge_tick and state.empty_tick and
            state.lmb_edge_tick > state.empty_tick then
            reload_request('empty_attack')
        elseif not attack_only and (not state.attempted or periodic_check) then
            reload_request(state.attempted and 'empty_periodic' or 'empty_immediate', nil, false,
                state.attempted and state.last_request_identity or nil)
        end
    else
        state.pending_reload = nil
        reset_speargun_retries()
        if state.request_at and row.ammo_path == 'weapon_heat' and row.heat_verified and not row.heat_overheated then
            emit('HEAT_LOCK_CLEARED_AFTER_REQUEST reload_animation_not_verified=true')
            state.request_at = nil
        end
        if state.request_at and ((row.magazine_count or row.rounds_magazine_count or 0) > 0 or
            (row.magazine_chamber_token or row.rounds_chamber_token or 0) > 0) then
            emit('AMMO_RECOVERED_AFTER_REQUEST reload_animation_not_verified=true')
            state.request_at = nil
        end
        if state.empty_since or state.attempted then
            emit('EMPTY_END tick=' .. state.ticks .. ' elapsed=' .. string.format('%.3f', state.elapsed) ..
                ' resource=' .. tostring(row.current_weapon_resource) ..
                ' mag=' .. tostring(row.magazine_count or row.rounds_magazine_count) ..
                ' chamber=' .. tostring(row.magazine_chamber_token or row.rounds_chamber_token))
        end
        state.empty_since, state.attempted = nil, false
        state.empty_tick = nil
        state.tactical_sent_generation = nil
        if state.lmb_edge_time and state.elapsed - state.lmb_edge_time > 0.75 then
            state.lmb_edge_time = nil
        end
    end
end

local function continuous_reload_step()
    local row = state.latest_row
    if state.weapon_switch_pending or state.switch_cancelled_identity then return end
    local rule = tactical_rule(row)
    local count = tactical_ammo_count(row, rule)
    if not row or row.context_status ~= 'context_observed' or
        row.ammo_path ~= 'weapon_rounds' or
        not rule or rule.continuous ~= true or
        not rounds_empty(row) or row.weapon_owned ~= true or
        not state.latest_at or state.elapsed - state.latest_at > 0.25 or
        unsafe_resources[row.current_weapon_resource] or not api.game_focused() then
        state.continuous_identity = nil
        state.continuous_probe_at = nil
        return
    end
    if api.own_reload_active and api.own_reload_active() then return end
    if count == 1 then return end
    if per_round_fire_held(row) then return end
    local identity = reload_identity(row)
    if identity ~= state.continuous_identity then
        state.continuous_identity = identity
        state.continuous_probe_at = nil
    end
    if (state.last_request and state.elapsed - state.last_request < CONTINUOUS_RELOAD_INTERVAL_SECONDS) or
        (state.continuous_probe_at and state.elapsed - state.continuous_probe_at < CONTINUOUS_RELOAD_INTERVAL_SECONDS) then
        return
    end
    state.continuous_probe_at = state.elapsed
    reload_request('continuous_load')
end

local function process_reload_delay()
    local pending, row = state.pending_reload, state.latest_row
    if not pending then return end
    if not row or row.context_status ~= 'context_observed' or row.weapon_owned ~= true or
        not state.latest_at or state.elapsed - state.latest_at > 0.25 or
        reload_identity(row) ~= pending.identity or not rounds_empty(row) or
        unsafe_resources[row.current_weapon_resource] or not api.game_focused() or per_round_fire_held(row) then
        state.pending_reload = nil
        return
    end
    if pending.expected_count and
        (tactical_ammo_count(row, tactical_rule(row)) or math.huge) > pending.expected_count then
        state.pending_reload = nil
        return
    end
    if state.elapsed < pending.due_at then return end
    -- Re-read the live context and fire state in reload_request, after waiting.
    if reload_request(pending.reason, pending.expected_count, true, pending.identity) then
        state.last_reload_wait_ms = (state.elapsed - pending.started_at) * 1000
        emit(string.format('RELOAD_DELAY_SENT delay_ms=%d waited_ms=%.3f reason=%s',
            pending.delay_ms, state.last_reload_wait_ms, pending.reason))
        state.pending_reload = nil
        if pending.reason == 'tactical_immediate' then state.immediate_count = pending.expected_count
        elseif pending.reason == 'tactical_zero' then state.critical_zero_requested = true
        elseif pending.reason == 'tactical_last_round' then state.critical_one_requested = true
        elseif pending.reason == 'tactical_idle' then state.tactical_sent_generation = pending.generation
        elseif pending.reason == 'empty_attack' then state.lmb_edge_time = nil end
    end
end

local function maintain_reload_input()
    local pending = api.reload_input_pending and api.reload_input_pending() or
        (api.own_reload_active and api.own_reload_active())
    if not pending then
        state.reload_key_identity = nil
        return
    end
    local row = state.latest_row
    local valid = row and row.context_status == 'context_observed' and row.weapon_owned == true and
        state.latest_at and state.elapsed - state.latest_at <= 0.25 and api.game_focused() and
        not state.weapon_switch_pending and
        state.reload_key_identity == reload_identity(row) and state.identity == state.reload_key_identity
    if not valid then api.release_reload(true) end
    if api.update_reload_input then api.update_reload_input() end
    if api.reload_input_pending and not api.reload_input_pending() then state.reload_key_identity = nil end
end

local function maintain_fire_interrupt()
    if not api.update_fire_interrupt then return end
    local row = state.latest_row
    local valid = row and row.context_status == 'context_observed' and row.weapon_owned == true and
        reload_reserves_available(row) and not per_round_weapon(row) and row.current_weapon_resource ~= AC8_RESOURCE and
        state.latest_at and state.elapsed - state.latest_at <= 0.25 and
        state.fire_interrupt_identity == reload_identity(row)
    api.update_fire_interrupt(not valid)
    if not valid or not api.fire_interrupt_active() then state.fire_interrupt_identity = nil end
end

local function eruptor_bolt_step(periodic_check)
    local row = state.latest_row
    local valid = reload_settings.eruptor_auto_bolt == true and row and
        row.context_status == 'context_observed' and row.weapon_owned == true and
        (row.weapon_context == 'on_foot' or row.weapon_context == 'vehicle_passenger') and
        row.current_weapon_resource == ERUPTOR_RESOURCE and
        row.eruptor_bolt_verified == true and row.eruptor_bolt_ability == ERUPTOR_BOLT_ABILITY and
        row.eruptor_gameplay_input == true and state.latest_at and
        state.elapsed - state.latest_at <= 0.25 and api.game_focused()
    if not valid then
        api.release_bolt(true)
        state.bolt_identity, state.bolt_requested_at, state.bolt_attempts = nil, nil, nil
        return
    end
    local identity = tostring(row.selected_entity_id) .. ':' .. tostring(row.selected_slot) ..
        ':' .. tostring(row._weapon_bytes) .. ':' .. tostring(row.local_entity_id)
    if identity ~= state.bolt_identity then
        api.release_bolt(true)
        state.bolt_identity, state.bolt_requested_at, state.bolt_attempts = identity, nil, 0
    end
    if row.eruptor_needs_bolt ~= true then
        api.release_bolt(true)
        if state.bolt_requested_at then
            emit('BOLT_CONFIRMED flags_cleared=true action_active=' .. tostring(row.eruptor_action_active))
        end
        state.bolt_requested_at, state.bolt_attempts = nil, 0
        return
    end
    if row.eruptor_action_active or row.eruptor_player_action_active ~= false then api.release_bolt(true); return end
    if api.own_reload_active() or api.own_bolt_active() or
        (api.fire_held and api.fire_held() or bit.band(api.key_state(0x01), 0x8000) ~= 0) or
        bit.band(api.key_state(0x52), 0x8000) ~= 0 then return end
    if ((state.bolt_attempts or 0) >= ERUPTOR_BOLT_MAX_ATTEMPTS and not periodic_check) or
        (state.bolt_requested_at and state.elapsed - state.bolt_requested_at < ERUPTOR_BOLT_RETRY_SECONDS) then return end
    -- Discard the complete fresh snapshot if any guarded pointer/state changes.
    local read_started = PERF and perf_begin()
    local ok_read, fresh = pcall(context_reader, api, game)
    if read_started then
        perf_end('context', read_started)
        if not ok_read or not fresh then perf_count('context_failures') end
    end
    if not ok_read or not fresh or fresh.context_status ~= 'context_observed' or
        fresh.current_weapon_resource ~= ERUPTOR_RESOURCE or fresh.weapon_owned ~= true or
        fresh.weapon_context ~= row.weapon_context or fresh._selection_bytes ~= row._selection_bytes or
        fresh.selected_entity_id ~= row.selected_entity_id or
        fresh.selected_slot ~= row.selected_slot or fresh._weapon_bytes ~= row._weapon_bytes or
        fresh.local_entity_id ~= row.local_entity_id or fresh.eruptor_bolt_verified ~= true or
        fresh.eruptor_bolt_ability ~= ERUPTOR_BOLT_ABILITY or fresh.eruptor_gameplay_input ~= true or
        fresh.eruptor_needs_bolt ~= true or fresh.eruptor_action_active ~= false or
        fresh.eruptor_player_action_active ~= false then return end
    local sent, detail = api.send_bolt()
    if sent then
        state.bolt_requested_at = state.elapsed
        state.bolt_attempts = (state.bolt_attempts or 0) + 1
    end
    emit('BOLT_REQUEST sent=' .. tostring(sent) .. ' detail=' .. tostring(detail) ..
        ' attempts=' .. tostring(state.bolt_attempts) .. ' entity=' .. tostring(fresh.selected_entity_id))
end

emit('START revision=' .. state.revision .. ' debug=' .. tostring(DEBUG) ..
    ' tactical_reload=' .. tostring(ENABLE_TACTICAL_RELOAD) ..
    ' reload_delay_ms=80..150 delay_mean_ms=133.582161 delay_variance_ms2=306.245821 fire_interrupt_seconds=0.5 heat_overheat_reload=true rounds_and_magazine=true ammo_read_only=true native_fire_consume=true input_injection=true')
sync_mod_options()
snapshot('initial')

local original_update = rawget(_G, 'update')
local function update(dt, ...)
    local update_started = PERF and perf_begin()
    state.ticks = state.ticks + 1
    sync_mod_options()
    if update_started then perf_end('options', update_started) end
    if setup_ok then
        state.started_at = state.started_at or api.now()
        state.elapsed = api.now() - state.started_at
        api.release_bolt(not api.game_focused() or not reload_settings.eruptor_auto_bolt)
        local input_started = PERF and perf_begin()
        input_probe()
        if input_started then perf_end('input', input_started) end
        if DEBUG and state.empty_since and state.lmb_edge_time and
            state.elapsed - state.lmb_edge_time <= 0.25 then
            debug_emit(string.format('DEBUG_EMPTY_ATTACK_FRAME tick=%d elapsed=%.3f',
                state.ticks, state.elapsed))
        end
        if api.game_focused() or not state.last_snapshot or state.elapsed - state.last_snapshot >= 0.05 then
            state.last_snapshot = state.elapsed
            snapshot('periodic')
        end
        local control_started = PERF and perf_begin()
        state.weapon_switch_pending = api.weapon_switch_pending()
        maintain_reload_input()
        -- Check the current weapon and switch inputs before keyup can emit Tap.
        api.release_reload(not api.game_focused())
        maintain_fire_interrupt()
        local trace_step = DEBUG and state.empty_since and state.lmb_edge_time and
            state.elapsed - state.lmb_edge_time <= 0.25
        if trace_step then
            debug_emit(string.format('DEBUG_AUTO_STEP_BEGIN tick=%d elapsed=%.3f',
                state.ticks, state.elapsed))
        end
        local periodic_check = false
        local interval = PERIODIC_CHECK_INTERVALS[reload_settings.periodic_check]
        if interval and api.game_focused() then
            state.periodic_check_at = state.periodic_check_at or state.elapsed
            if state.elapsed - state.periodic_check_at >= interval then
                state.periodic_check_at = state.elapsed
                periodic_check = true
            end
        else
            state.periodic_check_at = nil
        end
        -- Reuse this frame's snapshot and the existing checks before each input.
        auto_reload_step(periodic_check and
            (not state.last_request or state.elapsed - state.last_request >= interval))
        continuous_reload_step()
        process_reload_delay()
        eruptor_bolt_step(periodic_check)
        if trace_step then
            debug_emit(string.format('DEBUG_AUTO_STEP_END tick=%d elapsed=%.3f',
                state.ticks, state.elapsed))
        end
        if control_started then perf_end('control', control_started) end
    end
    flush_log(false)
    if update_started then perf_end('update', update_started) end
    if PERF then perf_report(false) end
    if original_update then return original_update(dt, ...) end
end
_G.update = update
local original_shutdown = rawget(_G, 'shutdown')
_G.shutdown = function(...)
    state.pending_reload = nil
    if api then api.update_fire_interrupt(true); api.release_bolt(true); api.release_reload(true) end
    perf_report(true)
    flush_log(true)
    if original_shutdown then return original_shutdown(...) end
end
return state
