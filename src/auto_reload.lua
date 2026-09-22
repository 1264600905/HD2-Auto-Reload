-- HD2-Addon: mods/liu/auto_reload_rounds

-- Auto Reload for build 24826606: read-only ammo state, native R input.
-- The entity/component layout is adapted from etxp/HD2-C4-Quick-Actions
-- (MIT); C4-specific action calls and all memory writes are deliberately removed.
local existing = rawget(_G, 'LiuAutoReloadRounds')
if existing then return existing end

local RELOAD_DELAY_SECONDS = 1
local state = {revision = 'auto-reload-4', ticks = 0, elapsed = 0, snapshots = 0,
    latest_row = nil,
    lmb_edge_time = nil, empty_since = nil, attempted = false, identity = nil}
-- Reported by the tester as crash-prone while being equipped. Keep it out of
-- all manager/state probing until its native layout is independently verified.
local unsafe_resources = {['11c27d3babb38956'] = 'user_reported_crash'}
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
    pcall(ffi.cdef, [[
        void *GetModuleHandleA(const char *name);
        void *GetCurrentProcess(void);
        int ReadProcessMemory(void *, const void *, void *, size_t, size_t *);
        uint32_t GetCurrentProcessId(void);
        void *GetForegroundWindow(void);
        uint32_t GetWindowThreadProcessId(void *, uint32_t *);
        uint32_t SendInput(uint32_t, const void *, int);
        uint64_t GetTickCount64(void);
    ]])
    local kernel = ffi.load('kernel32')
    local user32 = ffi.load('user32')
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
    local release_at
    local function key_event(up)
        local input = ffi.new('uint8_t[40]')
        ffi.cast('uint32_t *', input)[0] = 1
        -- KEYEVENTF_SCANCODE; R is scan code 0x13. Keep keydown across frames.
        ffi.cast('uint16_t *', input + 10)[0] = 0x13
        ffi.cast('uint32_t *', input + 12)[0] = up and 10 or 8
        return tonumber(user32.SendInput(1, input, 40)) == 1
    end
    function api.release_reload(force)
        if release_at and (force or api.now() >= release_at) then
            -- Always release our key, even if focus has left the game.
            if key_event(true) then release_at = nil; return true end
            return false
        end
        return true
    end
    function api.send_reload()
        if not api.game_focused() then return false, 'game_not_focused' end
        if release_at then return false, 'key_release_pending' end
        if not key_event(false) then return false, 'keydown_rejected' end
        release_at = api.now() + 0.08
        return true, 'keydown_accepted_release_after_80ms_not_reload_confirmation'
    end
    return api
end

local magazine_static_records

