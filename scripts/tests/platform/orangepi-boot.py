#!/usr/bin/env python3
"""Verify the Orange Pi boot-script transformation against its vendor source."""
import importlib.util
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
HELPER = ROOT / 'scripts/lib/python/orangepi-boot.py'


class OrangePiBootTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('orangepi_boot', HELPER)
        self.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.helper)
        self.root_partition = 3
        self.source = '''setenv bootargs "root=UUID=54516f99-1a85-4579-a27c-c0f42a9c8650 rw rootwait"
load ${devtype} ${devnum} ${ramdisk_addr_r} ${prefix}uInitrd
load ${devtype} ${devnum} ${kernel_addr_r} ${prefix}Image
load ${devtype} ${devnum} ${fdt_addr_r} ${prefix}dtb/${fdtfile}
fdt addr ${fdt_addr_r}
booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}
'''

    def test_axvisor_selects_actual_root_partition_and_reuses_device_tree_without_linux_initrd(self):
        result = self.helper.axvisor_script(self.source, self.root_partition)
        self.assertIn('load ${devtype} ${devnum} ${kernel_addr_r} ${prefix}AxVisor.bin\n', result)
        self.assertIn('booti ${kernel_addr_r} - ${fdt_addr_r}\n', result)
        self.assertNotIn('uInitrd', result)
        self.assertIn('if part uuid ${devtype} ${devnum}:3 axvisor_root_partuuid; then\n', result)
        self.assertIn('setenv bootargs "root=PARTUUID=${axvisor_root_partuuid} rw rootwait"\n', result)
        self.assertNotIn('root=UUID=', result)
        self.assertIn('load ${devtype} ${devnum} ${fdt_addr_r} ${prefix}dtb/${fdtfile}\n', result)

    def test_unknown_kernel_loader_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'unsupported'):
            self.helper.axvisor_script(self.source.replace('${prefix}Image', '${prefix}unknown'), self.root_partition)

    def test_legacy_script_component_table_is_removed(self):
        source = self.source.encode()
        payload = struct.pack('>II', len(source), 0) + source
        self.assertEqual(self.helper.script_source(payload), self.source)

    def test_invalid_legacy_component_size_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'unsupported'):
            self.helper.script_source(struct.pack('>II', 1000, 0) + b'booti')

    def test_multiple_kernel_loads_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'unsupported'):
            self.helper.axvisor_script(self.source +
                'load ${devtype} ${devnum} ${kernel_addr_r} ${prefix}Image\n', self.root_partition)

    def test_invalid_partition_number_is_rejected(self):
        with self.assertRaises(ValueError):
            self.helper.axvisor_script(self.source, 'invalid; boot')

    def test_linux_fallback_resolves_root_instead_of_retaining_vendor_partuuid(self):
        stale = '917e3513-75b6-4fe1-b12c-885ce0eea214'
        source = self.source.replace('UUID=54516f99-1a85-4579-a27c-c0f42a9c8650',
                                     'PARTUUID=' + stale)
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            payload = work / 'payload'
            encoded = source.encode()
            payload.write_bytes(struct.pack('>II', len(encoded), 0) + encoded)
            linux, axvisor = work / 'linux.cmd', work / 'axvisor.cmd'
            subprocess.run(['python3', str(HELPER), str(payload), str(linux),
                            str(axvisor), '--root-partition', '3'], check=True)
            result = linux.read_text()
            self.assertNotIn(stale, result)
            self.assertIn('part uuid ${devtype} ${devnum}:3 ', result)
            self.assertIn('${prefix}Image\n', result)
            self.assertIn('${prefix}uInitrd\n', result)
            self.assertIn('booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}\n', result)
            self.assertNotIn('${prefix}AxVisor.bin', result)

            # Recomposition uses the saved Linux script. Replace the previous
            # root-selection block instead of leaving a stale partition lookup.
            encoded = result.encode()
            payload.write_bytes(struct.pack('>II', len(encoded), 0) + encoded)
            subprocess.run(['python3', str(HELPER), str(payload), str(linux),
                            str(axvisor), '--root-partition', '2'], check=True)
            for output in (linux, axvisor):
                result = output.read_text()
                self.assertNotIn('${devnum}:3 ', result)
                self.assertEqual(result.count('part uuid ${devtype} ${devnum}:2 '), 1)


if __name__ == '__main__':
    unittest.main()
