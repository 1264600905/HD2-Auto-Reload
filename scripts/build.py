"""Build the standalone Auto Reload addon (Python standard library only)."""
from pathlib import Path
import hashlib
import argparse
import re

from package import build_addon

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src/auto_reload.lua'
BUILD = ROOT / 'build'
MARKER = '-- STATIC_COMPONENT_READER_INSERT'
DEBUG_MARKER = 'local DEBUG = false -- DEBUG_BUILD_FLAG'
CONFIG_MARKER = '-- RELOAD_CONFIG_INSERT'
MAPS = {
    'MAGAZINE': ROOT / 'data/WeaponMagazineComponent.25327279.map.hex',
    'ROUNDS': ROOT / 'data/WeaponRoundsComponent.25327279.map.hex',
    'HEAT': ROOT / 'data/WeaponHeatComponent.25327279.map.hex',
}
INSERT = (ROOT / 'src/component_maps.lua').read_text(encoding='utf-8')
RELOAD_CONFIG = ROOT / 'src/reload_config.lua'
RULE_LINE = re.compile(
    r"\s*\['([0-9a-f]{16})'\] = \{name='[^']+', path='(weapon_magazine|weapon_rounds)', "
    r"limit=(\d+)(?:, basis='(magazine|total)')?(?:, continuous=(true|false))?(?:, immediate=(true|false))?\},?\s*"
)
ATTACK_LINE = re.compile(r"\s*\['([0-9a-f]{16})'\] = true,?\s*(?:--.*)?")


def validate_reload_config(config):
    if len(re.findall(r'^local ENABLE_TACTICAL_RELOAD = (?:true|false) -- 启用战术换弹$',
                      config, re.M)) != 1:
        raise ValueError('Exactly one build-time tactical switch is required')
    try:
        tactical = config.split('local tactical_rules = {', 1)[1].split('\n}\n', 1)[0]
        attack = config.split('local attack_only_resources = {', 1)[1].split('\n}', 1)[0]
    except IndexError as error:
        raise ValueError('Reload configuration tables are missing') from error
    known = {}
    for component, path in MAPS.items():
        data = bytes.fromhex(path.read_text(encoding='ascii'))
        known['weapon_' + component.lower()] = {
            f'{int.from_bytes(data[i:i + 8], "little"):016x}'
            for i in range(0, len(data), 16)
        }
    seen = set()
    for line in tactical.splitlines():
        if not line.strip().startswith("['"):
            continue
        match = RULE_LINE.fullmatch(line.split('--', 1)[0].rstrip())
        if not match:
            raise ValueError('Invalid tactical rule: ' + line.strip())
        resource_id, path, limit, basis, continuous, immediate = match.groups()
        if resource_id in seen or resource_id not in known[path]:
            raise ValueError('Duplicate or unmatched tactical resource: ' + resource_id)
        if int(limit) > 100000 or (basis == 'total' and path != 'weapon_rounds') or (
                continuous == 'true' and path != 'weapon_rounds'):
            raise ValueError('Invalid tactical rule values: ' + resource_id)
        seen.add(resource_id)
    if not seen:
        raise ValueError('At least one tactical rule is required')
    attack_seen = set()
    for line in attack.splitlines():
        if not line.strip().startswith("['"):
            continue
        match = ATTACK_LINE.fullmatch(line)
        if not match:
            raise ValueError('Invalid attack-only rule: ' + line.strip())
        resource_id = match.group(1)
        if resource_id in attack_seen or not any(resource_id in ids for ids in known.values()):
            raise ValueError('Duplicate or unmatched attack-only resource: ' + resource_id)
        attack_seen.add(resource_id)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-dir', type=Path, help='Optional local game directory for SHA256 verification')
    parser.add_argument('--debug', action='store_true', help='Build a diagnostic package with reload trace logging')
    parser.add_argument('--enable-tactical-reload', action='store_true',
                        help='启用战术换弹 in the built package; no in-game setting')
    args = parser.parse_args()
    expected_hashes = {
        'data/game/game.dll': '73374bd4e38386beb9a23bef480082b67d457ebc77485fbec5f488b4e95e201f',
        'bin/helldivers2.exe': 'd8e23968d1412b07e06785321727d63edf74e711214d6f6adeb3bfca95ca6827'.lower(),
    }
    if args.game_dir:
        for relative, expected in expected_hashes.items():
            if hashlib.sha256((args.game_dir / relative).read_bytes()).hexdigest() != expected:
                raise SystemExit('Unsupported game binary: ' + relative)
    source = SOURCE.read_text(encoding='utf-8')
    reload_config = RELOAD_CONFIG.read_text(encoding='utf-8')
    validate_reload_config(reload_config)
    if args.enable_tactical_reload:
        reload_config = re.sub(
            r'^(local ENABLE_TACTICAL_RELOAD = )(?:true|false)( -- 启用战术换弹)$',
            r'\g<1>true\g<2>', reload_config, count=1, flags=re.M)
    if (source.count(MARKER) != 1 or source.count(DEBUG_MARKER) != 1 or
            source.count(CONFIG_MARKER) != 1):
        raise SystemExit('source build marker missing or duplicated')
    insertion = INSERT
    for name, path in MAPS.items():
        insertion = insertion.replace('__' + name + '_MAP__', bytes.fromhex(path.read_text()).hex())
    generated = source.replace(MARKER, insertion).replace(
        CONFIG_MARKER, reload_config).replace(
        DEBUG_MARKER, 'local DEBUG = ' + str(args.debug).lower() + ' -- DEBUG_BUILD_FLAG')
    BUILD.mkdir(parents=True, exist_ok=True)
    suffix = ('-tactical' if args.enable_tactical_reload else '') + ('-debug' if args.debug else '')
    entry = BUILD / ('auto_reload_entry' + suffix.replace('-', '_') + '.lua')
    entry.write_text(generated, encoding='utf-8', newline='\n')
    output = BUILD / ('Auto-Reload-configurable' + suffix + '.zip')
    build_addon('mods/liu/auto_reload_rounds', generated.encode('utf-8'),
                '4df5aee3-3c5d-47fc-b0e9-0a40f7988738', output,
                'Auto Reload configurable' + (' tactical' if args.enable_tactical_reload else '') +
                (' Debug' if args.debug else '') +
                ' (immediate; Heat; build 25327279)')
    print('Built', output)

if __name__ == '__main__':
    main()
