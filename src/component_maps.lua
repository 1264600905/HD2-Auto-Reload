-- Embedded by scripts/build.py. Shared maps for builds 25327279/25480438.
local static_magazine_map = '__MAGAZINE_MAP__'
local static_rounds_map = '__ROUNDS_MAP__'
local static_heat_map = '__HEAT_MAP__'
local function static_unhex(value)
    return (value:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end))
end
local specs = {
    magazine = {map=static_unhex(static_magazine_map), slot=0xf124a0, stride=160},
    rounds = {map=static_unhex(static_rounds_map), slot=0xf12820, stride=0x88},
    heat = {map=static_unhex(static_heat_map), slot=0xf12cc8, stride=0x250},
}
component_static_record = function(e, row, name)
    local spec = assert(specs[name], 'unknown_component_map')
    local index, entry_offset
    for offset = 0, #spec.map - 16, 16 do
        if resource(spec.map:sub(offset + 1, offset + 8)) == row.current_weapon_resource then
            index, entry_offset = u32(spec.map, offset + 8), offset
            break
        end
    end
    if not index or index >= #spec.map / 16 then return nil end
    local address = e.pointer(e.owner + spec.slot, true)
    -- Compare the whole resource/index map, including bytes beyond the prefix.
    for offset = 0, #spec.map - 1, 2048 do
        local wanted = spec.map:sub(offset + 1, offset + 2048)
        if e.read(address + offset, #wanted) ~= wanted then return nil end
    end
    assert(e.read(address + entry_offset, 16, true) ==
        spec.map:sub(entry_offset + 1, entry_offset + 16), 'static_resource_identity_changed')
    return e.read(address + #spec.map + index * spec.stride, spec.stride, true)
end
magazine_static_records = function(e, row)
    local record = component_static_record(e, row, 'magazine')
    if record then return {magazine=record} end
end
static_component_snapshot = function(row)
    emit('STATIC_COMPONENT resource=' .. tostring(row.current_weapon_resource) ..
        ' path=' .. tostring(row.ammo_path) .. ' map_build=25327279')
end
