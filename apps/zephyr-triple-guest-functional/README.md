# zephyr-triple-guest-functional

Zephyr client application for the Orange Pi 5 Plus **Linux + StarryOS + Zephyr**
three-guest functional test image (`zephyr-triple-guest-functional`).

The application only brings up Zephyr's serial shell. It exists so the board
checks can drive Zephyr's own inspection commands on the third client:

- `kernel version`
- `kernel thread list` (the `shell_uart` and `idle` threads must be present)
- `device list` (`interrupt-controller@fe600000`, `serial@feb50000`)

It keeps the serial prompt `zephyr:~$ `, the kernel shell, the device shell and
the thread monitor enabled; `src/main.c` adds no functional check of its own.
`boards/orangepi_5_plus_rk3588.overlay` pins `sram0` to the 128 MiB window the
Zephyr VM configuration maps.

Build it through the reproducible Orange Pi profile, which reuses the existing
`scripts/os/zephyr.sh orangepi-5-plus` base (fixed Zephyr ref, patches, SDK,
Python environment, `orangepi_5_plus_rk3588` board and DTB handling):

```bash
# from the tgosimages repository root
./scripts/apps/zephyr-triple-guest-functional.sh
```

Artifacts land in the standard Orange Pi Zephyr image directory as
`IMAGES/orangepi/zephyr/zephyr-triple-guest-functional{,.elf,.dtb}`. See
`scripts/apps/README.md` for the full entry point and options.
