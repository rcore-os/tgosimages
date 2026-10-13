#include "axivc_tests.h"

#include <axivc/axivc.h>
#include <axivc/benchmark_config.h>
#include <axivc/zephyr_platform.h>

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <zephyr/kernel.h>

static_assert(
	sizeof(struct axivc_bench_message) == AXIVC_SLOT_PAYLOAD_SIZE,
	"AXIVC benchmark message must fit in one slot");

static uint8_t source_data[AXIVC_BENCH_MAX_DATA_SIZE];

static uint64_t now_us(void)
{
	return k_cyc_to_us_floor64(k_cycle_get_64());
}

static uint32_t load_u32(volatile uint8_t *base, uint32_t offset)
{
	return __atomic_load_n(
		(volatile uint32_t *)(base + offset), __ATOMIC_ACQUIRE);
}

static void store_u32(volatile uint8_t *base, uint32_t offset, uint32_t value)
{
	__atomic_store_n((volatile uint32_t *)(base + offset), value, __ATOMIC_RELEASE);
}

static int send_message(
	axivc_channel_t *channel, const struct axivc_bench_message *msg, int64_t deadline)
{
	return ivc_send_before(channel, msg, sizeof(*msg), deadline);
}

static int recv_ack(
	axivc_channel_t *channel, const struct axivc_bench_message *data, int64_t deadline)
{
	struct axivc_bench_message ack = {};
	size_t len = 0;
	int ret = ivc_recv_before(
		channel, &ack, sizeof(ack), &len, deadline);

	if (ret < 0)
		return ret;
	if (len != sizeof(ack) || ack.magic != AXIVC_BENCH_MAGIC ||
	    ack.type != AXIVC_BENCH_TYPE_ACK || ack.case_index != data->case_index ||
	    ack.iteration != data->iteration || ack.len != data->len ||
	    ack.value != data->value)
		return -EPROTO;
	return 0;
}

static int send_payload(
	axivc_channel_t *channel, volatile uint8_t *window, uint32_t case_index,
	uint32_t iteration, uint32_t size, uint64_t *bandwidth_x100_sum,
	uint64_t *copy_bandwidth_x100_sum, uint64_t *flush_bandwidth_x100_sum,
	int64_t deadline)
{
	uint8_t *payload = (uint8_t *)window + AXIVC_BENCH_SHMEM_PAYLOAD_OFFSET;
	struct axivc_bench_message msg = {};
	uint64_t start;
	uint64_t flush_start;
	uint64_t copy_elapsed_us;
	uint64_t flush_elapsed_us;
	uint64_t elapsed_us;

	axivc_cache_invalidate(
		channel, (const void *)window, AXIVC_BENCH_SHMEM_PAYLOAD_OFFSET);
	while (load_u32(window, AXIVC_BENCH_SHMEM_FLAG_OFFSET) !=
	       AXIVC_BENCH_SHMEM_INVALID)
	{
		if (int abort = workload_abort_result(deadline)) return abort;
		k_sleep(K_MSEC(1));
		axivc_cache_invalidate(
			channel, (const void *)window,
			AXIVC_BENCH_SHMEM_PAYLOAD_OFFSET);
	}

	start = now_us();
	memcpy(payload, source_data, size);
	store_u32(window, AXIVC_BENCH_SHMEM_LEN_OFFSET, size);
	store_u32(window, AXIVC_BENCH_SHMEM_FLAG_OFFSET, AXIVC_BENCH_SHMEM_VALID);
	flush_start = now_us();
	axivc_zephyr_platform_flush(
		(const void *)window, AXIVC_BENCH_SHMEM_PAYLOAD_OFFSET + size);
	elapsed_us = now_us() - start;
	copy_elapsed_us = flush_start - start;
	flush_elapsed_us = elapsed_us - copy_elapsed_us;
	*bandwidth_x100_sum += axivc_bench_bandwidth_centi_mib(elapsed_us, size);
	*copy_bandwidth_x100_sum +=
		axivc_bench_bandwidth_centi_mib(copy_elapsed_us, size);
	*flush_bandwidth_x100_sum +=
		axivc_bench_bandwidth_centi_mib(flush_elapsed_us, size);

	msg.magic = AXIVC_BENCH_MAGIC;
	msg.type = AXIVC_BENCH_TYPE_DATA;
	msg.case_index = case_index;
	msg.iteration = iteration;
	msg.offset = 0;
	msg.len = size;
	msg.total_size = size;
	msg.value = axivc_bench_checksum(source_data, size);

	int ret = send_message(channel, &msg, deadline);
	if (ret < 0)
		return ret;
	return recv_ack(channel, &msg, deadline);
}

