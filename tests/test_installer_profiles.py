"""Verify the actual install sequence, without running any installer jobs."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'airootfs/etc/calamares'
spec = importlib.util.spec_from_file_location(
    'installer', ROOT / 'airootfs/usr/local/lib/horizon-installer/installer.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class ProfileTests(unittest.TestCase):
    def profile(self, mode, auto_drivers=False):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        destination = Path(temp.name)
        installer.prepare_profile(SOURCE, destination, mode, auto_drivers)
        return destination, yaml.safe_load((destination / 'settings.conf').read_text())

    def test_offline_cannot_queue_extra_packages(self):
        _, settings = self.profile('offline')
        steps = [step for phase in settings['sequence']
                 for sequence in phase.values() for step in sequence]
        self.assertFalse(set(steps) & installer.DOWNLOAD_JOBS)
        for job in ('unpackfs@rootfs', 'initcpio', 'bootloader', 'umount'):
            self.assertIn(job, steps)

    def test_online_exposes_every_group_and_installs_before_initramfs(self):
        directory, settings = self.profile('online')
        show = settings['sequence'][0]['show']
        for name in ('drivers', 'software'):
            self.assertLess(show.index(f'netinstall@{name}'), show.index('summary'))
            groups = yaml.safe_load((directory / f'modules/{name}.yaml').read_text())
            self.assertTrue(groups)
            self.assertTrue(all(not group['hidden'] for group in groups))
            config = yaml.safe_load((directory / f'modules/net_{name}.conf').read_text())
            self.assertEqual(config['groupsUrl'], (directory / f'modules/{name}.yaml').as_uri())
        jobs = settings['sequence'][1]['exec']
        self.assertLess(jobs.index('packages'), jobs.index('initcpiocfg'))
        package = yaml.safe_load((directory / 'modules/packages.conf').read_text())
        self.assertEqual(package['backend'], 'pacman')
        self.assertTrue(package['update_db'])
        self.assertFalse(package['skip_if_no_internet'])
        welcome = yaml.safe_load((directory / 'modules/welcome.conf').read_text())
        self.assertIn('internet', welcome['requirements']['required'])

    def test_profiles_do_not_modify_source_or_leak_online_state(self):
        original = (SOURCE / 'settings.conf').read_bytes()
        directory, _ = self.profile('online')
        installer.prepare_profile(SOURCE, directory, 'offline')
        settings = yaml.safe_load((directory / 'settings.conf').read_text())
        self.assertNotIn('packages', settings['sequence'][1]['exec'])
        self.assertEqual((SOURCE / 'settings.conf').read_bytes(), original)
        package = yaml.safe_load((directory / 'modules/packages.conf').read_text())
        self.assertEqual(package['backend'], 'dummy')

    def test_automatic_drivers_are_opt_in_and_run_before_initramfs(self):
        for enabled in (False, True):
            with self.subTest(auto_drivers=enabled):
                _, settings = self.profile('online', enabled)
                jobs = settings['sequence'][1]['exec']
                for vendor in ('nvidia', 'amd', 'intel'):
                    job = f'shellprocess@{vendor}-autodetect'
                    self.assertEqual(job in jobs, enabled)
                    if enabled:
                        self.assertLess(jobs.index('packages'), jobs.index(job))
                        self.assertLess(jobs.index(job), jobs.index('initcpiocfg'))

    def test_offline_ignores_automatic_driver_request(self):
        _, settings = self.profile('offline', True)
        jobs = settings['sequence'][1]['exec']
        self.assertFalse(set(jobs) & installer.DOWNLOAD_JOBS)

    def test_unknown_mode_rejected(self):
        with self.assertRaises(ValueError):
            installer.prepare_profile(SOURCE, '/unused', 'automatic')


if __name__ == '__main__':
    unittest.main()
