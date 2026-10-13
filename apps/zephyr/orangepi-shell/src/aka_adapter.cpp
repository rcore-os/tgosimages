#include "aka_adapter.h"
#include <errno.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/atomic.h>

#if defined(TGOS_AKA_RK3588)
/* A strong reference also extracts the entry from a static library. */
extern "C" int aka_rk3588_run(void);
#else
extern "C" int aka_rk3588_run(void) __attribute__((weak));
#endif

namespace {
K_THREAD_STACK_DEFINE(aka_stack, 16384);
k_thread aka_thread;
atomic_t state = ATOMIC_INIT(0);
atomic_t result = ATOMIC_INIT(0);

void worker(void *, void *, void *)
{
    const int rc = aka_rk3588_run();
    atomic_set(&result, rc);
    atomic_set(&state, 2);
    printk("AKA_WORKLOAD_EXIT result=%d\n", rc);
}
}

int aka_adapter_run()
{
#if !defined(TGOS_AKA_RK3588)
    if (!aka_rk3588_run) {
        return -ENOSYS;
    }
#endif
    /* The controller owns timers and hardware; start it once per boot. */
    if (!atomic_cas(&state, 0, 1)) {
        return -EALREADY;
    }
    k_thread_create(&aka_thread, aka_stack, K_THREAD_STACK_SIZEOF(aka_stack),
        worker, nullptr, nullptr, nullptr, 5, 0, K_NO_WAIT);
    return 0;
}

const char *aka_adapter_state()
{
    const atomic_val_t value = atomic_get(&state);
    if (value == 0) return "idle";
    if (value == 1) return "running";
    return atomic_get(&result) == 0 ? "passed" : "failed";
}

int aka_adapter_result()
{
    return static_cast<int>(atomic_get(&result));
}