static int send_stats(
	axivc_channel_t *channel, uint32_t case_index, uint32_t size,
	uint64_t average_bandwidth_x100, uint64_t average_copy_bandwidth_x100,
	uint64_t average_flush_bandwidth_x100, int64_t deadline)
{
	struct axivc_bench_message msg = {};

	msg.magic = AXIVC_BENCH_MAGIC;
	msg.type = AXIVC_BENCH_TYPE_STATS;
	msg.case_index = case_index;
	msg.offset = average_copy_bandwidth_x100;
	msg.reserved = (uint32_t)average_flush_bandwidth_x100;
	msg.total_size = size;
	msg.value = average_bandwidth_x100;
	return send_message(channel, &msg, deadline);
}

static int send_done(axivc_channel_t *channel, int64_t deadline)
{
	struct axivc_bench_message msg = {};

	msg.magic = AXIVC_BENCH_MAGIC;
	msg.type = AXIVC_BENCH_TYPE_DONE;
	return send_message(channel, &msg, deadline);
}

int run_ivc_benchmark(int64_t deadline)
{
	axivc_channel_t *channel =
		axivc_publish(AXIVC_BENCH_CHANNEL_KEY, AXIVC_BENCH_CHANNEL_SIZE);
	size_t region_size = 0;
	uint8_t *region;
	volatile uint8_t *window;
	uint32_t transfers = 0;
	size_t window_size;
	int ret = 0;

	if (!channel)
	{
		printk("AXIVC Zephyr-Starry benchmark publish failed\n");
		return -ENODEV;
	}

	region = (uint8_t *)axivc_shared_region(channel, &region_size);
	if (!region || region_size < AXIVC_BENCH_CHANNEL_SIZE)
	{
		printk("AXIVC Zephyr-Starry benchmark shared region unavailable\n");
		ret = -EINVAL;
		goto out;
	}

	window = region + sizeof(struct axivc_region);
	window_size = region_size - sizeof(struct axivc_region);
	store_u32(window, AXIVC_BENCH_SHMEM_FLAG_OFFSET, AXIVC_BENCH_SHMEM_INVALID);
	axivc_cache_flush(
		channel, (const void *)window, AXIVC_BENCH_SHMEM_PAYLOAD_OFFSET);
	axivc_bench_fill(source_data, sizeof(source_data));

	printk(
		"[test_output] IVC random block bench created, testTime = %u, "
		"windowSize = %u\n",
		AXIVC_BENCH_ITERATIONS, (unsigned int)window_size);

	for (uint32_t case_index = 0; case_index < AXIVC_BENCH_SIZE_COUNT;
	     case_index++)
	{
		uint32_t size = axivc_bench_size_at(case_index);
		uint64_t send_bandwidth_x100_sum = 0;
		uint64_t copy_bandwidth_x100_sum = 0;
		uint64_t flush_bandwidth_x100_sum = 0;

		for (uint32_t iteration = 0; iteration < AXIVC_BENCH_ITERATIONS;
		     iteration++)
		{
			ret = send_payload(
				channel, window, case_index, iteration, size,
				&send_bandwidth_x100_sum, &copy_bandwidth_x100_sum,
				&flush_bandwidth_x100_sum, deadline);
			if (ret < 0)
				goto out;
			transfers++;
		}
		uint64_t average_bandwidth_x100 =
			send_bandwidth_x100_sum / AXIVC_BENCH_ITERATIONS;
		uint64_t average_copy_bandwidth_x100 =
			copy_bandwidth_x100_sum / AXIVC_BENCH_ITERATIONS;
		uint64_t average_flush_bandwidth_x100 =
			flush_bandwidth_x100_sum / AXIVC_BENCH_ITERATIONS;
		printk("ivc bench publish case=%u datasize=%u\n", case_index, size);
		ret = send_stats(
			channel, case_index, size, average_bandwidth_x100,
			average_copy_bandwidth_x100, average_flush_bandwidth_x100, deadline);
		if (ret < 0)
			goto out;
	}

	ret = send_done(channel, deadline);
	(void)transfers;

out:
	if (ret < 0)
		printk("AXIVC Zephyr-Starry benchmark failed: %s\n", axivc_strerror(ret));
	axivc_close(channel);
	return ret;
}
