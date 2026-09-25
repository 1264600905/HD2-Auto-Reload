-- HD2-Addon: mods/liu/auto_reload_rounds

-- Auto Reload for builds 25327279/25480438: read-only ammo state, native R input.
-- The entity/component layout is adapted from etxp/HD2-C4-Quick-Actions
-- (MIT); C4-specific action calls and all memory writes are deliberately removed.
local existing = rawget(_G, 'LiuAutoReloadRounds')
if existing then return existing end

local DEBUG = false -- DEBUG_BUILD_FLAG
local CONTINUOUS_RELOAD_INTERVAL_SECONDS = 0.1
local TACTICAL_RAPID_CLICK_WINDOW_SECONDS = 0.5
local TACTICAL_CLICK_DELAYS = {0.1, 0.2, 0.4, 0.6}
-- RELOAD_CONFIG_INSERT
local state = {revision = DEBUG and 'auto-reload-0.6.3-debug' or 'auto-reload-0.6.3',
    ticks = 0, elapsed = 0, snapshots = 0,
    latest_row = nil,
    lmb_edge_time = nil, empty_since = nil, attempted = false, identity = nil,
    critical_one_requested = false, critical_zero_requested = false}
-- MG-43's earlier crash report remains unresolved. Its guarded Magazine
-- reader path is enabled experimentally at the user's request.
local unsafe_resources = {}
rawset(_G, 'LiuAutoReloadRounds', state)

local logger = rawget(_G, 'CowboyBingusModLoader')
local file
if logger and logger.open_log then
    local ok, result = pcall(logger.open_log, 'AutoReloadRounds.log')
    if ok then file = result end
end

local function emit(line)
    print('[AutoReload] ' .. line)
    if file then
        pcall(function() file:write(line .. '\n'); file:flush() end)
    end
end

local function debug_emit(line)
    if not DEBUG then return end
    if file then
        pcall(function() file:write(line .. '\n'); file:flush() end)
    else
        print('[AutoReload] ' .. line)
    end
end

local bit = require('bit')
local INVALID = 0xffffffff

