import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('addon_package', ROOT / 'scripts/package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageTests(unittest.TestCase):
    def test_archive_payload_and_reproducibility(self):
        with tempfile.TemporaryDirectory() as folder:
            files = [Path(folder) / name for name in ('a.zip', 'b.zip')]
            for path in files:
                package.build_addon('mods/liu/auto_reload_rounds', b'return {}\n',
                    '4df5aee3-3c5d-47fc-b0e9-0a40f7988738', path, 'Auto Reload')
            self.assertEqual(files[0].read_bytes(), files[1].read_bytes())
            with zipfile.ZipFile(files[0]) as z:
                self.assertIsNone(z.testzip())
                self.assertEqual(len(z.namelist()), 4)
                manifest = json.loads(z.read('manifest.json'))
                self.assertEqual(manifest['Guid'], '4df5aee3-3c5d-47fc-b0e9-0a40f7988738')
                raw = z.read('Addon/' + package.ARCHIVE)
                self.assertEqual(struct.unpack_from('<III', raw), (0xF0000011, 1, 1))
                entry = struct.unpack_from('<7Q6I', raw, 104)
                start, size = entry[2], entry[7]
                length, mode = struct.unpack_from('<II', raw, start)
                body = raw[start + 8:start + size]
                self.assertEqual(mode, 2)
                self.assertEqual(len(body), length)
                self.assertEqual(body, b'-- HD2-Addon: mods/liu/auto_reload_rounds\nreturn {}\n')

    def test_rejects_mismatched_entry(self):
        with self.assertRaises(ValueError):
            package.build_addon('mods/liu/auto_reload_rounds',
                b'-- HD2-Addon: mods/other/mod\nreturn {}',
                '4df5aee3-3c5d-47fc-b0e9-0a40f7988738', 'unused.zip', 'Test')

    def test_one_archive_contains_reload_and_bundled_menu(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'Auto-Reload.zip'
            menu_name = 'mods/cowboybingus/mod_options_menu'
            package.build_addon('mods/liu/auto_reload_rounds', b'return {}',
                                '4df5aee3-3c5d-47fc-b0e9-0a40f7988738', path, 'Auto Reload',
                                extra_resources={menu_name: b'return {version=4}'})
            with zipfile.ZipFile(path) as z:
                raw = z.read('Addon/' + package.ARCHIVE)
                self.assertEqual(struct.unpack_from('<III', raw), (0xF0000011, 1, 2))
                bodies = {}
                for index in range(2):
                    entry = struct.unpack_from('<7Q6I', raw, 104 + index * 80)
                    start, size = entry[2], entry[7]
                    self.assertEqual(start % 16, 0)
                    length, mode = struct.unpack_from('<II', raw, start)
                    body = raw[start + 8:start + size]
                    self.assertEqual((length, mode), (len(body), 2))
                    bodies[entry[0]] = body
                self.assertIn(package.resource_hash(menu_name), bodies)
                self.assertIn(package.resource_hash('mods/liu/auto_reload_rounds'), bodies)
                self.assertTrue(bodies[package.resource_hash(menu_name)].startswith(
                    b'-- HD2-Addon: mods/cowboybingus/mod_options_menu\n'))


if __name__ == '__main__':
    unittest.main()
