#include "axivc_tests.h"
#include "aka_adapter.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <zephyr/sys/atomic.h>

#include <zephyr/kernel.h>
#include <zephyr/shell/shell.h>

namespace {

enum class job_state : unsigned char { idle, running, passed, failed, canceled };
job_state state = job_state::idle;
ivc_test active = ivc_test::latency;
int result = 0;
int active_timeout_ms = 30000;
atomic_t stop_requested = ATOMIC_INIT(0);
K_MUTEX_DEFINE(state_lock);
K_SEM_DEFINE(job_sem, 0, 1);
K_SEM_DEFINE(done_sem, 0, 1);
K_THREAD_STACK_DEFINE(job_stack, 16384);
k_thread job_thread;

const char *state_name(job_state value)
{
	switch (value) {
	case job_state::idle: return "idle";
	case job_state::running: return "running";
	case job_state::passed: return "passed";
	case job_state::failed: return "failed";
	case job_state::canceled: return "canceled";
	}
	return "unknown";
}

void worker(void *, void *, void *)
{
	while (true) {
		k_sem_take(&job_sem, K_FOREVER);
		k_mutex_lock(&state_lock, K_FOREVER);
		ivc_test test = active;
		int timeout_ms = active_timeout_ms;
		state = job_state::running;
		k_mutex_unlock(&state_lock);
		int rc = run_ivc_test(test, timeout_ms);
		k_mutex_lock(&state_lock, K_FOREVER);
		result = rc;
		/* Keep running until the waiting command consumes completion, so
		 * another shell cannot overwrite this job or steal its wakeup. */
		k_mutex_unlock(&state_lock);
		k_sem_give(&done_sem);
	}
}

int start_test(const struct shell *shell, ivc_test test, size_t argc, char **argv)
{
	int timeout_ms = 30000;
	if (argc == 2) {
		char *end;
		errno = 0;
		long parsed = strtol(argv[1], &end, 10);
		if (errno || !*argv[1] || *end || parsed < 1 || parsed > 600000) {
			shell_error(shell, "timeout_ms must be between 1 and 600000");
			return -EINVAL;
		}
		timeout_ms = static_cast<int>(parsed);
	}
	k_mutex_lock(&state_lock, K_FOREVER);
	if (state == job_state::running) {
		k_mutex_unlock(&state_lock);
		shell_error(shell, "test already running");
		return -EBUSY;
	}
	atomic_set(&stop_requested, 0);
	active = test;
	active_timeout_ms = timeout_ms;
	result = 0;
	state = job_state::running;
	k_mutex_unlock(&state_lock);
	const int64_t started_ms = k_uptime_get();
	/* The workload uses one deadline and unwinds normally on timeout.
	 * Wait for its cleanup instead of aborting a thread with live mappings. */
	shell_print(shell, "TEST_RUNNING timeout_ms=%d", timeout_ms);
	shell_print(shell, "Press Ctrl+C to stop.");
	k_sem_give(&job_sem);
	while (k_sem_take(&done_sem, K_NO_WAIT) != 0) {
		uint8_t input[32];
		int read = shell_readline(shell, input, sizeof(input), K_MSEC(20));
		if (read == -ECANCELED) {
			if (atomic_cas(&stop_requested, 0, 1))
				shell_print(shell, "stop requested");
		} else if (read > 0 && !strcmp(reinterpret_cast<char *>(input), "status")) {
			shell_print(shell, "state=running");
		}
	}
	k_mutex_lock(&state_lock, K_FOREVER);
	const int rc = result;
	state = rc == -ECANCELED ? job_state::canceled :
		rc == 0 ? job_state::passed : job_state::failed;
	const job_state finished = state;
	k_mutex_unlock(&state_lock);
	shell_print(shell, "elapsed_ms=%lld timeout_ms=%d",
		static_cast<long long>(k_uptime_get() - started_ms), timeout_ms);
	shell_print(shell, "state=%s result=%d", state_name(finished), rc);
	return rc;
}

int cmd_status(const struct shell *shell, size_t, char **)
{
	k_mutex_lock(&state_lock, K_FOREVER);
	const job_state current = state;
	const int rc = result;
	k_mutex_unlock(&state_lock);
	shell_print(shell, "state=%s result=%d", state_name(current), rc);
	return 0;
}

int cmd_aka_run(const struct shell *shell, size_t, char **)
{
	int rc = aka_adapter_run();
	shell_print(shell, "aka_run=%d", rc);
	return rc;
}

#define TEST_CMD(name, value) \
int cmd_##name(const struct shell *shell, size_t argc, char **argv) { return start_test(shell, ivc_test::value, argc, argv); }
TEST_CMD(latency, latency)
TEST_CMD(irq_latency, irq_latency)
TEST_CMD(publisher, publisher)
TEST_CMD(subscriber, subscriber)
TEST_CMD(pingpong, pingpong)
TEST_CMD(ivc_demo, demo)
TEST_CMD(ivc_benchmark, benchmark)

SHELL_STATIC_SUBCMD_SET_CREATE(ivc_commands,
	SHELL_CMD_ARG(latency, NULL, "run latency workload [timeout_ms]", cmd_latency, 1, 1),
	SHELL_CMD_ARG(publisher, NULL, "run Linux publisher peer test [timeout_ms]", cmd_publisher, 1, 1),
	SHELL_CMD_ARG(subscriber, NULL, "run Linux subscriber peer test [timeout_ms]", cmd_subscriber, 1, 1),
	SHELL_CMD_ARG(pingpong, NULL, "run ping-pong test [timeout_ms]", cmd_pingpong, 1, 1),
	SHELL_CMD_ARG(ivc_demo, NULL, "run StarryOS IVC demo [timeout_ms]", cmd_ivc_demo, 1, 1),
	SHELL_CMD_ARG(ivc_benchmark, NULL, "run StarryOS IVC benchmark [timeout_ms]", cmd_ivc_benchmark, 1, 1),
	SHELL_SUBCMD_SET_END
);
SHELL_CMD_REGISTER(ivc, &ivc_commands, "Orange Pi AXIVC workloads", NULL);
SHELL_STATIC_SUBCMD_SET_CREATE(irq_commands,
	SHELL_CMD_ARG(latency, NULL, "measure ARM timer IRQ interval deviation [timeout_ms]", cmd_irq_latency, 1, 1),
	SHELL_SUBCMD_SET_END
);
SHELL_CMD_REGISTER(irq, &irq_commands, "Interrupt measurements", NULL);
int cmd_aka_status(const struct shell *shell, size_t, char **)
{
    shell_print(shell, "aka_state=%s result=%d", aka_adapter_state(),
        aka_adapter_result());
    return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(aka_commands,
	SHELL_CMD_ARG(run, NULL, "start the AKA controller", cmd_aka_run, 1, 0),
	SHELL_CMD_ARG(status, NULL, "show AKA controller state", cmd_aka_status, 1, 0),
	SHELL_SUBCMD_SET_END
);
SHELL_CMD_REGISTER(aka, &aka_commands, "AKA RK3588 library workloads", NULL);
SHELL_CMD_REGISTER(status, NULL, "show workload state", cmd_status);

} // namespace

bool workload_stop_requested()
{
	return atomic_get(&stop_requested) != 0;
}

extern "C" int main(void)
{
	k_thread_create(&job_thread, job_stack, K_THREAD_STACK_SIZEOF(job_stack),
		worker, nullptr, nullptr, nullptr, 5, 0, K_NO_WAIT);
	printk("ORANGEPI_ZEPHYR_SHELL_READY\n");
	return 0;
}
