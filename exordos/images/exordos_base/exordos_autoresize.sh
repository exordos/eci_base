#!/usr/bin/env bash

# Copyright 2025-2026 Genesis Corporation
#
# All Rights Reserved.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

# Grow partitions and filesystems up to the size of the underlying disk.
#
# Usage:
#   exordos_autoresize.sh            grow every mounted partition
#   exordos_autoresize.sh <disk>     grow the mounted partitions of one disk
#
# The first form runs once at boot and covers disks that were enlarged while
# the machine was off. The second form is triggered by udev when the
# hypervisor enlarges a disk of a running machine.

set -eu
set -x
set -o pipefail

log() {
  echo "[exordos-autoresize] $*"
}

wait_for_rw_root() {
  while [[ "$(findmnt / -o options -n | grep -E "^ro,|,ro,|,ro$")" != "" ]]
  do
    log "Waiting for root partition to be in RW mode"
    sleep 2
  done
}

# List "<partition> <mount point>" pairs of mounted partitions.
# Args:
#   $1 - (optional) disk to limit the listing to, e.g. /dev/vda
list_mounted_partitions() {
  local disk="${1:-}"

  # shellcheck disable=SC2086
  lsblk -nr -o PATH,TYPE,MOUNTPOINT ${disk:+"$disk"} \
    | awk '$2 == "part" && $3 != "" && $3 != "[SWAP]" {print $1, $3}'
}

# Grow a single mounted partition and the filesystem on it.
# Args:
#   $1 - partition device, e.g. /dev/vda1
#   $2 - mount point of that partition, e.g. /
grow_partition() {
  local part="$1"
  local mount_point="$2"
  local disk partition_number fstype

  fstype="$(findmnt -n -o FSTYPE "$mount_point")"

  # Partitions we cannot grow are expected here: the sweep walks every mounted
  # partition, and images ship an EFI system partition among them.
  case "$fstype" in
    ext2|ext3|ext4|xfs) ;;
    *)
      log "Filesystem '$fstype' on $part is not growable; skipping"
      return 0
      ;;
  esac

  disk="/dev/$(lsblk -no PKNAME "$part")"
  partition_number="$(cat "/sys/class/block/$(basename "$part")/partition")"

  log "Growing $part ($fstype) on disk $disk, partition $partition_number, mounted at $mount_point"

  # growpart exits non-zero when the partition is already the last one and
  # occupies the whole disk, so failures here are not fatal.
  growpart "$disk" "$partition_number" || true

  case "$fstype" in
    ext2|ext3|ext4)
      resize2fs "$part"
      ;;
    xfs)
      # XFS grows by mount point, not by device
      xfs_growfs "$mount_point"
      ;;
  esac
}

DISK="${1:-}"

if [[ -n "$DISK" && ! -b "$DISK" ]]; then
  log "Disk $DISK does not exist; nothing to grow"
  exit 0
fi

wait_for_rw_root

RC=0
while read -r PART MOUNT_POINT; do
  grow_partition "$PART" "$MOUNT_POINT" || RC=1
done < <(list_mounted_partitions "$DISK")

exit "$RC"
