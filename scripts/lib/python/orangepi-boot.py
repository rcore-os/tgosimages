#!/usr/bin/env python3
"""Select AxVisor and its actual root partition in the vendor RK3588 script."""
import argparse
from pathlib import Path
import re
import struct
import sys


def script_source(payload):
    # dumpimage removes the legacy image header, but a script payload still
    # begins with its big-endian component length and terminating zero word.
    if len(payload) < 8:
        raise ValueError('unsupported legacy script payload')
    size, terminator = struct.unpack('>II', payload[:8])
    if terminator != 0 or size != len(payload) - 8:
        raise ValueError('unsupported legacy script component layout')
    return payload[8:].decode('utf-8')


def linux_script(source, root_partition):
    if type(root_partition) is not int or root_partition < 1:
        raise ValueError('invalid root partition number')
    # Both boot modes must query the deployed disk rather than retain UUIDs
    # from the vendor image. Recomposition replaces our previous query block.
    source = re.sub(r'(?ms)^# TGOS root selection begin\n.*?^# TGOS root selection end\n',
                    '', source)
    root_query = (
        '# TGOS root selection begin\n'
        f'if part uuid ${{devtype}} ${{devnum}}:{root_partition} axvisor_root_partuuid; then\n'
        '    echo "Boot root PARTUUID: ${axvisor_root_partuuid}"\n'
        'else\n'
        f'    echo "AxVisor: root partition {root_partition} not found"\n'
        '    exit 1\n'
        'fi\n'
        '# TGOS root selection end\n'
    )
    source, roots = re.subn(
        r'''(?m)^([ \t]*setenv[ \t]+bootargs[ \t]+["']?root=)[^\s"']+''',
        lambda match: root_query + match[1] + 'PARTUUID=${axvisor_root_partuuid}', source)
    if roots != 1:
        raise ValueError('unsupported Orange Pi boot script: expected one root argument')
    return source


def axvisor_script(source, root_partition):
    source = linux_script(source, root_partition)
    source, kernels = re.subn(
        r'(?m)^([ \t]*load[ \t]+[^\n]*\$\{kernel_addr_r\}[ \t]+)\$\{prefix\}Image[ \t]*$',
        r'\1${prefix}AxVisor.bin', source)
    source, ramdisks = re.subn(
        r'(?m)^[ \t]*load[ \t]+[^\n]*\$\{ramdisk_addr_r\}[ \t]+\$\{prefix\}uInitrd[ \t]*(?:\n|$)',
        '', source)
    source, boots = re.subn(
        r'(?m)^([ \t]*booti[ \t]+\$\{kernel_addr_r\}[ \t]+)\$\{ramdisk_addr_r\}([ \t]+\$\{fdt_addr_r\}[ \t]*)$',
        r'\1-\2', source)
    if (kernels, ramdisks, boots) != (1, 1, 1):
        raise ValueError('unsupported Orange Pi boot script: expected one root argument, Image load, uInitrd load and booti command')
    return '# Default: AxVisor.bin. Linux startup: boot-linux.scr.\n' + source


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('payload', type=Path)
    parser.add_argument('linux_output', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--root-partition', type=int, required=True)
    args = parser.parse_args()
    try:
        source = script_source(args.payload.read_bytes())
        result = axvisor_script(source, args.root_partition)
        args.linux_output.write_text(linux_script(source, args.root_partition))
        args.output.write_text(result)
    except (OSError, ValueError) as error:
        print(f'orangepi-boot: {error}', file=sys.stderr)
        sys.exit(1)
