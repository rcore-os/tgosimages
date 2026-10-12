/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Minimal Zephyr guest application for the Orange Pi 5 Plus Linux + StarryOS +
 * Zephyr three-guest functional test image (`zephyr-triple-guest-functional`).
 *
 * It only brings up the serial shell so the board checks can use Zephyr's own
 * `kernel version`, `kernel thread list` and `device list` commands; it adds no
 * functional check of its own.
 */
#include <zephyr/kernel.h>

int main(void)
{
	printk("Zephyr triple-guest functional shell ready.\n");

	/* Zephyr keeps running after main() returns, so the shell stays usable. */
	return 0;
}
