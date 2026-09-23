"""Build the standalone Auto Reload addon (Python standard library only)."""
from pathlib import Path
import hashlib
import argparse

from package import build_addon

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src/auto_reload.lua'
BUILD = ROOT / 'build'
MARKER = '-- STATIC_COMPONENT_READER_INSERT'
DEBUG_MARKER = 'local DEBUG = false -- DEBUG_BUILD_FLAG'
MAPS = {
    'MAGAZINE': ROOT / 'data/WeaponMagazineComponent.25327279.map.hex',
    'ROUNDS': ROOT / 'data/WeaponRoundsComponent.25327279.map.hex',
    'HEAT': ROOT / 'data/WeaponHeatComponent.25327279.map.hex',
}
INSERT = (ROOT / 'src/component_maps.lua').read_text(encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-dir', type=Path, help='Optional local game directory for SHA256 verification')
    parser.add_argument('--debug', action='store_true', help='Build a diagnostic package with reload trace logging')
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
    if source.count(MARKER) != 1 or source.count(DEBUG_MARKER) != 1:
        raise SystemExit('source build marker missing or duplicated')
    insertion = INSERT
    for name, path in MAPS.items():
        insertion = insertion.replace('__' + name + '_MAP__', bytes.fromhex(path.read_text()).hex())
    generated = source.replace(MARKER, insertion).replace(
        DEBUG_MARKER, 'local DEBUG = ' + str(args.debug).lower() + ' -- DEBUG_BUILD_FLAG')
    BUILD.mkdir(parents=True, exist_ok=True)
    entry = BUILD / ('auto_reload_entry_debug.lua' if args.debug else 'auto_reload_entry.lua')
    entry.write_text(generated, encoding='utf-8', newline='\n')
    output = BUILD / ('Auto-Reload-function-test-fork-r36-zero-debug.zip' if args.debug else 'Auto-Reload-function-test-fork-r36-zero.zip')
    build_addon('mods/liu/auto_reload_rounds', generated.encode('utf-8'),
                '4df5aee3-3c5d-47fc-b0e9-0a40f7988738', output,
                'Auto Reload function-test-fork R36 zero' + (' Debug' if args.debug else '') +
                ' (1s; Heat; build 25327279)')
    print('Built', output)

if __name__ == '__main__':
    main()
