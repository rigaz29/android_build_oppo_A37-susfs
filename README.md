# susfs for OPPO A37 (msm8916, Linux 3.10)

A staged port of [susfs](https://gitlab.com/simonpunk/susfs4ksu) v2.3.0 to the
OPPO A37 / A37f kernel (3.10.108, arm64), running LineageOS 20 with
[KernelSU backslashxx](https://github.com/backslashxx/KernelSU) v3.3.0-48.

Upstream susfs targets GKI 5.10+, and its non-GKI branches stop at 4.9. The
closest port is the 4.4 patch in
[JackA1ltman/NonGKI_Kernel_Build_2nd](https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/tree/mainline/Patches/Patch).
This repo carries that code forward to 3.10, one feature group at a time, and
wires it into a KernelSU fork that has no susfs support of its own.

The kernel code lives in
[kernel_oppo_msm8939](https://github.com/rigaz29/kernel_oppo_msm8939), branch
`wip/susfs`. This repo holds the patch series, notes and status.

## Status

| Stage | Features | Status |
|---|---|---|
| 0 | core, `set_uname`, `set_cmdline_or_bootconfig`, log, `show` | done, verified on device |
| 1 | `sus_mount` (hide mounts in /proc/mounts, mountinfo) | todo |
| 2 | `sus_kstat`, `sus_map` | todo |
| 3 | `sus_path` (hide files/dirs), sdcard monitor | todo |

Each stage gets its own Kconfig option. Only options that are already ported
are defined, so an unported feature cannot be enabled and fail at link time.

## Base

- Kernel: `kernel_oppo_msm8939` `wip/kernelsu` @ `00a7a53`
  (KernelSU backslashxx v3.3.0-48, 32649, syscall-table hooks)
- susfs: v2.3.0, kernel side from the JackA1ltman 4.4 patch
- Userspace: `ksu_susfs` from susfs4ksu `gki-android12-5.10` @ `f3b5aec`
  (`ksu_module_susfs/tools/ksu_susfs_arm64`)

## Applying

On top of `wip/kernelsu`:

```sh
git checkout -b wip/susfs 00a7a53
git am patches/stage0/*.patch
```

`lineageos_a37f_defconfig` is updated by the series:

```
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
```

Install the tool as `/data/adb/ksu/bin/ksu_susfs` (0755). Then, as root:

```sh
ksu_susfs show version            # v2.3.0
ksu_susfs show variant            # NON-GKI
ksu_susfs show enabled_features
```

## How commands reach the kernel

`ksu_susfs` calls `reboot(0xDEADBEEF, 0xFAFAFAFA, cmd, &info)`. The KernelSU
fork already hooks `reboot` through the syscall table and passes it to
`ksu_handle_sys_reboot()`; stage 0 adds a `SUSFS_MAGIC` branch there for root
callers, ahead of the toolkit path. The original `sys_reboot` still runs
afterwards and returns `-EINVAL` for the unknown magic, which is harmless:
results come back through `info.err`.

## 3.10 adaptations

- `linux/bits.h` is 4.19+; `BIT()` comes from `linux/bitops.h`.
- `strscpy()` is 4.3+; mapped to `strlcpy()`. No caller uses the return value.
- `kuid_t` is a plain typedef here, so `current_uid().val` does not build.
  KernelSU's `kernel_compat.h` also overrides `current_uid()`, and
  `susfs_def.h` is included from both sides. Reading
  `__kuid_val(current_cred()->uid)` works in both.
- 3.10's `static_key_enabled()` takes the bare `struct static_key`; the
  backported `static_key_{true,false}` are wrapped.
- `newuname` copies `utsname()` straight to userspace; the spoof needs a local
  copy, added under `CONFIG_KSU_SUSFS_SPOOF_UNAME` only.
- The `/sdcard` fsnotify monitor and the extra works only serve `sus_path` and
  depend on KernelSU internals this fork lacks (`setup_selinux`, `ksu_cred`).
  They build only with `CONFIG_KSU_SUSFS_SUS_PATH`, which lands in stage 3.
- `supercall.c` has no includes of its own; it is `#include`d by `ksu.c`.

## Known issue: do not spoof uname to 4.4 or later

NetworkStack's `TcpSocketTracker` enables netlink TCP polling only when
`Os.uname().release` is 4.4 or later, and it re-reads uname on every check.
At boot the real 3.10 disables it, so the request message is never built.
After `set_uname '4.9.337-...'` the check flips, it sends that missing
message, hits a `NullPointerException`, and takes `system_server` down
(soft restart, looks like a reboot). Android gates other features on uname
too.

Keep the version and only disguise the suffix:

```sh
ksu_susfs set_uname '3.10.108-g1a2b3c4d' '#1 SMP PREEMPT'
```

## Credits

- simonpunk, [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu)
- JackA1ltman, [NonGKI_Kernel_Build_2nd](https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd)
- backslashxx, [KernelSU](https://github.com/backslashxx/KernelSU)

susfs4ksu is published under GPL-3.0 upstream. The patches here are derived
from it and follow the upstream licensing.