local function u32(bytes, offset)
    assert(bytes and offset >= 0 and offset + 4 <= #bytes, 'short_u32')
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function hex(bytes)
    return (bytes:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

local function resource(bytes)
    local out = {}
    for i = 8, 1, -1 do out[#out + 1] = string.format('%02x', bytes:byte(i)) end
    return table.concat(out)
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
    local send_input = ffi.cast(
        'uint32_t (__stdcall *)(uint32_t, const void *, int)', user32.SendInput)
    local get_async_key_state = user32.GetAsyncKeyState
    local process = kernel.GetCurrentProcess()
    local process_id = kernel.GetCurrentProcessId()
    local api = {}
    function api.now() return tonumber(kernel.GetTickCount64()) / 1000 end
    function api.module(name)
        local handle = kernel.GetModuleHandleA(name)
        if handle == nil then return nil end
        return tonumber(ffi.cast('uintptr_t', handle))
    end
    function api.pointer(bytes)
        if not bytes or #bytes < 8 then return nil end
        local value = ffi.new('uintptr_t[1]')
        ffi.copy(value, bytes, 8)
        local number = tonumber(value[0])
        if number and number >= 65536 and number < 0x800000000000 then return number end
    end
    function api.read(address, size)
        assert(type(address) == 'number' and address >= 65536 and
            address + size < 0x800000000000, 'bad_read_address')
        assert(size > 0 and size <= 4096, 'bad_read_size')
        local output, count = ffi.new('uint8_t[?]', size), ffi.new('size_t[1]')
        if kernel.ReadProcessMemory(process, ffi.cast('const void *', address),
            output, size, count) == 0 or tonumber(count[0]) ~= size then return nil end
        return ffi.string(output, size)
    end
    function api.game_focused()
        local window = user32.GetForegroundWindow()
        if window == nil then return false end
        local owner = ffi.new('uint32_t[1]')
        user32.GetWindowThreadProcessId(window, owner)
        return tonumber(owner[0]) == tonumber(process_id)
    end
    function api.key_state(code) return tonumber(get_async_key_state(code)) end
    local release_at, released_tick
    function api.own_reload_active() return release_at ~= nil end
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
        if release_at and (force or api.now() >= release_at) then
            -- Always release our key, even if focus has left the game.
            if key_event(true) then
                release_at, released_tick = nil, state.ticks
                return true
            end
            return false
        end
        return true
    end
    function api.send_reload()
        if not api.game_focused() then return false, 'game_not_focused' end
        if release_at then return false, 'key_release_pending' end
        if released_tick == state.ticks then return false, 'keyup_frame_pending' end
        -- A previous script can leave an injected R down across a reload.
        -- Always establish a released frame before a fresh automatic press.
        if bit.band(api.key_state(0x52), 0x8000) ~= 0 then
            if not key_event(true) then return false, 'stale_keyup_rejected' end
            released_tick = state.ticks
            -- Let the game observe keyup before retrying keydown next frame.
            return false, 'stale_key_released_retry_next_frame'
        end
        if not key_event(false) then return false, 'keydown_rejected' end
        release_at = api.now() + 0.08
        return true, 'keydown_accepted_release_after_80ms_not_reload_confirmation'
    end
    return api
end

local magazine_static_records, component_static_record

local function read_magazine_component(e, row)
    -- Build 25327279 ammo query 0x744d02..0x744db7. No game calls.
    assert(e.read(e.game + 0x744d02, 7) == '\x48\x8b\x2d\x3f\x19\xbe\x02',
        'magazine_native_signature_mismatch')
    assert(hex(e.read(e.game + 0x744d6c, 76)) ==
        '488b4d38488bdf48c1e30448035d48488b0cf9e8bce9daff80b89c000000007420488b4550488d0c7f807c880800750a837b08000f85b600000032c0e9b1000000833b000f9fc0e9a6000000',
        'magazine_native_layout_mismatch')
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
    -- Require BOTH counters empty. This is conservative even if an entity
    -- configuration override changes the static template's chambered flag.
    -- A blocked chamber containing a round is not sufficient to request R.
    row.ammo_status = count == 0 and token == 0 and 'magazine_and_chamber_empty' or 'ammo_present'
    row.ammo_counter_semantics = 'native_magazine_count_and_chamber_token'
end

local function read_heat_component(e, row)
    -- Build 25327279: 0x764ee0 separates action inhibition from Heat +8.
    assert(hex(e.read(e.game + 0x764efa, 7)) == '4c8b15471ebc02',
        'heat_native_manager_mismatch')
    assert(hex(e.read(e.game + 0x764f79, 18)) == '8bc8498b4258488d1449807c9008000f94c0',
        'heat_native_layout_mismatch')
    local config = assert(component_static_record, 'heat_maps_not_built')(e, row, 'heat')
    if not config then row.ammo_status = 'heat_static_identity_unverified'; return end
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
    row.heat_value_bits = hex(runtime:sub(5, 8))
    row.heat_config_source = override and 'entity_override' or 'resource_template'
    row.ammo_status = row.heat_overheated and
        (row.heat_requires_replacement and 'heat_sink_burned_out' or 'heat_cooling_lock') or 'heat_ready'
end

local function context_reader(api, game, extend)
    local guards, reads, bytes = {}, 0, 0
    local function read(address, size, guard)
        reads, bytes = reads + 1, bytes + size
        assert(reads <= 768 and bytes <= 32768, 'snapshot_budget')
        local result = assert(api.read(address, size), 'read_unavailable')
        assert(#result == size, 'short_read')
        if guard then guards[#guards + 1] = {address, result} end
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
        for _, guard in ipairs(guards) do
            if read(guard[1], #guard[2]) ~= guard[2] then return false end
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
    local entity_index = lookup(owner + 0xf22ec8, avatar_unit, 1048576)
    if not entity_index then return finish(row, 'avatar_map_missing') end
    assert(entity_index < 1048576, 'avatar_entity_index_invalid')
    local entity = read(owner + 0xf32f18 + entity_index * 24, 24, true)
    if u32(entity, 16) ~= avatar_unit then return finish(row, 'avatar_unit_mismatch') end
    if bit.band(entity:byte(21), 1) == 0 then return finish(row, 'avatar_not_owned') end
    local entity_id = u32(entity, 8)
    row.local_entity_id = entity_id

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
    local weapon_id = u32(inventory_state, slot_offsets[slot])
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
        local e = {read=read, pointer=pointer, lookup=lookup, owner=owner, weapon_id=weapon_id}
        local config = component_static_record(e, row, 'rounds')
        if config then
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
            row.rounds_config_hex = hex(config)
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
        read_heat_component({read=read, pointer=pointer, global=global, lookup=lookup,
            game=game, owner=owner, weapon_id=weapon_id, weapon=weapon}, row)
    elseif row.ammo_path == 'weapon_magazine' then
        read_magazine_component({read=read, pointer=pointer, global=global, lookup=lookup,
            game=game, owner=owner, weapon_id=weapon_id, weapon=weapon}, row)
    else
        row.ammo_status = 'unknown_ammo_path'
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
    }) do
        assert(hex(assert(api.read(game + signature[1], #signature[2] / 2), 'layout_code_unavailable')) ==
            signature[2], string.format('unsupported_layout_at_%x', signature[1]))
    end
end

local api, game
local setup_ok, setup_error = pcall(function()
    api = read_api()
    game = assert(api.module('game.dll'), 'game_module_missing')
    local dos = assert(api.read(game, 64), 'module_header_unavailable')
    assert(dos:sub(1, 2) == 'MZ', 'module_header_invalid')
    local pe_offset = u32(dos, 0x3c)
    assert(pe_offset < 0x1000, 'module_pe_offset_invalid')
    local pe = assert(api.read(game + pe_offset, 0x60), 'module_pe_unavailable')
    verify_build(pe)
    verify_layout(api, game)
    emit(string.format('SETUP game_base=0x%X read_only=true build=25327279', game))
    -- One known ammo query, identified by the reference project's native
    -- analysis. Capture for offline disassembly only; never execute these bytes.
    local query = api.read(game + 0x744c20, 0x660)
    if query then
        emit('AMMO_QUERY_CODE rva=0x744c20 bytes=' .. hex(query))
    else
        emit('AMMO_QUERY_CODE_UNAVAILABLE')
    end
end)
if not setup_ok then emit('SETUP_ERROR error=' .. tostring(setup_error)) end

local function scalar(value)
    if value == nil then return 'nil' end
    return tostring(value):gsub('[%s=]', '_')
end

local function log_row(row, error_message, phase)
    if error_message then
        emit(string.format('CTX_ERROR tick=%d elapsed=%.3f phase=%s error=%s',
            state.ticks, state.elapsed, phase or 'snapshot', scalar(error_message)))
        return
    end
    local fields = {
        'CTX', 'tick=' .. state.ticks, string.format('elapsed=%.3f', state.elapsed),
        'phase=' .. scalar(phase), 'status=' .. scalar(row.context_status),
        'slot=' .. scalar(row.selected_slot), 'entity=' .. scalar(row.selected_entity_id),
        'resource=' .. scalar(row.current_weapon_resource), 'weapon=' .. scalar(row.current_weapon),
        'owned=' .. scalar(row.weapon_owned), 'driver_flags=' .. scalar(row.weapon_driver_flags),
        'ammo_path=' .. scalar(row.ammo_path), 'ammo_status=' .. scalar(row.ammo_status),
        'policy=' .. scalar(row.ammo_action_policy), 'mag=' .. scalar(row.rounds_magazine_count),
        'magazine_count=' .. scalar(row.magazine_count),
        'magazine_chamber=' .. scalar(row.magazine_chamber_token),
        'magazine_blocked=' .. scalar(row.magazine_chamber_blocked),
        'magazine_verified=' .. scalar(row.magazine_verified),
        'heat_verified=' .. scalar(row.heat_verified),
        'heat_overheated=' .. scalar(row.heat_overheated),
        'heat_requires_replacement=' .. scalar(row.heat_requires_replacement),
        'heat_spares=' .. scalar(row.heat_spares),
        'heat_value_bits=' .. scalar(row.heat_value_bits),
        'heat_config_source=' .. scalar(row.heat_config_source),
        'selected_mag=' .. scalar(row.rounds_selected_magazine),
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
    local ok, row, reason = pcall(context_reader, api, game)
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
    for name, code in pairs(keys) do
        local value = api.key_state(code) or 0
        local down = bit.band(value, 0x8000) ~= 0
        if state.keys == nil then state.keys = {} end
        if state.keys[name] ~= down then
            state.keys[name] = down
            if name == 'LMB' and down then
                state.lmb_edge_time = state.elapsed
                state.last_lmb_press_at = state.elapsed
            end
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

local function tactical_rule(row)
    if not ENABLE_TACTICAL_RELOAD or not row then return nil end
    local rule = tactical_rules[row.current_weapon_resource]
    if rule and rule.path == row.ammo_path then return rule end
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
        row.current_weapon_resource == 'UNKNOWN' then return false end
    if attack_only_resources[row.current_weapon_resource] then return truly_empty(row) end
    local rule = tactical_rule(row)
    if rule then
        local count = tactical_ammo_count(row, rule)
        if count ~= nil then return count <= rule.limit end
    end
    return truly_empty(row)
end

local function reset_tactical_clicks()
    state.tactical_window_since = nil
    state.tactical_last_click_at = nil
    state.tactical_seen_click_at = nil
    state.tactical_click_tier = nil
    state.tactical_click_generation = nil
    state.tactical_sent_generation = nil
end

local function track_tactical_click()
    local click = state.last_lmb_press_at
    if not click or click == state.tactical_seen_click_at or
        not state.tactical_window_since or click < state.tactical_window_since or
        state.elapsed - click > 0.25 then return end
    local previous = state.tactical_last_click_at
    if previous and click >= previous and
        click - previous <= TACTICAL_RAPID_CLICK_WINDOW_SECONDS then
        state.tactical_click_tier = math.min((state.tactical_click_tier or 1) + 1,
            #TACTICAL_CLICK_DELAYS)
    else
        state.tactical_click_tier = 1
    end
    state.tactical_seen_click_at = click
    state.tactical_last_click_at = click
    state.tactical_click_generation = (state.tactical_click_generation or 0) + 1
end

local function tactical_click_wait_finished()
    local last_click = state.tactical_last_click_at
    local since = last_click or state.tactical_window_since
    local delay = TACTICAL_CLICK_DELAYS[state.tactical_click_tier or 1]
    return since and state.elapsed - since >= delay
end

local function fresh_context_matches(row, fresh)
    return rounds_empty(fresh) and fresh.weapon_owned == true and
        fresh.selected_entity_id == row.selected_entity_id and
        fresh.selected_slot == row.selected_slot and
        fresh.ammo_path == row.ammo_path and
        fresh._weapon_bytes == row._weapon_bytes and
        fresh.local_entity_id == row.local_entity_id and
        fresh.current_weapon_resource == row.current_weapon_resource
end

local function reload_request(reason, expected_tactical_count)
    debug_emit(string.format('DEBUG_RELOAD_ENTER tick=%d elapsed=%.3f reason=%s resource=%s',
        state.ticks, state.elapsed, reason,
        tostring(state.latest_row and state.latest_row.current_weapon_resource)))
    if state.attempted and reason ~= 'empty_attack' and reason ~= 'tactical_idle' and
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
    -- Refresh selection and ammo immediately before sending input.
    debug_emit(string.format('DEBUG_RELOAD_REFRESH_BEGIN tick=%d elapsed=%.3f',
        state.ticks, state.elapsed))
    local ok_read, fresh = pcall(context_reader, api, game)
    debug_emit(string.format('DEBUG_RELOAD_REFRESH_END tick=%d elapsed=%.3f ok=%s status=%s',
        state.ticks, state.elapsed, tostring(ok_read),
        scalar(type(fresh) == 'table' and fresh.context_status or fresh)))
    if not ok_read or not fresh_context_matches(state.latest_row, fresh) then
        debug_emit('DEBUG_RELOAD_SKIP reason=fresh_context_rejected')
        return
    end
    if expected_tactical_count and
        (tactical_ammo_count(fresh, tactical_rule(fresh)) or math.huge) > expected_tactical_count then
        debug_emit('DEBUG_RELOAD_SKIP reason=last_round_changed')
        return
    end
    debug_emit(string.format('DEBUG_RELOAD_SEND_BEGIN tick=%d elapsed=%.3f',
        state.ticks, state.elapsed))
    local ok, detail = api.send_reload()
    debug_emit(string.format('DEBUG_RELOAD_SEND_END tick=%d elapsed=%.3f ok=%s detail=%s',
        state.ticks, state.elapsed, tostring(ok), tostring(detail)))
    emit(string.format(
        'RELOAD_REQUEST tick=%d elapsed=%.3f reason=%s sent=%s detail=%s resource=%s mag=%s chamber=%s',
        state.ticks, state.elapsed, reason, tostring(ok), tostring(detail),
        tostring(state.latest_row.current_weapon_resource),
        tostring(state.latest_row.magazine_count or state.latest_row.rounds_magazine_count),
        tostring(state.latest_row.magazine_chamber_token or state.latest_row.rounds_chamber_token)))
    if ok then
        state.last_request = state.elapsed
        state.attempted = true; state.request_at = state.elapsed
    end
    return ok
end

local function auto_reload_step()
    local row = state.latest_row
    if not row or row.context_status ~= 'context_observed' or
        (row.ammo_path ~= 'weapon_rounds' and row.ammo_path ~= 'weapon_magazine' and row.ammo_path ~= 'weapon_heat') or row.weapon_owned ~= true or
        (row.ammo_path == 'weapon_heat' and (row.heat_verified ~= true or row.heat_requires_replacement ~= true)) or
        not state.latest_at or state.elapsed - state.latest_at > 0.25 or
        unsafe_resources[row.current_weapon_resource] or not api.game_focused() then
        state.identity, state.empty_since, state.attempted = nil, nil, false
        state.lmb_edge_time, state.request_at = nil, nil
        state.critical_one_requested = false
        state.critical_zero_requested = false
        reset_tactical_clicks()
        return
    end
    local identity = tostring(row.current_weapon_resource) .. ':' .. tostring(row.selected_entity_id) ..
        ':' .. tostring(row.selected_slot) .. ':' .. tostring(row._weapon_bytes) .. ':' .. tostring(row.local_entity_id)
    if identity ~= state.identity then
        state.identity, state.empty_since, state.attempted = identity, nil, false
        state.request_at, state.last_request = nil, nil
        state.immediate_count = nil
        state.critical_one_requested = false
        state.critical_zero_requested = false
        reset_tactical_clicks()
        emit('WEAPON_CONTEXT resource=' .. tostring(row.current_weapon_resource) ..
            ' entity=' .. tostring(row.selected_entity_id) .. ' policy=' .. row.ammo_path)
    end
    local rule = tactical_rule(row)
    local count = tactical_ammo_count(row, rule)
    if rule and not rule.immediate and count and count <= rule.limit and
        not attack_only_resources[row.current_weapon_resource] then
        state.tactical_window_since = state.tactical_window_since or state.elapsed
        track_tactical_click()
    else
        -- Refills and leaving the threshold discard the previous click tier.
        -- A click before entry must not shorten or lengthen the new wait.
        reset_tactical_clicks()
    end
    if not rounds_empty(row) then state.immediate_count = nil end
    if count ~= 1 then state.critical_one_requested = false end
    if not rule or rule.limit ~= 0 or count ~= 0 then
        state.critical_zero_requested = false
    end
    if rounds_empty(row) then
        if not state.empty_since then
            state.empty_since = state.elapsed
            emit('EMPTY_BEGIN tick=' .. state.ticks .. ' elapsed=' .. string.format('%.3f', state.elapsed) ..
                ' resource=' .. tostring(row.current_weapon_resource) ..
                ' mag=' .. tostring(row.magazine_count or row.rounds_magazine_count) ..
                ' chamber=' .. tostring(row.magazine_chamber_token or row.rounds_chamber_token))
        end
        if state.request_at and state.elapsed - state.request_at >= 8 then
            emit('RELOAD_UNCONFIRMED reason=still_empty_after_8_seconds retry=press_attack')
            state.request_at = nil
        end
        local attack_only = attack_only_resources[row.current_weapon_resource] == true
        if not attack_only and rule and rule.immediate and count then
            local fresh_attack = state.last_lmb_press_at and state.last_request and
                state.last_lmb_press_at > state.last_request
            if (state.immediate_count == nil or count < state.immediate_count or fresh_attack) and
                not (api.own_reload_active and api.own_reload_active()) then
                if reload_request('tactical_immediate', count) then state.immediate_count = count end
            end
            return
        end
        if not attack_only and rule and rule.limit == 0 and count == 0 then
            -- Zero-limit rules request immediately. A later attack press can
            -- retry when the game did not load, without repeating each frame.
            local fresh_attack = state.last_lmb_press_at and state.last_request and
                state.last_lmb_press_at > state.last_request
            if (not state.critical_zero_requested or fresh_attack) and
                not (api.own_reload_active and api.own_reload_active()) then
                if reload_request('tactical_zero', 0) then
                    state.critical_zero_requested = true
                end
            end
            return
        end
        if not attack_only and count == 1 then
            -- Give the final round priority over attack and idle timers. An
            -- accepted R is enough for this one-round episode; a failed press
            -- can be retried after our previous key has been released.
            if not state.critical_one_requested and
                not (api.own_reload_active and api.own_reload_active()) then
                if reload_request('tactical_last_round', 1) then
                    state.critical_one_requested = true
                end
            end
            return
        end
        if not attack_only and count and count > 1 and count <= rule.limit then
            -- A new shot restarts the wait. Magazine weapons request once per
            -- click interval; per-round weapons continue in continuous_reload_step.
            if tactical_click_wait_finished() and
                not rule.continuous and
                state.tactical_sent_generation ~= (state.tactical_click_generation or 0) then
                if reload_request('tactical_idle') then
                    state.tactical_sent_generation = state.tactical_click_generation or 0
                end
            end
            return
        end
        if state.lmb_edge_time and state.elapsed - state.lmb_edge_time <= 0.25 and
            state.lmb_edge_time >= state.empty_since then
            if reload_request('empty_attack') then state.lmb_edge_time = nil end
        elseif not attack_only and not state.attempted then
            reload_request('empty_immediate')
        end
    else
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
        state.tactical_sent_generation = nil
        if state.lmb_edge_time and state.elapsed - state.lmb_edge_time > 0.75 then
            state.lmb_edge_time = nil
        end
    end
end

local function continuous_reload_step()
    local row = state.latest_row
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
    if count == 1 then return end
    if count and count > 1 and not rule.immediate and not tactical_click_wait_finished() then return end
    local identity = tostring(row.current_weapon_resource) .. ':' .. tostring(row.selected_entity_id) ..
        ':' .. tostring(row.selected_slot) .. ':' .. tostring(row._weapon_bytes) .. ':' .. tostring(row.local_entity_id)
    if identity ~= state.continuous_identity then
        state.continuous_identity = identity
        state.continuous_probe_at = nil
    end
    if (state.last_request and state.elapsed - state.last_request < CONTINUOUS_RELOAD_INTERVAL_SECONDS) or
        (state.continuous_probe_at and state.elapsed - state.continuous_probe_at < CONTINUOUS_RELOAD_INTERVAL_SECONDS) then
        return
    end
    state.continuous_probe_at = state.elapsed
    debug_emit(string.format('DEBUG_CONTINUOUS_REFRESH_BEGIN tick=%d elapsed=%.3f',
        state.ticks, state.elapsed))
    local ok_read, fresh = pcall(context_reader, api, game)
    if not ok_read or not fresh_context_matches(row, fresh) then
        debug_emit('DEBUG_CONTINUOUS_SKIP reason=fresh_context_rejected')
        return
    end
    debug_emit(string.format('DEBUG_CONTINUOUS_SEND_BEGIN tick=%d elapsed=%.3f',
        state.ticks, state.elapsed))
    local ok, detail = api.send_reload()
    debug_emit(string.format('DEBUG_CONTINUOUS_SEND_END tick=%d elapsed=%.3f ok=%s detail=%s',
        state.ticks, state.elapsed, tostring(ok), tostring(detail)))
    emit(string.format(
        'RELOAD_REQUEST tick=%d elapsed=%.3f reason=continuous_load sent=%s detail=%s resource=%s mag=%s chamber=%s',
        state.ticks, state.elapsed, tostring(ok), tostring(detail),
        tostring(row.current_weapon_resource), tostring(row.rounds_magazine_count),
        tostring(row.rounds_chamber_token)))
    if ok then
        state.last_request = state.elapsed
        state.attempted = true; state.request_at = state.elapsed
    end
end

emit('START revision=' .. state.revision .. ' debug=' .. tostring(DEBUG) ..
    ' tactical_reload=' .. tostring(ENABLE_TACTICAL_RELOAD) ..
    ' reload_delay=0 heat_overheat_reload=true rounds_and_magazine=true no_native_calls=true no_memory_writes=true input_injection=true')
snapshot('initial')

local original_update = rawget(_G, 'update')
local function update(dt, ...)
    state.ticks = state.ticks + 1
    if setup_ok then
        state.started_at = state.started_at or api.now()
        state.elapsed = api.now() - state.started_at
        input_probe()
        api.release_reload(not api.game_focused())
        if DEBUG and state.empty_since and state.lmb_edge_time and
            state.elapsed - state.lmb_edge_time <= 0.25 then
            debug_emit(string.format('DEBUG_EMPTY_ATTACK_FRAME tick=%d elapsed=%.3f',
                state.ticks, state.elapsed))
        end
        if api.game_focused() or not state.last_snapshot or state.elapsed - state.last_snapshot >= 0.05 then
            state.last_snapshot = state.elapsed
            snapshot('periodic')
        end
        local trace_step = DEBUG and state.empty_since and state.lmb_edge_time and
            state.elapsed - state.lmb_edge_time <= 0.25
        if trace_step then
            debug_emit(string.format('DEBUG_AUTO_STEP_BEGIN tick=%d elapsed=%.3f',
                state.ticks, state.elapsed))
        end
        auto_reload_step()
        continuous_reload_step()
        if trace_step then
            debug_emit(string.format('DEBUG_AUTO_STEP_END tick=%d elapsed=%.3f',
                state.ticks, state.elapsed))
        end
    end
    if original_update then return original_update(dt, ...) end
end
_G.update = update
return state
