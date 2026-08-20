#!/bin/bash
#
# build-kvm-relay-guard.sh
#
# Build + install the nested-Hyper-V hypercall relay into the running Proxmox VE
# kernel's kvm.ko / kvm-intel.ko. This repo is the single source: it makes a
# fresh worktree of the matching PVE kernel branch, then runs
# kvm_patch_apply_hcall_relay.sh (relay anchored edits + build + install).
#
# The timer-storm guard is OPT-IN (GUARD=1) and NOT part of the default build as
# of 2026-08-20. The guard existed to bound a past-dated one-shot stimer re-arm
# storm from the L1 root on this no-VMX-TSC-scaling host. openvmm now removes
# that storm at its source by aligning the guest TSC so the partition reference
# counter leads the kvmclock by a verified floor on cold boot AND on reset, so
# the arms the guard was throttling no longer happen: measured past-dated arm
# rate fell from ~1.88 M/s to 0.02-0.03/s, identical with the guard on and off.
# A guard-less kernel is therefore the correct default; the patch stays in the
# repo for a host or a binary that predates that openvmm fix. See
# docs/timer-guard.md.
#
# Run ON the target PVE host. The kernel source MUST match `uname -r` EXACTLY: a
# version-mismatched build loads (modversions tolerates it) but the kvm struct
# layouts differ, so nested guests SIGSEGV at ~0.1 s. The per-release PVE source
# is the git repo PVE_KERNEL_REPO, one branch per release (7.0.2-7, ...).
#
# Env:
#   PVE_KERNEL_REPO  PVE kernel git repo (default /usr/src/pve-x86-v7-build/repo)
#   KVM_RELAY_SRC    build worktree path (default /usr/src/kvm-guard)
#   GUARD            1 to also apply the timer-storm guard (default 0)
#
# After it finishes, activate (with 0 running VMs, Tasmota ready):
#   rmmod kvm_intel kvm && modprobe kvm_intel
#   cat /sys/module/kvm/srcversion   # must change to the new build
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${PVE_KERNEL_REPO:-/usr/src/pve-x86-v7-build/repo}"
SRC="${KVM_RELAY_SRC:-/usr/src/kvm-guard}"
GUARD="${GUARD:-0}"
BR="$(uname -r | sed 's/-pve$//')"

[ "$(id -u)" = 0 ] || { echo "error: run as root" >&2; exit 1; }
[ -d "$REPO/.git" ] || { echo "error: PVE kernel git repo not found: $REPO" >&2; exit 1; }

echo "== fresh worktree of branch ${BR} =="
rm -rf "$SRC"
git -C "$REPO" worktree prune
git -C "$REPO" worktree add --detach "$SRC" "$BR"

if [ "$GUARD" = 1 ]; then
    echo "== apply relay + timer guard, build + install =="
else
    echo "== apply relay (no timer guard), build + install =="
fi
KVM_RELAY_SRC="$SRC" GUARD="$GUARD" bash "$HERE/kvm_patch_apply_hcall_relay.sh"

echo "== build artefacts =="
echo "  vermagic=$(modinfo -F vermagic "$SRC/arch/x86/kvm/kvm.ko" 2>/dev/null)"
echo "  srcversion=$(modinfo -F srcversion "$SRC/arch/x86/kvm/kvm.ko" 2>/dev/null)"
echo "  cap=$(grep -c '0x4f564d52' "$SRC/include/uapi/linux/kvm.h" 2>/dev/null) (relay, want >0)"
# Both guard counts are reported either way and compared against what THIS build
# asked for, so a guard that silently survived into a guard-less build (a stale
# worktree, a half-applied patch) is visible instead of being read as success.
# The guard's state-load clear is a separate hunk from the storm detection, so a
# partial apply builds and loads and simply carries a throttle across every
# reset; "guard params=2" says nothing about it, hence its own line.
echo "  guard params=$(modinfo -p "$SRC/arch/x86/kvm/kvm.ko" 2>/dev/null | grep -c hv_stimer) (want $([ "$GUARD" = 1 ] && echo 2 || echo 0))"
echo "  state-load clear=$(grep -c 'stimer->imm_fire_ns = 0;' "$SRC/arch/x86/kvm/hyperv.c" 2>/dev/null) (want $([ "$GUARD" = 1 ] && echo 1 || echo 0))"
echo "== installed for $(uname -r). Activate (0 VMs): rmmod kvm_intel kvm && modprobe kvm_intel =="
