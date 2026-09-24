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
| 1 | `sus_mount` (hide mounts in /proc/mounts, mountinfo) | done, verified on device |
| 2 | `sus_kstat`, `sus_map` | done, verified on device |
| 3 | `sus_path` (hide files/dirs), sdcard monitor | done, verified on device (hiding checked from an app process, needs stage 4 0004) |
| 4 | `open_redirect`, symbol hiding, avc log spoofing | done, verified on device |

Each stage gets its own Kconfig option. Only options that are already ported
are defined, so an unported feature cannot be enabled and fail at link time.

## Base

- Kernel: `kernel_oppo_msm8939` `wip/kernelsu` @ `34007f3`
  (KernelSU backslashxx v3.3.0-48, 32649, syscall-table hooks, plus a
  fix marking modules mounted on post-fs-data: backslashxx ksud never
  sends EVENT_MODULE_MOUNTED on its own, which left `ksu_module_mounted`
  false and kernel_umount dead. That is a fork bug, not a susfs one, so
  it lives in the base branch, outside the susfs patch series.)
- susfs: v2.3.0, kernel side from the JackA1ltman 4.4 patch
- Userspace: `ksu_susfs` from susfs4ksu `gki-android12-5.10` @ `f3b5aec`
  (`ksu_module_susfs/tools/ksu_susfs_arm64`)

## Applying

On top of `wip/kernelsu`:

```sh
git checkout -b wip/susfs 34007f3
git am patches/stage0/*.patch
git am patches/stage1/*.patch
git am patches/stage2/*.patch
git am patches/stage3/*.patch
git am patches/stage4/*.patch
```

`lineageos_a37f_defconfig` is updated by the series:

```
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
```

Install the tool as `/data/adb/ksu/bin/ksu_susfs` (0755). Then, as root:

```sh
ksu_susfs show version            # v2.3.0
ksu_susfs show variant            # NON-GKI
ksu_susfs show enabled_features   # includes CONFIG_KSU_SUSFS_SUS_MOUNT
ksu_susfs hide_sus_mnts_for_non_su_procs 1   # stage 1
```

Stage 1 has no per-mount command: every mount created or cloned while the
caller is in the su domain automatically gets a fake `mnt_id` from
`DEFAULT_KSU_MNT_ID` (2000000000) on. `hide_sus_mnts_for_non_su_procs 1`
makes `/proc/mounts`, `/proc/<pid>/mountinfo` and `/proc/<pid>/mountstats`
skip those mounts for every process outside the su domain (enabled at boot
in post-fs-data by the module scripts, then left on).

Note: with `CONFIG_KSU_HOSTSREDIRECT` off in this tree, KernelSU's
kernel_umount really unmounts for apps instead of just marking them; the
`__lookup_mnt` spoof for `TIF_KSU_UNMOUNTABLE` processes is ported anyway
and activates if that option is ever turned on.

Stage 2 (`sus_kstat`, `sus_map`) marks inodes from a root shell:

```sh
# store original stat info of a path (before it gets bind mounted /
# overlayed), then complete the spoof after the mount happens
ksu_susfs add_sus_kstat /path/of/file_or_directory
ksu_susfs update_sus_kstat /path/of/file_or_directory
# or set fake values in one shot (argc 15, 'default' keeps original value):
ksu_susfs add_sus_kstat_statically /system/addon.d 1234 1234 2 223344 \
    1712592355 0 1712592355 0 1712592355 0 16 512
# hide the file's VMAs from maps/smaps/pagemap/map_files of umounted apps
ksu_susfs add_sus_map /path/of/file_or_directory
```

The spoofs only apply to app processes (`uid % 100000 >= 10000`); `sus_map`
additionally requires the reader to be marked umounted. `kernel_umount.c`
now sets `TIF_KSU_UNMOUNTABLE` whenever SUSFS is enabled, so the marking
works without `CONFIG_KSU_HOSTSREDIRECT`, and (since stage 4 0004) also
when kernel umount is disabled in the manager.

Stage 4 adds the remaining optional features:

```sh
# apps opening <target> get <redirected> instead; uid_scheme 3 = umounted apps
ksu_susfs add_open_redirect <target> <redirected> <uid_scheme>
# uid_scheme: 1 = all non-su apps, 2 = root except su, 3 = non-su processes,
#             4 = umounted apps, 5 = umounted processes
ksu_susfs enable_avc_log_spoofing 1   # mask ksu denials in audit logs
```

