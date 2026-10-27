# Orange Pi prebuilt guest payloads implementation plan

> Execute the approved design in this session. Use focused review and behavior tests before completion.

**Goal:** A complete Orange Pi image contains the normal report workloads without workstation builds during testing; the default host still creates no guests.

**Architecture:** Extend the existing AxVisor package node using its single TGOSKits checkout. Build the ArceOS Shell and robot-flow StarryOS into isolated object directories, compile the existing YOLOv8 CMake project for AArch64 GNU/Linux, and install runtime configurations with board paths. Generate 64 network configurations from the upstream generator and reuse `/guest/arceos/orangepi-5-plus`. Extend the existing AKA package with `tennis` and single-client launch scripts, sharing models, libraries and calibration with the perception package. Copy the complete AKA package into outer `/guest/aka` and retain `/opt/aka` in nested guest disks. Keep task-switch on its existing dedicated kernel-test entry; do not present ordinary VM startup as an equivalent FIFO benchmark.

**Constraints:** Preserve existing complete-image atomic publication, workspace isolation and user-supplied checkouts. Keep Linux startup and default AxVisor boot unchanged. Do not touch the untracked DOCX reports. Config sources and transformed runtime paths must be recorded in the package manifest; the task-switch configuration remains explicitly source dependent. Do not automatically execute robot programs or guest VMs. Complete Linux runtime packages must validate AArch64 binaries and bundled dependencies; build failures must retain previously published output.

**Files and tasks:**

- [x] Extend `scripts/tests/platform/orangepi-axvisor.py` and add focused payload tests proving deployed config paths, 64 peer identities, shared network BIN, source immutability and package publication failure. Observe failure before implementation.
- [x] Add `scripts/lib/axvisor-payloads.sh` for isolated builds and `scripts/lib/python/axvisor-payloads.py` for runtime configuration staging/provenance. Integrate into `scripts/os/axvisor.sh` inside the existing package staging transaction. Reuse upstream guest configs, CMake definitions and network generator; reject missing inputs.
- [x] Migrate the existing platform ArceOS network build input to `board-ballpick-robot/virtio-net-peer/configs/arceos-guest-build.toml`; the former board-orangepi-5-plus path has been removed upstream. Check this against the actual TGOSKits tree.
- [x] Extend `scripts/tests/apps/aka-package.py` for complete robot runtime validation. Extend `scripts/apps/orangepi-aka-perception.sh` to build/install both existing CMake targets and stage single-client scripts with relative links to common assets. Validate the full generated package and retain compatibility for explicitly supplied perception-only packages in dual-only entry points.
- [x] Extend `scripts/platform/orangepi-5-plus.sh` final staging and its compose-cache inputs in `scripts/lib/python/platform-graph.py` to include `/guest/aka`; require the single runtime for a default complete image, and keep `ORANGEPI_WITH_AKA=0` behavior. Verify with the existing real GPT/FAT/ext4 composition fixture, including atomic failure.
- [x] Update English/Chinese README and application build documentation with runtime paths, commands, calibration input and dedicated task-switch boundary. Do not add the chat-only missing-artifact inventory to the Word report.
- [x] Run focused Python/shell packaging, graph, rootfs and boot regressions; compile the real YOLOv8 CMake package with the available AArch64 compiler. If toolchains or full source builds cannot be completed, report their scope without claiming board validation. Obtain code review and address substantive findings.

**Verification commands:** `python3 scripts/tests/platform/orangepi-axvisor.py`; the new payload test; `python3 scripts/tests/apps/aka-package.py`; `bash scripts/tests/apps/orangepi-aka-rootfs.sh`; `python3 scripts/tests/rootfs/rootfs-graph.py`; `bash scripts/tests/platform/orangepi-rootfs-flow.sh`; `bash scripts/tests/platform/orangepi-axvisor-boot.sh`; shell syntax checks for modified scripts. Additional tests only for uncovered changes or failures.

## Execution results

Implemented and reviewed. Real builds produced the ArceOS Shell, UVC robot-flow StarryOS, YOLOv8 image runtime and both AKA executables. The package staging orchestration was exercised with the actual TGOSKits checkout and produced all 64 generated peer configurations. Target-loader checks resolved single-client indirect libraries without executing robot applications. Explicit target SDKs remain read-only, and ABI validation reads the selected target libraries rather than assuming the build host matches the deployed OS.

The Python checks (40 cases), rootfs flow (13 checks), disk regression (35 checks), boot/default-selection checks and legacy dual-only rootfs composition pass. A real ext4 assembled from the target SDK and AKA runtime also passes architecture, dependency and symbol-version validation. Review findings concerning root PARTLABEL selection, private generator output, target-absolute SDK links and cache inputs were fixed and rechecked. Vendor Linux/full `all` image production and physical board startup were not run in this task.
