#include "axivc_tests.h"

#include <zephyr/sys/atomic.h>
#include <zephyr/sys/printk.h>

namespace {
constexpr uint32_t sample_target = 10000;
constexpr uint32_t warmup_target = 5;
static_assert(CONFIG_MP_MAX_NUM_CPUS == 1,
              "The ARM timer observer supports one guest vCPU");
struct distribution {
    uint64_t minimum = UINT64_MAX;
    uint64_t maximum = 0;
    uint64_t total = 0;
};
struct measurement {
    uint32_t samples = 0;
    uint32_t warmup = 0;
    uint32_t skipped = 0;
    uint32_t tick_cycles = 0;
    uint64_t previous_entry = 0;
    uint64_t previous_compare = 0;
    bool bad_context = false;
    distribution deadline_deviation;
    distribution interval_deviation;
};
k_spinlock measurement_lock;
atomic_t observing = ATOMIC_INIT(0);
measurement data;

void accumulate(distribution &stats, uint64_t cycles)
{
    stats.minimum = cycles < stats.minimum ? cycles : stats.minimum;
    stats.maximum = cycles > stats.maximum ? cycles : stats.maximum;
    stats.total += cycles;
}

uint64_t difference(uint64_t actual, uint64_t expected)
{
    return actual >= expected ? actual - expected : expected - actual;
}

void keep_timer_active(struct k_timer *) {}
// A 1 ms heartbeat keeps real timer IRQs flowing while retaining tickless mode.
K_TIMER_DEFINE(measurement_heartbeat, keep_timer_active, nullptr);

void print_distribution(const char *name, const distribution &stats, uint32_t count)
{
    const uint64_t average = stats.total / count;
    printk("%s samples=%u min_cycles=%llu avg_cycles=%llu max_cycles=%llu\n",
           name, count, static_cast<unsigned long long>(stats.minimum),
           static_cast<unsigned long long>(average),
           static_cast<unsigned long long>(stats.maximum));
    printk("%s min_ns=%llu avg_ns=%llu max_ns=%llu\n", name,
           static_cast<unsigned long long>(k_cyc_to_ns_floor64(stats.minimum)),
           static_cast<unsigned long long>(k_cyc_to_ns_floor64(average)),
           static_cast<unsigned long long>(k_cyc_to_ns_floor64(stats.maximum)));
}
}

extern "C" void orangepi_timer_irq_sample(uint64_t now, uint64_t tick_base,
                                           uint32_t tick_cycles, uint64_t compare)
{
    if (!atomic_get(&observing)) return;
    const k_spinlock_key_t key = k_spin_lock(&measurement_lock);
    if (!atomic_get(&observing)) {
        k_spin_unlock(&measurement_lock, key);
        return;
    }
    data.tick_cycles = tick_cycles;
    if (!k_is_in_isr()) {
        data.bad_context = true;
        atomic_set(&observing, 0);
    } else if (data.warmup++ < warmup_target || !tick_base ||
               !compare || compare == UINT64_MAX) {
        // Discard startup samples; remember the last actual timer event.
    } else if (now <= data.previous_entry || compare <= data.previous_compare ||
               now < tick_base || compare < tick_base) {
        ++data.skipped;
    } else {
        const uint64_t actual_tick_window = now - tick_base;
        const uint64_t programmed_tick_window = compare - tick_base;
        // With a periodic timer this is abs(now - last_cycle - CYC_PER_TICK),
        // matching the reference. Tickless uses the actual programmed window.
        accumulate(data.deadline_deviation,
                   difference(actual_tick_window, programmed_tick_window));
        accumulate(data.interval_deviation,
                   difference(now - data.previous_entry,
                              compare - data.previous_compare));
        if (++data.samples == sample_target) atomic_set(&observing, 0);
    }
    data.previous_entry = now;
    data.previous_compare = compare;
    k_spin_unlock(&measurement_lock, key);
}

int run_irq_latency(int64_t deadline)
{
    k_spinlock_key_t key = k_spin_lock(&measurement_lock);
    data = measurement{};
    atomic_set(&observing, 1);
    k_spin_unlock(&measurement_lock, key);
    printk("IRQ_LATENCY_BEGIN source=arch_timer samples=%u warmup=%u tickless=%d heartbeat_ms=1\n",
           sample_target, warmup_target, IS_ENABLED(CONFIG_TICKLESS_KERNEL));
    k_timer_start(&measurement_heartbeat, K_MSEC(1), K_MSEC(1));
    int ret = 0;
    measurement snapshot;
    for (;;) {
        key = k_spin_lock(&measurement_lock);
        snapshot = data;
        k_spin_unlock(&measurement_lock, key);
        if (snapshot.bad_context) {
            ret = -EIO;
            break;
        }
        if (snapshot.samples == sample_target) break;
        ret = workload_abort_result(deadline);
        if (ret) break;
        k_sleep(K_MSEC(5));
    }
    key = k_spin_lock(&measurement_lock);
    atomic_set(&observing, 0);
    snapshot = data;
    k_spin_unlock(&measurement_lock, key);
    // Never acquire the clock lock while holding measurement_lock. The ISR
    // takes clock -> measurement; timer operations run after releasing it.
    k_timer_stop(&measurement_heartbeat);
    if (snapshot.samples) {
        print_distribution("IRQ_LATENCY", snapshot.deadline_deviation, snapshot.samples);
        print_distribution("IRQ_INTERVAL_DEVIATION", snapshot.interval_deviation, snapshot.samples);
    }
    printk("IRQ_TIMER_STATS tick_cycles=%u skipped=%u\n", snapshot.tick_cycles, snapshot.skipped);
    if (ret) {
        printk("IRQ_LATENCY_%s result=%d samples=%u\n",
               ret == -ECANCELED ? "CANCELED" : "FAILED", ret, snapshot.samples);
        return ret;
    }
    printk("IRQ_LATENCY_PASSED\n");
    return 0;
}
