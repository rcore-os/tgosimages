#pragma once

#include <axivc/axivc.h>
#include <errno.h>
#include <zephyr/kernel.h>

inline int ivc_remaining_ms(int64_t deadline)
{
	const int64_t left = deadline - k_uptime_get();
	return left > 0 ? static_cast<int>(left) : 0;
}

bool workload_stop_requested();

inline int workload_abort_result(int64_t deadline)
{
	if (workload_stop_requested()) return -ECANCELED;
	return ivc_remaining_ms(deadline) ? 0 : -ETIMEDOUT;
}

inline int ivc_send_before(axivc_channel_t *channel, const void *bytes,
			   size_t length, int64_t deadline)
{
	for (;;) {
		int abort = workload_abort_result(deadline);
		if (abort) return abort;
		const int remaining = ivc_remaining_ms(deadline);
		int ret = axivc_send(channel, bytes, length, remaining < 50 ? remaining : 50);
		if (ret != -ETIMEDOUT) return ret;
	}
}

inline int ivc_recv_before(axivc_channel_t *channel, void *bytes, size_t capacity,
			   size_t *length, int64_t deadline)
{
	for (;;) {
		int abort = workload_abort_result(deadline);
		if (abort) return abort;
		const int remaining = ivc_remaining_ms(deadline);
		int ret = axivc_recv(channel, bytes, capacity, length, remaining < 50 ? remaining : 50);
		if (ret != -ETIMEDOUT) return ret;
	}
}

inline axivc_channel_t *ivc_subscribe_before(uint64_t publisher, uint64_t key,
					  int64_t deadline)
{
	while (!workload_abort_result(deadline)) {
		const int remaining = ivc_remaining_ms(deadline);
		axivc_channel_t *channel = axivc_subscribe(publisher, key,
			remaining < 50 ? remaining : 50);
		if (channel) return channel;
		k_sleep(K_MSEC(1));
	}
	return nullptr;
}

enum class ivc_test : unsigned char {
	latency,
	irq_latency,
	publisher,
	subscriber,
	pingpong,
	demo,
	benchmark,
};

int run_ivc_test(ivc_test test, int timeout_ms);
