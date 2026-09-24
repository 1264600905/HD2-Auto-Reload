"""Validate build-time rules against the exact build-25327279 component maps."""

from pathlib import Path
import re
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from build import validate_reload_config  # noqa: E402


class ReloadConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = (ROOT / 'src/reload_config.lua').read_text(encoding='utf-8')

    def test_rules_match_known_component_maps(self):
        validate_reload_config(self.config)
        tactical = self.config.split('local tactical_rules = {', 1)[1].split('\n}\n', 1)[0]
        ids = re.findall(r"\['([0-9a-f]{16})'\] = \{name=", tactical)
        self.assertEqual((len(ids), len(set(ids))), (50, 50))
        for excluded in ('80f1a156d9fa1e36',  # JAR-5
                         'a32621e3bde13379',  # Guard Dog AR-23
                         '54d86057f5dacfb9'):  # AC-8 sentry
            self.assertNotIn(excluded, ids)
        self.assertIn('05d8d8c073b9d502', ids)  # SG-8P

    def test_plan_two_thresholds_and_immediate_policy(self):
        rules = re.findall(r"name='([^']+)', path='[^']+', limit=(\d+)([^}]*)", self.config)
        fast = 0
        for name, limit, options in rules:
            expected = (10 if name.startswith('M-105') else
                        3 if name.startswith(('AR', 'SMG')) or name in
                        ('BR-14', 'M7S', 'StA-11', 'P-2', 'P-19', 'M6C/SOCOM') else None)
            if expected is not None:
                fast += 1
                self.assertEqual(int(limit), expected, name)
                self.assertIn('immediate=true', options, name)
            else:
                self.assertNotIn('immediate=true', options, name)
        self.assertEqual(fast, 22)

    def test_existing_total_thresholds_are_retained(self):
        for name, limit in (('SG-97', 4), ('GL-15', 2)):
            self.assertRegex(self.config, re.escape("name='" + name + "', path='weapon_rounds', ") +
                             rf"limit={limit}, basis='total', continuous=true")

    def test_bad_rule_is_rejected_before_packaging(self):
        for invalid in (
            self.config.replace('84354339522c932d', '0000000000000001', 1),
            self.config.replace('968211c0033dce64', '84354339522c932d', 1),
            self.config.replace("name='AR-2', path='weapon_magazine'",
                                "name='AR-2', path='weapon_rounds'", 1),
        ):
            with self.subTest(invalid=invalid != self.config):
                with self.assertRaises(ValueError):
                    validate_reload_config(invalid)


if __name__ == '__main__':
    unittest.main()
