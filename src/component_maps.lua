-- Embedded by scripts/build.py. Shared maps for builds 25327279/25480438.
local static_magazine_map = '__MAGAZINE_MAP__'
local static_rounds_map = '__ROUNDS_MAP__'
local static_heat_map = '__HEAT_MAP__'
local static_backpack_map = '__BACKPACK_MAP__'
local static_item_map = '__ITEM_MAP__'
local function static_unhex(value)
    return (value:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end))
end
local specs = {
    magazine = {map=static_unhex(static_magazine_map), slot=0xf124a0, stride=160},
    rounds = {map=static_unhex(static_rounds_map), slot=0xf12820, stride=0x88},
    heat = {map=static_unhex(static_heat_map), slot=0xf12cc8, stride=0x250},
    backpack = {map=static_unhex(static_backpack_map), slot=0xf12a00, stride=152},
    item = {map=static_unhex(static_item_map), slot=0xf12bc0, stride=232},
}
for _, spec in pairs(specs) do
    spec.resources = {}
    for offset = 0, #spec.map - 16, 16 do
        local key = resource(spec.map:sub(offset + 1, offset + 8))
        -- Keep the original first-match rule for duplicate/empty keys.
        if not spec.resources[key] then
            spec.resources[key] = {index=u32(spec.map, offset + 8), offset=offset}
        end
    end
end
component_static_record = function(e, row, name)
    local started = PERF and perf_begin()
    local spec = assert(specs[name], 'unknown_component_map')
    local entry = spec.resources[row.current_weapon_resource]
    if not entry or entry.index >= #spec.map / 16 then
        if started then perf_end('static', started) end
        return nil
    end
    local address = e.pointer(e.owner + spec.slot, true)
    local cached = e.cache and e.cache.maps[name]
    if not cached or cached.owner ~= e.owner or cached.address ~= address or
        e.now < cached.at or e.now - cached.at >= 1 then
        -- Full map checks are bounded to one second; the selected entry and
        -- effective record remain guarded on EVERY snapshot, including sends.
        if PERF then perf_count('map_checks') end
        local valid = true
        for offset = 0, #spec.map - 1, 2048 do
            local wanted = spec.map:sub(offset + 1, offset + 2048)
            if e.read(address + offset, #wanted) ~= wanted then valid = false; break end
        end
        cached = {owner=e.owner, address=address, at=e.now, valid=valid}
        if e.cache then e.cache.maps[name] = cached end
    elseif PERF then
        perf_count('map_hits')
    end
    if not cached.valid then
        if started then perf_end('static', started) end
        return nil
    end
    assert(e.read(address + entry.offset, 16, true) ==
        spec.map:sub(entry.offset + 1, entry.offset + 16), 'static_resource_identity_changed')
    local record = e.read(address + #spec.map + entry.index * spec.stride, spec.stride, true)
    if started then perf_end('static', started) end
    return record
end
magazine_static_records = function(e, row)
    local record = component_static_record(e, row, 'magazine')
    if record then return {magazine=record} end
end
static_component_snapshot = function(row)
    emit('STATIC_COMPONENT resource=' .. tostring(row.current_weapon_resource) ..
        ' path=' .. tostring(row.ammo_path) .. ' map_build=25327279')
end