Symbol hiding (`CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS`) is compile-time
and drops `ksu_*`/`susfs_*` entries from `/proc/kallsyms`.

Known caveat (upstream design): the `i_state` mark is in-memory only. If the
inode is evicted from the icache before the file is re-opened, stat/statfs/
fdinfo stop spoofing until `add_sus_kstat` is run again. The maps spoof
(ino/dev) does not depend on the mark, only on the hash entry. In practice
module scripts register after the file is in place and the daemon holds it
open; on this 3.10 port this matches upstream susfs4ksu behaviour.

Stage 3 (`sus_path`) hides files and directories from umounted app
processes (marked `TIF_KSU_UNMOUNTABLE`, uid >= 10000):

```sh
ksu_susfs add_sus_path /path/to/hide            # hide from lookups and readdir
ksu_susfs add_sus_path_loop /path/on/sus/mount  # re-mark after kernel_umount
```

`susfs_is_inode_sus_path()` gates on the umounted flag, so su shells and
non-umounted apps still see the files. The `/sdcard` decryption monitor
starts on `boot_complete` and disables the early-boot mount checks once
`/data/media/0/Android` appears.

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

### Stage 1 (sus_mount)

- 3.10 has no `ida_simple_get()`; the fake mnt_id allocator uses the
  `ida_pre_get()` + `ida_get_new_above()` dance and never bumps
  `mnt_id_start`, so normal mount ids stay in the low range.
- The `alloc_vfsmnt()` copies keep 3.10's `mnt_fsnotify_marks` init and use
  plain `kstrdup()` (`kstrdup_const` is 3.13+).
- `__lookup_mnt()` iterates a `list_head` here (an hlist since 4.x); the sus
  mount skip is folded into the list walk.
- `CL_COPY_MNT_NS` is set in `dup_mnt_ns()` (4.4 calls it `copy_mnt_ns()`).
- `susfs_is_current_ksu_domain()` maps to this fork's `is_ksu_domain()` SID
  check (backslashxx has no susfs support of its own).
- `susfs_is_current_proc_umounted()` maps to the fork's `TIF_KSU_UNMOUNTABLE`
  flag; `susfs_def.h` defines it as 61 (64-bit) / 29 (32-bit), matching
  `drivers/kernelsu/policy/app_profile.h`.
- `VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT` is set right after the unshare alloc
  in `clone_mnt()`, not only after the `mnt_flags` copy. Upstream 4.4 leaves
  a window where an error path (`clone_mnt_data` failing, which sdcardfs
  implements) would `ida_remove()` the borrowed id in `mnt_free_id()`.

### Stage 2 (sus_kstat, sus_map)

- `struct kstat` has no `result_mask` (4.11+); the field is backported. It
  is never copied to userspace, so the ABI is unchanged.
- 3.10 has no `vfs_getattr_nosec()`; the hook lives in `vfs_getattr()`
  after the security check, and `result_mask` is zeroed first because 3.10
  callers pass uninitialized stack kstats.
- fdinfo base in 3.10 prints only pos/flags (no mnt_id/ino), so the 4.4
  `sus_mount` fdinfo branch has nothing to spoof and is not ported; the
  kstat branch prints the mnt_id/ino lines only for marked files.
- `inotify/fanotify_fdinfo()` keep 3.10's ret-accumulating show() style and
  `mark->mask` format.
- `proc_map_files_readdir()` is two-pass here; the `sus_map` skip goes in
  both the count and the collect loop to keep `f_pos` consistent.
- `__access_remote_vm()` declares `vma` at function scope in 3.10; only
  the `find_vma()` prefill and the loop check are added.
- `get_anon_bdev()` (missed `sus_mount` piece): 3.10 has no
  `ida_simple_get()`; su domain mounts get anon devs from
  `DEFAULT_KSU_MNT_MINOR_DEV` without bumping `unnamed_dev_start`.
- `susfs_get_non_sus_mnt_id_from_mnt()` and
  `susfs_get_non_sus_vfsmnt_from_vfsmnt()` land now (declared `extern`
  since stage 0): `sus_kstat` snapshots the non-sus mnt_id/statfs of
  marked files. 3.10 has no `lock_mount_hash()`; `vfsmount_lock` is taken
  via `br_write_lock` instead.