local function read_magazine_component(e, row)
    -- Evidence: v2 AMMO_QUERY_CODE, 0x73d062..0x73d113. No game calls.
    assert(e.read(e.game + 0x73d062, 7) == '\x48\x8b\x2d\x0f\xf3\x02\x02',
        'magazine_native_signature_mismatch')
    assert(hex(e.read(e.game + 0x73d0cc, 76)) ==
        '488b4d38488bdf48c1e30448035d48488b0cf9e8dc1bdbff80b89c000000007420488b4550488d0c7f807c880800750a837b08000f85b600000032c0e9b1000000833b000f9fc0e9a6000000',
        'magazine_native_layout_mismatch')
    local records = assert(magazine_static_records, 'magazine_maps_not_built')(e, row)
    if not records then row.ammo_status = 'magazine_static_identity_unverified'; return end
    local manager = e.global(0x276c378)
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
    local mode = read(global(0x276c3d0), 0x44, true)
    if u32(mode, 8) == 0 or u32(mode, 0x40) < 1 or u32(mode, 0x40) > 7 then
        return finish(row, 'waiting_for_mission')
    end
    local player_manager = global(0x276c190)
    local counts = read(player_manager + 0x84, 8, true)
    if u32(counts, 0) == 0 or u32(counts, 4) == 0 then
        return finish(row, 'waiting_for_local_player')
    end
    local player = read(pointer(player_manager + 0xe8, true), 24, true)
    if bit.band(player:byte(21), 1) == 0 then return finish(row, 'local_player_not_owned') end
    local avatar_unit = u32(read(player_manager + 0x3a8, 4, true), 0)
    if avatar_unit == 0x7fff then return finish(row, 'waiting_for_avatar') end

    local owner = global(0x276f0c0)
    local entity_index = lookup(owner + 0xf21a88, avatar_unit, 1048576)
    if not entity_index then return finish(row, 'avatar_map_missing') end
    local entity = read(owner + 0xf31ad8 + entity_index * 24, 24, true)
    if bit.band(entity:byte(21), 1) == 0 then return finish(row, 'avatar_not_owned') end
    local entity_id = u32(entity, 8)
    row.local_entity_id = entity_id

    local avatar = global(0x276ca30)
    local avatar_index = lookup(avatar + 0xf8, entity_id, 64)
    local avatar_count = u32(read(avatar + 0x6c, 4, true), 0)
    if not avatar_index or avatar_index >= avatar_count then return finish(row, 'avatar_registry_missing') end
    if read(pointer(avatar + 0x110 + avatar_index * 8, true), 24, true) ~= entity then
        return finish(row, 'avatar_registry_mismatch')
    end

    local inventory = global(0x276c468)
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

    local weapon_index = lookup(owner + 0xf19a70, weapon_id, 1048576)
    if not weapon_index then return finish(row, 'weapon_map_missing') end
    local weapon = read(owner + 0xf31ad8 + weapon_index * 24, 24, true)
    if u32(weapon, 8) ~= weapon_id then return finish(row, 'weapon_identity_mismatch') end
    row.current_weapon_resource = resource(weapon)
    row.current_weapon = row.current_weapon_resource
    row.weapon_owned = bit.band(weapon:byte(21), 1) ~= 0
    if unsafe_resources[row.current_weapon_resource] then return finish(row, 'unsafe_resource') end
    if not row.weapon_owned then return finish(row, 'weapon_not_owned') end

    local weapon_data = global(0x276c9f0)
    local data_index = lookup(weapon_data + 0x30, weapon_id, 65536)
    row.weapon_data_status = data_index and 'present' or 'missing'
    if data_index then
        local data_count = u32(read(weapon_data + 0x1c, 4, true), 0)
        if data_index >= data_count then return finish(row, 'weapon_data_index_invalid') end
        if read(pointer(pointer(weapon_data + 0x48, true) + data_index * 8, true), 24, true) ~= weapon then
            return finish(row, 'weapon_data_owner_mismatch')
        end
        local types = read(pointer(weapon_data + 0x58, true) + data_index * 0x3e0 + 0x340, 16, true)
        local packed = read(pointer(weapon_data + 0x60, true) + data_index * 12, 12, true)
        row.weapon_function_types = hex(types)
        row.weapon_state_12 = hex(packed)
        row.weapon_state_flags = hex(read(pointer(weapon_data + 0x50, true) + data_index * 2, 2, true))
    end

    local weapon_manager = global(0x276c390)
    local weapon_component = lookup(weapon_manager + 0x28, weapon_id, 65536)
    if not weapon_component then return finish(row, 'weapon_driver_missing') end
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
        local rounds_manager = global(0x276ca00)
        local rounds_index = lookup(rounds_manager + 0x28, weapon_id, 65536)
        if not rounds_index then return finish(row, 'rounds_component_missing') end
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
        local override = lookup(rounds_manager + 0x68, weapon_id, 65536)
        local config
        if override then
            config = read(pointer(rounds_manager + 0xa8, true) + override * 0x84, 0x84, true)
            row.rounds_config_source = 'entity_override'
        else
            local templates = pointer(owner + 0xf113a8, true)
            local start = 0
            for i = 8, 1, -1 do start = (start * 256 + weapon:byte(i)) % 46 end
            for probe = 0, 45 do
                local entry = read(templates + ((start + probe) % 46) * 16, 16, true)
                local key = resource(entry)
                if key == '0000000000000000' then break end
                if key == row.current_weapon_resource then
                    local index = u32(entry, 8)
                    if index < 46 then config = read(templates + 0x2e0 + index * 0x84, 0x84, true) end
                    break
                end
            end
            row.rounds_config_source = 'resource_template'
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
        local resource_manager = global(0x276c7c0)
        local resource_index = lookup(resource_manager + 0x20, weapon_id, 65536)
        if resource_index then
            local provider = u32(read(pointer(resource_manager + 0x48, true) + resource_index * 36, 4, true), 0)
            row.resource_provider = provider
            if provider ~= 0 and provider ~= INVALID and provider ~= 0x7fff then
                local counter_manager = global(0x276c318)
                local counter_index = lookup(counter_manager + 0x20, provider, 65536)
                if counter_index then
                    row.resource_count = u32(read(pointer(counter_manager + 0x50, true) + counter_index * 8, 8, true), 0)
                    row.ammo_status = row.resource_count > 0 and 'resource_available' or 'resource_empty'
                else
                    row.resource_count = 'boolean_provider_unresolved'
                    row.ammo_status = 'resource_provider_unresolved'
                end
            else
                row.resource_count = 0
                row.ammo_status = 'resource_empty'
            end
        else
            row.ammo_status = 'resource_component_missing'
        end
    elseif row.ammo_path == 'weapon_heat' then
        row.ammo_status = 'heat_runtime_unverified'
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
    row.ammo_action_policy = row.ammo_path == 'weapon_heat' and 'HEAT_DIAGNOSTIC_PENDING' or
        row.ammo_path == 'weapon_magazine' and (row.magazine_verified and 'NATIVE_R_ONLY_CANDIDATE' or 'SKIP_UNVERIFIED_MAGAZINE') or
        row.ammo_path == 'no_native_ammo_component' and 'SKIP_UNKNOWN' or 'NATIVE_R_ONLY_CANDIDATE'
    return finish(row, 'context_observed')
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
    assert(pe:sub(1, 4) == 'PE\0\0' and u32(pe, 8) == 0x6a86132e and
        u32(pe, 0x50) == 0x3a6b000, 'unsupported_game_build')
    emit(string.format('SETUP game_base=0x%X read_only=true build=24826606', game))
    -- One known ammo query, identified by the reference project's native
    -- analysis. Capture for offline disassembly only; never execute these bytes.
    local query = api.read(game + 0x73cf80, 0x660)
    if query then
        emit('AMMO_QUERY_CODE rva=0x73cf80 bytes=' .. hex(query))
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

