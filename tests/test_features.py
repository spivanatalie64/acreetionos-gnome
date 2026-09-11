"""Unit tests for Calamares enhancements:
- Hardware driver auto-detection and preselection
- Automatic location, timezone, and keyboard layout configuration
- Zswap and zram compatibility
- Windows/macOS/Linux data preservation and restoration
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
CALAMARES_ETC = ROOT / 'airootfs/etc/calamares'
HORIZON_LIB = ROOT / 'airootfs/usr/local/lib/horizon-installer'

spec_hw = importlib.util.spec_from_file_location('hardware_detect', HORIZON_LIB / 'hardware_detect.py')
hw_detect = importlib.util.module_from_spec(spec_hw)
spec_hw.loader.exec_module(hw_detect)

spec_mig = importlib.util.spec_from_file_location('migration_backup', HORIZON_LIB / 'migration_backup.py')
migration = importlib.util.module_from_spec(spec_mig)
spec_mig.loader.exec_module(migration)

spec_rest = importlib.util.spec_from_file_location('restore_data', HORIZON_LIB / 'restore_data.py')
restore_data = importlib.util.module_from_spec(spec_rest)
spec_rest.loader.exec_module(restore_data)


class CalamaresConfigTests(unittest.TestCase):
    def test_keyboard_conf(self):
        kb_path = CALAMARES_ETC / 'modules/keyboard.conf'
        self.assertTrue(kb_path.is_file(), "keyboard.conf should exist")
        data = yaml.safe_load(kb_path.read_text())
        self.assertTrue(data.get('guessLayout'), "guessLayout must be true")
        self.assertTrue(data.get('useLocale1'), "useLocale1 must be true")

    def test_welcome_conf_geoip(self):
        welcome_path = CALAMARES_ETC / 'modules/welcome.conf'
        data = yaml.safe_load(welcome_path.read_text())
        self.assertEqual(data.get('geoip', {}).get('style'), 'json')
        self.assertEqual(data.get('geoip', {}).get('selector'), 'country')

    def test_locale_conf(self):
        locale_path = CALAMARES_ETC / 'modules/locale.conf'
        data = yaml.safe_load(locale_path.read_text())
        self.assertTrue(data.get('useSystemTimezone'))
        self.assertEqual(data.get('geoip', {}).get('style'), 'json')
        self.assertEqual(data.get('geoip', {}).get('selector'), 'timezone')

    def test_grub_zswap_params(self):
        grub_path = CALAMARES_ETC / 'modules/grubcfg.conf'
        content = grub_path.read_text()
        self.assertIn('zswap.enabled=1', content)
        self.assertIn('zswap.compressor=zstd', content)

    def test_settings_conf_includes_zram_and_restore(self):
        settings_path = CALAMARES_ETC / 'settings.conf'
        data = yaml.safe_load(settings_path.read_text())
        instances = {inst['id']: inst for inst in data['instances']}
        self.assertIn('zswap-zram', instances)
        self.assertIn('restore-data', instances)

        exec_steps = next(phase['exec'] for phase in data['sequence'] if 'exec' in phase)
        self.assertIn('shellprocess@zswap-zram', exec_steps)
        self.assertIn('shellprocess@restore-data', exec_steps)
        self.assertLess(exec_steps.index('shellprocess@restore-data'), exec_steps.index('umount'))


class HardwareDetectionTests(unittest.TestCase):
    def test_detect_cpu(self):
        with tempfile.NamedTemporaryFile('w', delete=False) as f:
            f.write("vendor_id\t: AuthenticAMD\nmodel name\t: AMD Ryzen 7\n")
            amd_file = f.name
        try:
            vendor, desc, pkgs, groups = hw_detect.detect_cpu(cpuinfo_path=amd_file)
            self.assertEqual(vendor, 'amd')
            self.assertIn('amd-ucode', pkgs)
            self.assertIn('Amd-ucode (microcode)', groups)
        finally:
            os.unlink(amd_file)

        with tempfile.NamedTemporaryFile('w', delete=False) as f:
            f.write("vendor_id\t: GenuineIntel\nmodel name\t: Intel Core i7\n")
            intel_file = f.name
        try:
            vendor, desc, pkgs, groups = hw_detect.detect_cpu(cpuinfo_path=intel_file)
            self.assertEqual(vendor, 'intel')
            self.assertIn('intel-ucode', pkgs)
            self.assertIn('Intel-ucode (microcode)', groups)
        finally:
            os.unlink(intel_file)

    def test_detect_gpu_normalizes_pci_identifiers(self):
        nvidia_gpu = {
            "vendor": "10de",
            "device": "2520",
            "class": "0x030000",
            "slot": "0000:01:00.0",
        }
        amd_gpu = {
            "vendor": "1002",
            "device": "73bf",
            "class": "0x030000",
            "slot": "0000:05:00.0",
        }
        intel_gpu = {
            "vendor": "8086",
            "device": "9a49",
            "class": "0x038000",
            "slot": "0000:00:02.0",
        }

        detected_nvidia = hw_detect.detect_gpu([nvidia_gpu])
        self.assertTrue(detected_nvidia)
        self.assertEqual(detected_nvidia[0]["vendor"], "nvidia")
        self.assertIn("nvidia-open-dkms", detected_nvidia[0]["packages"])

        detected_amd = hw_detect.detect_gpu([amd_gpu])
        self.assertTrue(detected_amd)
        self.assertEqual(detected_amd[0]["vendor"], "amd")

        detected_intel = hw_detect.detect_gpu([intel_gpu])
        self.assertTrue(detected_intel)
        self.assertEqual(detected_intel[0]["vendor"], "intel")

    def test_apply_hardware_to_drivers_catalogue(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            catalogue = Path(tmpdir) / "drivers.yaml"
            catalogue.write_text(yaml.safe_dump([
                {
                    "name": "Latest Linux-Lts Kernel",
                    "selected": True,
                    "hidden": False,
                    "packages": ["linux-lts"]
                },
                {
                    "name": "AMD Graphics Drivers",
                    "selected": False,
                    "hidden": True,
                    "packages": ["vulkan-radeon"]
                },
                {
                    "name": "Intel Graphics Drivers",
                    "selected": False,
                    "hidden": True,
                    "packages": ["vulkan-intel"]
                },
                {
                    "name": "Amd-ucode (microcode)",
                    "selected": False,
                    "hidden": True,
                    "packages": ["amd-ucode"]
                }
            ]))

            mock_hw = {
                "cpu": {"vendor": "amd", "desc": "AMD CPU", "packages": ["amd-ucode"], "groups": ["Amd-ucode (microcode)"]},
                "gpus": [{
                    "vendor": "amd", "arch": "amdgpu", "desc": "AMD Radeon",
                    "packages": ["vulkan-radeon"], "groups": ["AMD Graphics Drivers"]
                }],
                "network": [],
                "recommended_groups": ["Amd-ucode (microcode)", "AMD Graphics Drivers"]
            }

            hw_detect.apply_hardware_to_drivers_catalogue(catalogue, mock_hw)
            updated = yaml.safe_load(catalogue.read_text())
            by_name = {g["name"]: g for g in updated}

            self.assertTrue(by_name["AMD Graphics Drivers"]["selected"])
            self.assertFalse(by_name["AMD Graphics Drivers"]["hidden"])
            self.assertTrue(by_name["Amd-ucode (microcode)"]["selected"])
            self.assertFalse(by_name["Intel Graphics Drivers"]["selected"])
            self.assertTrue(by_name["Latest Linux-Lts Kernel"]["selected"])


class MigrationAndRestoreTests(unittest.TestCase):
    def test_identify_os_on_partition(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            p = Path(tmpdir)
            # Test Windows detection
            (p / "Windows").mkdir()
            (p / "Users").mkdir()
            os_type, desc = migration.identify_os_on_partition(p, "ntfs")
            self.assertEqual(os_type, "Windows")
            shutil.rmtree(p / "Windows")
            shutil.rmtree(p / "Users")

            # Test macOS detection
            (p / "System/Library/CoreServices").mkdir(parents=True)
            (p / "Users").mkdir()
            os_type, desc = migration.identify_os_on_partition(p, "apfs")
            self.assertEqual(os_type, "macOS")
            shutil.rmtree(p / "System")
            shutil.rmtree(p / "Users")

            # Test Linux detection
            (p / "etc").mkdir()
            (p / "etc/os-release").write_text('PRETTY_NAME="Ubuntu 24.04 LTS"\n')
            os_type, desc = migration.identify_os_on_partition(p, "ext4")
            self.assertEqual(os_type, "Linux")
            self.assertIn("Ubuntu", desc)

    def test_restore_data(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            target_root = Path(tmpdir) / "target"
            target_root.mkdir()
            user_home = target_root / "home/testuser"
            user_home.mkdir(parents=True)

            staging_dir = Path(tmpdir) / "staging"
            staging_dir.mkdir()
            (staging_dir / "my_document.txt").write_text("Hello AcreetionOS")
            (staging_dir / "Photos").mkdir()
            (staging_dir / "Photos/image.jpg").write_text("image_bytes")

            # Temporarily patch BACKUP_DIR
            original_backup = restore_data.BACKUP_DIR
            restore_data.BACKUP_DIR = staging_dir
            try:
                ret = restore_data.restore_user_files(target_root=str(target_root))
                self.assertEqual(ret, 0)
                dest = user_home / "Preserved_Files"
                self.assertTrue((dest / "my_document.txt").is_file())
                self.assertEqual((dest / "my_document.txt").read_text(), "Hello AcreetionOS")
                self.assertTrue((dest / "Photos/image.jpg").is_file())
            finally:
                restore_data.BACKUP_DIR = original_backup


if __name__ == '__main__':
    unittest.main()