- The pre-6.1 `SUSFS_LOGI` in `susfs_mark_inode_sus_kstat()` prints
  `spoofed_size` with `%u` while the field is a `long long`; use `%lld`.
- `kernel_umount.c` sets `TIF_KSU_UNMOUNTABLE` whenever SUSFS is enabled
  (not only under `KSU_HOSTSREDIRECT`), otherwise `sus_map` and the
  fdinfo/statfs spoofs for umounted apps never trigger on this fork.
  The mark must also come before the `ksu_kernel_umount_enabled` and
  `ksu_module_mounted` checks, as in upstream `handle_zygote_setresuid()`.
  Stages 2 and 3 set it after them, so with kernel umount off no app was
  marked and every app-side feature was inert (fixed in stage 4 0004).

### Stage 3 (sus_path)

- `struct nameidata` has no `state` field and 3.10 has no
  `set_nameidata()`; the field is zeroed in `path_init()`.
- `lookup_fast()` takes a path/inode out pair here; the RCU branch hook
  drops the dentry via `goto unlazy` (no `dput`, `__d_lookup_rcu` holds no
  reference), the ref-walk branch `dput`s it.
- 3.10's `lookup_slow()` goes straight to `__lookup_hash()` and cannot
  express a NULL dentry (4.4 returns NULL from `lookup_dcache()`), so the
  ungated hide lives in `lookup_slow()` after the dentry materializes and
  in `lookup_open()` for the open path.
- `link_path_walk()` has no `OK:` label; the walk-in check goes after the
  `nested_symlink()` block, before `can_lookup()`.
- `lookup_last()` keeps its 3.10 `path` argument.
- readdir: `filldir`/`filldir64` keep 3.10's `put_user(d_off)` ordering;
  the `ilookup()` skip is placed before emitting the entry, as in 4.4.
- 3.10's `fsnotify_ops.handle_event` receives a `struct fsnotify_event *`
  instead of the split `mask`/`data`/`file_name` arguments, so the sdcard
  handler is written against the 3.10 API; `SUSFS_DECL_FSNOTIFY_OPS` only
  covers 4.3+ and is not used here. 3.10's `send_to_group()` also calls
  `ops->should_send_event()` unconditionally, so the ops provide it; the
  first iteration left it NULL and panicked on the first `/data/media/0`
  event after `boot_complete` (found and fixed on device via pstore).
- The sdcard monitor and extra works need `setup_selinux()` and `ksu_cred`;
  both exist in the backslashxx fork since the 3.3.0-48 update.

### Stage 4 (open_redirect, symbol hiding, avc log spoofing)

- 3.10's `path_openat()` opens the file inside `do_last()` during the walk
  (5.10 splits it into `open_last_lookups()`+`do_open()`), so the redirect
  re-walk releases the first open via `fput()`+`get_empty_filp()` first;
  otherwise `finish_open()` hits `BUG_ON(*opened & FILE_OPENED)`.
- `do_last()` already ends with `terminate_walk()` in 3.10, so the redirect
  branch must not call it again (0003). The extra call put the target's
  dentry and vfsmount once more per redirected open, and the next umount
  panicked with `dentry still in use (-1)`. To test, redirect a file on a
  tmpfs, open it a few times and umount the tmpfs. A reboot is not a
  reliable test: /data is often busy at shutdown and never unmounts.
- No `set_nameidata()`/`restore_nameidata()`; the re-walk calls
  `path_init(dfd, fake->name, flags)` directly and drops the previous
  `base` file ref first.
- `do_tmpfile()` takes `dfd`/`pathname` here; the redirect redoes
  `path_lookupat()` on the fake name after `path_put()` of the original.
- `filename_lookup()` in 3.10 fills a `struct nameidata`, not a path.
- `generic_readlink()` is `follow_link()`+`vfs_readlink()` based; the spoof
  result is kept separate so a non-matching entry falls back to the real
  link instead of returning `-ENOENT`.
- 3.10 has no `show_vma_header_prefix()`; the maps spoof prints the header
  inline as `show_map_vma()` itself does.
- 3.10 has no `getname_kernel()`; `susfs_getname_kernel()` builds an
  embedded `struct filename` the way `getname_flags()` does, so `putname()`
  releases it correctly.
- The avc hook lives in `avc_dump_query()` (3.10 still formats queries
  there); `susfs_ksu_sid`/`susfs_priv_app_sid` are cached in `susfs_init()`
  via `security_secctx_to_secid()`.


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