-- Build-time injection point for the exact WeaponMagazineComponent and
-- WeaponReloadComponent map fingerprints from the reviewed reference Mod.
-- The generated probe only performs bounded read-only table/record checks.
local static_component_snapshot = function() end
-- STATIC_COMPONENT_READER_INSERT

local function snapshot(phase)
    state.snapshots = state.snapshots + 1
    if not setup_ok then return end
    local ok, row, reason = pcall(context_reader, api, game)
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
    local ok, ffi = pcall(require, 'ffi')
    if not ok then return end
    pcall(ffi.cdef, [[short GetAsyncKeyState(int key);]])
    local ok_user, user32 = pcall(ffi.load, 'user32')
    if not ok_user then return end
    local keys = {LMB = 0x01, RMB = 0x02, R = 0x52, F8 = 0x77}
    for name, code in pairs(keys) do
        local value = tonumber(user32.GetAsyncKeyState(code)) or 0
        local down = bit.band(value, 0x8000) ~= 0
        if state.keys == nil then state.keys = {} end
        if state.keys[name] ~= down then
            state.keys[name] = down
            if name == 'LMB' and down then state.lmb_edge_time = state.elapsed end
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

local function rounds_empty(row)
    if not row or row.context_status ~= 'context_observed' or
        row.current_weapon_resource == 'UNKNOWN' then return false end
    if row.ammo_path == 'weapon_magazine' then
        return row.magazine_verified == true and row.magazine_count == 0 and
            row.magazine_chamber_token == 0
    end
    if row.ammo_path ~= 'weapon_rounds' then return false end
    if type(row.rounds_chambered) ~= 'boolean' then return false end
    if row.rounds_chambered then
        return row.rounds_magazine_count == 0 and
            (row.rounds_chamber_token == 0 or row.rounds_chamber_blocked == true)
    end
    return row.rounds_magazine_count == 0
