"""Build the standalone Auto Reload addon (Python standard library only)."""
from pathlib import Path
import hashlib
import argparse

from package import build_addon

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src/auto_reload.lua'
BUILD = ROOT / 'build'
MAG_MAP = ROOT / 'data/WeaponMagazineComponent.map.hex'
RELOAD_MAP = ROOT / 'data/WeaponReloadComponent.map.hex'
MARKER = '-- STATIC_COMPONENT_READER_INSERT'

INSERT = r'''local static_magazine_map = "__MAGAZINE_MAP__"
local static_reload_map = "__RELOAD_MAP__"
local function static_unhex(value)
    return (value:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end))
end
static_magazine_map = static_unhex(static_magazine_map)
static_reload_map = static_unhex(static_reload_map)

local function static_map_matches(address, wanted)
    if not address then return false end
    if api.read(address, 32) ~= wanted:sub(1, 32) then return false end
    for offset = 0, #wanted - 1, 2048 do
        local chunk = wanted:sub(offset + 1, offset + 2048)
        if api.read(address + offset, #chunk) ~= chunk then return false end
    end
    return true
end

local function static_find_table(owner, wanted)
    local direct = api.pointer(api.read(owner + 0xf11078, 8) or '')
    if static_map_matches(direct, wanted) then return direct, nil, 0xf11078 end
    local chunks = {}
    for offset = 0, 0x2fff, 0x1000 do
        local chunk = api.read(owner + 0xf10000 + offset, math.min(0x1000, 0x3000 - offset))
        if not chunk then return nil, 'owner_component_scan_unavailable' end
        chunks[#chunks + 1] = chunk
    end
    local raw = table.concat(chunks)
    local found, found_slot
    for offset = 0, #raw - 8, 8 do
        local candidate = api.pointer(raw:sub(offset + 1, offset + 8))
        if static_map_matches(candidate, wanted) then
            if found and found ~= candidate then return nil, 'ambiguous_component_table' end
            found = candidate
            found_slot = 0xf10000 + offset
        end
    end
    return found, nil, found_slot
end

local function static_record_index(map, resource_id)
    for offset = 0, #map - 16, 16 do
        if resource(map:sub(offset + 1, offset + 8)) == resource_id then
            return u32(map, offset + 8), offset
        end
    end
end

local static_slots = {}
magazine_static_records = function(e, row)
    local result = {}
    for _, spec in ipairs({
        {name='magazine', map=static_magazine_map, stride=160},
        {name='reload', map=static_reload_map, stride=80},
    }) do
        local index, entry_offset = static_record_index(spec.map, row.current_weapon_resource)
        if not index or index >= #spec.map / 16 then return nil end
        local key = tostring(e.owner) .. ':' .. spec.name
        local cached = static_slots[key]
        if not cached or (not cached.slot and state.elapsed >= cached.retry_at) then
            local _, _, slot = static_find_table(e.owner, spec.map)
            cached = {slot=slot, retry_at=state.elapsed + 2}
            static_slots[key] = cached
        end
        if not cached.slot then return nil end
        local address = e.pointer(e.owner + cached.slot, true)
        for offset = 0, #spec.map - 1, 2048 do
            local wanted = spec.map:sub(offset + 1, offset + 2048)
            if e.read(address + offset, #wanted) ~= wanted then
                static_slots[key] = nil
                return nil
            end
        end
        assert(e.read(address + entry_offset, 16, true) ==
            spec.map:sub(entry_offset + 1, entry_offset + 16), 'static_resource_identity_changed')
        result[spec.name] = e.read(address + #spec.map + index * spec.stride, spec.stride, true)
    end
    return result
end

static_component_snapshot = function(row)
    local owner = row._game_owner
    if not owner then emit('STATIC_COMPONENT_SKIP resource=' .. tostring(row.current_weapon_resource) .. ' reason=owner_missing'); return end
    local magazine_index = static_record_index(static_magazine_map, row.current_weapon_resource)
    local reload_index = static_record_index(static_reload_map, row.current_weapon_resource)
    if not magazine_index and not reload_index then
        emit('STATIC_COMPONENT_SKIP resource=' .. tostring(row.current_weapon_resource) .. ' reason=resource_not_in_reference_maps')
        return
    end
    local magazine_table, magazine_reason = static_find_table(owner, static_magazine_map)
    local reload_table, reload_reason = static_find_table(owner, static_reload_map)
    if magazine_index and magazine_table then
        local record = api.read(magazine_table + #static_magazine_map + magazine_index * 160, 160)
        if record then
            emit(string.format('STATIC_MAGAZINE resource=%s index=%d record=0x%X fields_0x8c=%d fields_0x90=%d fields_0x94=%d',
                row.current_weapon_resource, magazine_index,
                magazine_table + #static_magazine_map + magazine_index * 160,
                u32(record, 140), u32(record, 144), u32(record, 148)))
        else
            emit('STATIC_MAGAZINE_ERROR resource=' .. row.current_weapon_resource .. ' reason=record_read_failed')
        end
    elseif magazine_index then
        emit('STATIC_MAGAZINE_ERROR resource=' .. row.current_weapon_resource .. ' reason=' .. tostring(magazine_reason))
    end
    if reload_index and reload_table then
        local record = api.read(reload_table + #static_reload_map + reload_index * 80, 80)
        if record then
            emit(string.format('STATIC_RELOAD resource=%s index=%d record=0x%X field_0x38=%s',
                row.current_weapon_resource, reload_index,
                reload_table + #static_reload_map + reload_index * 80,
                hex(record:sub(57, 60))))
        else
            emit('STATIC_RELOAD_ERROR resource=' .. row.current_weapon_resource .. ' reason=record_read_failed')
        end
    elseif reload_index then
        emit('STATIC_RELOAD_ERROR resource=' .. row.current_weapon_resource .. ' reason=' .. tostring(reload_reason))
    end
end
'''

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-dir', type=Path, help='Optional local game directory for SHA256 verification')
    args = parser.parse_args()
    expected_hashes = {
        'data/game/game.dll': 'cc75948d90fdfde259dcb519e9933db7ffa3ccb281ce4fb89e6b1b011557470c',
        'bin/helldivers2.exe': 'a09ff52663e73b94fb0cac0dcB5ba84ffd10ecf44f74a8921ac66af923988cc3'.lower(),
    }
    if args.game_dir:
        for relative, expected in expected_hashes.items():
            if hashlib.sha256((args.game_dir / relative).read_bytes()).hexdigest() != expected:
                raise SystemExit('Unsupported game binary: ' + relative)
    source = SOURCE.read_text(encoding='utf-8')
    if MARKER not in source:
        raise SystemExit('static component marker missing')
    insertion = INSERT.replace('__MAGAZINE_MAP__', bytes.fromhex(MAG_MAP.read_text()).hex())
    insertion = insertion.replace('__RELOAD_MAP__', bytes.fromhex(RELOAD_MAP.read_text()).hex())
    generated = source.replace(MARKER, insertion)
    BUILD.mkdir(parents=True, exist_ok=True)
    entry = BUILD / 'auto_reload_entry.lua'
    entry.write_text(generated, encoding='utf-8', newline='\n')
    output = BUILD / 'Auto-Reload-v4.zip'
    build_addon('mods/liu/auto_reload_rounds', generated.encode('utf-8'),
                '4df5aee3-3c5d-47fc-b0e9-0a40f7988738', output,
                'Auto Reload v4 (1s; Heat Diagnostic)')
    print('Built', output)

if __name__ == '__main__':
    main()
