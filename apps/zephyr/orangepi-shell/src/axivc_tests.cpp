#include "axivc_tests.h"

#include <axivc/axivc.h>
#include <axivc/benchmark_config.h>
#include <axivc/demo_config.h>

#include <errno.h>
#include <string.h>

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>

extern int run_ivc_benchmark(int64_t deadline);
extern int run_irq_latency(int64_t deadline);

namespace {

int publisher(int64_t deadline)
{
	axivc_channel_t *channel = axivc_publish(AXIVC_DEMO_CHANNEL_KEY,
		AXIVC_DEMO_CHANNEL_SIZE);
	if (!channel) {
		printk("ORANGEPI_ZEPHYR_PUBLISHER_FAILED open\n");
		return -ENODEV;
	}
	int ret = 0;
	for (int seq = 1; seq <= AXIVC_DEMO_MESSAGE_COUNT; ++seq) {
		char message[AXIVC_SLOT_PAYLOAD_SIZE];
		char ack[AXIVC_SLOT_PAYLOAD_SIZE + 1];
		size_t len = 0;
		snprintk(message, sizeof(message), "hello-%d", seq);
		ret = ivc_send_before(channel, message, strlen(message), deadline);
		if (ret < 0) break;
		ret = ivc_recv_before(channel, ack, AXIVC_SLOT_PAYLOAD_SIZE, &len, deadline);
		if (ret < 0) break;
		ack[len] = '\0';
		printk("ivc publisher seq=%d ack=%s\n", seq, ack);
	}
	axivc_close(channel);
	printk("ORANGEPI_ZEPHYR_PUBLISHER_%s\n", ret == -ECANCELED ? "CANCELED" : ret < 0 ? "FAILED" : "PASSED");
	return ret;
}

int subscriber(int64_t deadline)
{
	axivc_channel_t *channel = ivc_subscribe_before(AXIVC_DEMO_PUBLISHER_VM_ID,
		AXIVC_DEMO_CHANNEL_KEY, deadline);
	if (!channel) {
		const int ret = workload_abort_result(deadline);
		printk("ORANGEPI_ZEPHYR_SUBSCRIBER_%s open\n",
			ret == -ECANCELED ? "CANCELED" : "FAILED");
		return ret;
	}
	int ret = 0;
	for (int seq = 1; seq <= AXIVC_DEMO_MESSAGE_COUNT; ++seq) {
		char message[AXIVC_SLOT_PAYLOAD_SIZE + 1];
		size_t len = 0;
		ret = ivc_recv_before(channel, message, AXIVC_SLOT_PAYLOAD_SIZE, &len, deadline);
		if (ret < 0) break;
		message[len] = '\0';
		printk("ivc subscriber seq=%d msg=%s\n", seq, message);
		char expected[AXIVC_SLOT_PAYLOAD_SIZE];
		char reply[AXIVC_SLOT_PAYLOAD_SIZE];
		snprintk(expected, sizeof(expected), "linux-to-zephyr-%d\n", seq);
		if (len != strlen(expected) || memcmp(message, expected, len)) {
			ret = -EPROTO;
			break;
		}
		snprintk(reply, sizeof(reply), "zephyr-to-linux-%d\n", seq);
		ret = ivc_send_before(channel, reply, strlen(reply), deadline);
		if (ret < 0) break;
	}
	/* Keep the subscriber mapping alive until the peer has finished its
	 * teardown. The next test run resets the VM/channel state. */
	printk("ORANGEPI_ZEPHYR_SUBSCRIBER_%s\n", ret == -ECANCELED ? "CANCELED" : ret < 0 ? "FAILED" : "PASSED");
	return ret;
}

int pingpong(int64_t deadline)
{
	axivc_channel_t *channel = axivc_publish(AXIVC_DEMO_CHANNEL_KEY,
		AXIVC_DEMO_CHANNEL_SIZE);
	if (!channel) {
		printk("ORANGEPI_ZEPHYR_PINGPONG_FAILED open\n");
		return -ENODEV;
	}
	int ret = 0;
	for (int seq = 1; seq <= AXIVC_DEMO_MESSAGE_COUNT; ++seq) {
		char ping[AXIVC_SLOT_PAYLOAD_SIZE];
		char pong[AXIVC_SLOT_PAYLOAD_SIZE + 1];
		size_t len = 0;
		snprintk(ping, sizeof(ping), "ping-%d", seq);
		ret = ivc_send_before(channel, ping, strlen(ping), deadline);
		if (ret < 0) break;
		ret = ivc_recv_before(channel, pong, AXIVC_SLOT_PAYLOAD_SIZE, &len, deadline);
		if (ret < 0) break;
		pong[len] = '\0';
		printk("ivc pingpong seq=%d pong=%s\n", seq, pong);
	}
	axivc_close(channel);
	printk("ORANGEPI_ZEPHYR_PINGPONG_%s\n", ret == -ECANCELED ? "CANCELED" : ret < 0 ? "FAILED" : "PASSED");
	return ret;
}

int starry_demo(int64_t deadline)
{
	axivc_channel_t *channel = axivc_publish(AXIVC_DEMO_CHANNEL_KEY,
		AXIVC_DEMO_CHANNEL_SIZE);
	if (!channel) {
		printk("ORANGEPI_ZEPHYR_IVC_DEMO_FAILED open\n");
		return -ENODEV;
	}
	printk("ORANGEPI_ZEPHYR_IVC_DEMO_WAITING\n");
	int ret = 0;
	/* Match the existing Starry demo's batch exchange. Each reply is still
	 * checked against its complete message and sequence number. */
	for (int seq = 1; seq <= AXIVC_DEMO_MESSAGE_COUNT; ++seq) {
		char message[AXIVC_SLOT_PAYLOAD_SIZE];
		snprintk(message, sizeof(message), "zephyr-to-starry-%d\n", seq);
		ret = ivc_send_before(channel, message, strlen(message), deadline);
		if (ret < 0) break;
		printk("ivc demo sent %d/%d\n", seq, AXIVC_DEMO_MESSAGE_COUNT);
	}
	for (int seq = 1; !ret && seq <= AXIVC_DEMO_MESSAGE_COUNT; ++seq) {
		char expected[AXIVC_SLOT_PAYLOAD_SIZE];
		char reply[AXIVC_SLOT_PAYLOAD_SIZE + 1];
		size_t len = 0;
		ret = ivc_recv_before(channel, reply, AXIVC_SLOT_PAYLOAD_SIZE, &len, deadline);
		if (ret < 0) break;
		snprintk(expected, sizeof(expected), "starry-to-zephyr-%d\n", seq);
		if (len != strlen(expected) || memcmp(reply, expected, len)) {
			ret = -EPROTO;
			break;
		}
		reply[len] = '\0';
		printk("starry reply %d/%d: %s\n", seq, AXIVC_DEMO_MESSAGE_COUNT, reply);
	}
	int close_ret = axivc_close(channel);
	if (!ret) ret = close_ret;
	if (ret < 0) printk("ORANGEPI_ZEPHYR_IVC_DEMO_RET=%d\n", ret);
	printk("ORANGEPI_ZEPHYR_IVC_DEMO_%s\n", ret == -ECANCELED ? "CANCELED" : ret < 0 ? "FAILED" : "PASSED");
	return ret;
}

int benchmark(int64_t deadline)
{
	int ret = run_ivc_benchmark(deadline);
	printk("ORANGEPI_ZEPHYR_IVC_BENCHMARK_%s\n", ret == -ECANCELED ? "CANCELED" : ret < 0 ? "FAILED" : "PASSED");
	return ret;
}

int latency(int64_t deadline)
{
	uint64_t start = k_cycle_get_64();
	for (unsigned int i = 0; i < 1000; ++i) {
		if (int abort = workload_abort_result(deadline)) return abort;
		k_yield();
	}
	uint64_t elapsed = k_cycle_get_64() - start;
	printk("latency yield_cycles=%llu\n", (unsigned long long)elapsed);
	printk("ORANGEPI_ZEPHYR_LATENCY_PASSED\n");
	return 0;
}

} // namespace

int run_ivc_test(ivc_test test, int timeout_ms)
{
	const int64_t deadline = k_uptime_get() + timeout_ms;
	switch (test) {
	case ivc_test::latency: return latency(deadline);
	case ivc_test::irq_latency: return run_irq_latency(deadline);
	case ivc_test::publisher: return publisher(deadline);
	case ivc_test::subscriber: return subscriber(deadline);
	case ivc_test::pingpong: return pingpong(deadline);
	case ivc_test::demo: return starry_demo(deadline);
	case ivc_test::benchmark: return benchmark(deadline);
	}
	return -EINVAL;
}