end

local function reload_request(reason)
    if state.attempted and reason ~= 'empty_attack' then return end
    if state.last_request and state.elapsed - state.last_request < 2 then return end
    if not state.latest_row or unsafe_resources[state.latest_row.current_weapon_resource] then return end
    if state.keys and state.keys.R then return end
    -- Refresh selection and ammo immediately before sending input.
    local ok_read, fresh = pcall(context_reader, api, game)
    if not ok_read or not rounds_empty(fresh) or fresh.weapon_owned ~= true or
        fresh.selected_entity_id ~= state.latest_row.selected_entity_id or
        fresh.current_weapon_resource ~= state.latest_row.current_weapon_resource then return end
    state.last_request = state.elapsed
    local ok, detail = api.send_reload()
    emit(string.format(
        'RELOAD_REQUEST tick=%d elapsed=%.3f reason=%s sent=%s detail=%s resource=%s mag=%s chamber=%s',
        state.ticks, state.elapsed, reason, tostring(ok), tostring(detail),
        tostring(state.latest_row.current_weapon_resource),
        tostring(state.latest_row.magazine_count or state.latest_row.rounds_magazine_count),
        tostring(state.latest_row.magazine_chamber_token or state.latest_row.rounds_chamber_token)))
    if ok then state.attempted = true; state.request_at = state.elapsed end
end

local function auto_reload_step()
    local row = state.latest_row
    if not row or row.context_status ~= 'context_observed' or
        (row.ammo_path ~= 'weapon_rounds' and row.ammo_path ~= 'weapon_magazine') or row.weapon_owned ~= true or
        not state.latest_at or state.elapsed - state.latest_at > 0.25 or
        unsafe_resources[row.current_weapon_resource] or not api.game_focused() then
        state.identity, state.empty_since, state.attempted = nil, nil, false
        state.lmb_edge_time, state.request_at = nil, nil
        return
    end
    local identity = tostring(row.current_weapon_resource) .. ':' .. tostring(row.selected_entity_id)
    if identity ~= state.identity then
        state.identity, state.empty_since, state.attempted = identity, nil, false
        state.request_at = nil
        emit('WEAPON_CONTEXT resource=' .. tostring(row.current_weapon_resource) ..
            ' entity=' .. tostring(row.selected_entity_id) .. ' policy=' .. row.ammo_path)
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
        if state.lmb_edge_time and state.elapsed - state.lmb_edge_time <= 0.25 and
            state.lmb_edge_time >= state.empty_since then
            state.lmb_edge_time = nil
            reload_request('empty_attack')
        elseif not state.attempted and state.keys and state.keys.LMB and
            state.elapsed - state.empty_since >= 0.15 then
            reload_request('empty_attack_held')
        elseif not state.attempted and state.elapsed - state.empty_since >= RELOAD_DELAY_SECONDS then
            reload_request('empty_1_second')
        end
    else
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
        if state.lmb_edge_time and state.elapsed - state.lmb_edge_time > 0.75 then
            state.lmb_edge_time = nil
        end
    end
end

emit('START revision=' .. state.revision .. ' reload_delay=1 heat_diagnostic=true rounds_and_magazine=true no_native_calls=true no_memory_writes=true input_injection=true')
snapshot('initial')

local original_update = rawget(_G, 'update')
local function update(dt, ...)
    state.ticks = state.ticks + 1
    if setup_ok then
        state.started_at = state.started_at or api.now()
        state.elapsed = api.now() - state.started_at
        api.release_reload(not api.game_focused())
        input_probe()
        if not state.last_snapshot or state.elapsed - state.last_snapshot >= 0.05 then
            state.last_snapshot = state.elapsed
            snapshot('periodic')
        end
        auto_reload_step()
    end
    if original_update then return original_update(dt, ...) end
end
_G.update = update
return state
