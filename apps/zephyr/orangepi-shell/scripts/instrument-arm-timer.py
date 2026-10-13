#!/usr/bin/env python3
"""Add an app-scoped observer to a generated copy of Zephyr's timer driver."""
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
include = '#include <zephyr/arch/cpu.h>\n'
account = '\tlast_cycle += (cycle_diff_t)delta_ticks * CYC_PER_TICK;'
if source.count(include) != 1 or source.count(account) != 1 or source.count('arm_arch_timer_set_compare(') != 5:
    raise SystemExit('ARM timer driver changed: review observer anchors before building')
source = source.replace('arm_arch_timer_set_compare(', 'orangepi_observe_set_compare(')
observer = '''
/* App-only measurement: preserve the upstream timer programming and tick
 * accounting. The single-vCPU driver owns this value under sys_clock_lock. */
extern void orangepi_timer_irq_sample(uint64_t now, uint64_t tick_base,
                                     uint32_t tick_cycles, uint64_t compare);
static uint64_t orangepi_programmed_compare;

static void orangepi_observe_set_compare(uint64_t compare)
{
    orangepi_programmed_compare = compare;
    arm_arch_timer_set_compare(compare);
}
'''
source = source.replace(include, include + observer)
source = source.replace(account, '\torangepi_timer_irq_sample(curr_cycle, last_cycle,\n\t\t\t\t  CYC_PER_TICK, orangepi_programmed_compare);\n\n' + account)
Path(sys.argv[2]).write_text(source)
