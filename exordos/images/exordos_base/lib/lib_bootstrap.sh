#!/usr/bin/env bash

#    Copyright 2026 Genesis Corporation.
#
#    All Rights Reserved.
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

set -eu
set -x
set -o pipefail

PERSISTENT_MOUNT="/persist"
PERSIST_MIGRATE_MARKER="${PERSISTENT_MOUNT}/bootstrap_success.txt"

get_root_disk() {
    local root_mount
    root_mount=$(findmnt -n -o SOURCE /)
    local disk
    disk=$(lsblk -no PKNAME "$root_mount" 2>/dev/null || echo "")
    if [[ -n "$disk" ]]; then
        echo "/dev/$disk"
    else
        basename "$root_mount" | sed 's/[0-9]*$//'
    fi
}

find_persistent_disk() {
    local root_disk
    root_disk=$(get_root_disk)

    local disks
    disks=$(lsblk -d -n -o NAME,TYPE,RO | grep -E 'disk\s+0$' | awk '{print "/dev/" $1}')

    for disk in $disks; do
        if [[ "$disk" == "$root_disk" ]] || [[ "$disk" == "/dev/$(basename "$root_disk")" ]]; then
            continue
        fi
        echo "$disk"
        return 0
    done

    return 1
}

is_disk_formatted() {
    local disk="$1"
    local fs_type
    fs_type=$(blkid -s TYPE -o value "$disk" 2>/dev/null)
    [[ -n "$fs_type" ]]
}

is_disk_mounted() {
    local disk="$1"
    findmnt -rno SOURCE "$disk" 2>/dev/null | grep -q "$(basename "$disk")"
}

get_partition_uuid() {
    local disk="$1"
    blkid -s UUID -o value "$disk" 2>/dev/null || echo ""
}

get_partition_name() {
    local disk="$1"
    # For nvme devices, partition name is like nvme0n1p1
    # For sd devices, partition name is like sda1
    if [[ "$disk" =~ nvme ]]; then
        echo "${disk}p1"
    else
        echo "${disk}1"
    fi
}

has_gpt_partition() {
    local disk="$1"
    local partition
    partition=$(get_partition_name "$disk")
    [[ -b "$partition" ]]
}

create_gpt_partition() {
    local disk="$1"
    echo "Creating GPT partition table on $disk..."
    parted -s "$disk" mklabel gpt
    echo "Creating partition 1 on $disk..."
    parted -s "$disk" mkpart primary 0% 100%
    # Wait for partition to be created
    sleep 1
    # Notify kernel about partition table changes
    partprobe "$disk" 2>/dev/null || true
    local partition
    partition=$(get_partition_name "$disk")
    # Wait for partition device to appear
    local retries=10
    while [[ ! -b "$partition" ]] && [[ $retries -gt 0 ]]; do
        sleep 1
        ((retries--))
    done
    if [[ -b "$partition" ]]; then
        echo "Partition $partition created successfully."
    else
        echo "ERROR: Failed to create partition $partition"
        return 1
    fi
}

is_persist_migrate_completed() {
    [[ -f "$PERSIST_MIGRATE_MARKER" ]]
}

should_migrate_data() {
    if [[ -f "$PERSIST_MIGRATE_MARKER" ]]; then
        echo "true"
    fi;
}

persist_migrate_complete() {
    echo "Bootstrap completed at $(date -Iseconds)" > "$PERSIST_MIGRATE_MARKER"
    echo "Bootstrap marker created at $PERSIST_MIGRATE_MARKER"
}

wait_for_mount() {
    local mount_point="$1"
    while ! grep -qs "$mount_point" /proc/mounts; do
        echo "Waiting for mount $mount_point..."
        sleep 0.1
    done
}

prepare_persistent_disk() {
    local persistent_disk="$1"
    local mount_point="$2"
    local fstype="${3:-ext4}"

    if [[ -z "$persistent_disk" ]]; then
        echo "WARNING: No persistent disk found. Using root filesystem."
        return 0
    fi

    echo "Found persistent disk: $persistent_disk"

    mkdir -p "$mount_point"

    # Get partition name for the persistent disk
    local partition
    partition=$(get_partition_name "$persistent_disk")

    # Check if partition already exists
    if has_gpt_partition "$persistent_disk"; then
        echo "GPT partition already exists on $persistent_disk"
    else
        # Disk is not partitioned, create GPT partition table and partition
        create_gpt_partition "$persistent_disk"
        echo "Formatting persistent partition $partition..."
        mkfs."$fstype" "$partition"
    fi

    if ! is_disk_mounted "$partition"; then
        if is_disk_formatted "$partition"; then
            echo "Persistent partition $partition already formatted."
        else
            echo "Formatting persistent partition $partition..."
            mkfs."$fstype" "$partition"
        fi

        echo "Mounting persistent partition $partition to $mount_point..."
        mount "$partition" "$mount_point"
        wait_for_mount "$mount_point"
    fi

    local part_uuid
    part_uuid=$(get_partition_uuid "$partition")
    if [[ -n "$part_uuid" ]]; then
        if grep -q "$mount_point" /etc/fstab; then
            # Replace existing entry
            sed -i "s|^.*[[:space:]]${mount_point}[[:space:]].*|UUID=$part_uuid $mount_point auto defaults 0 2|" /etc/fstab
            echo "Updated persistent partition entry in /etc/fstab"
        else
            echo "UUID=$part_uuid $mount_point auto defaults 0 2" >> /etc/fstab
            echo "Added persistent partition to /etc/fstab"
        fi
    fi

    echo "$partition"
}

# Migrate service data to persistent storage with bind mount
# Args:
#   $1 - path to the old data directory (e.g., /var/lib/postgresql/18/main)
#   $2 - path to the persistent directory (e.g., /persist/postgresql)
#   $3 - (optional) owner user to apply to persistent_dir (default: inherited from old_data_dir)
#   $4 - (optional) owner group to apply to persistent_dir (default: inherited from old_data_dir)
migrate_to_persistent() {
    local old_data_dir="$1"
    local persistent_dir="$2"
    local override_user="${3:-}"
    local override_group="${4:-}"

    if [[ -z "$old_data_dir" ]] || [[ -z "$persistent_dir" ]]; then
        echo "ERROR: migrate_to_persistent requires old_data_dir and persistent_dir"
        return 1
    fi

    # Create tmp directory name for atomic swap
    local tmp_dir="${persistent_dir}.tmp"

    # Clean up any leftover tmp directory from previous failed attempts
    if [[ -d "$tmp_dir" ]]; then
        echo "Removing leftover tmp directory: $tmp_dir"
        rm -rf "$tmp_dir"
    fi

    if [ -d "$persistent_dir" ]; then
        echo "Skipping data migration, $persistent_dir dir already exists"
    else
        if [[ -d "$old_data_dir" ]]; then
            echo "Migrating data from $old_data_dir to $persistent_dir (using atomic swap)..."

            # Create tmp directory for rsync target
            mkdir -p "$tmp_dir"

            # Copy data to temporary directory using rsync
            rsync -av "$old_data_dir/" "$tmp_dir/" || {
                echo "ERROR: rsync failed, cleaning up $tmp_dir"
                rm -rf "$tmp_dir"
                return 1
            }

            # Get ownership and permissions from original
            local owner group
            owner=$(stat -c '%U' "$old_data_dir" 2>/dev/null || echo "root")
            group=$(stat -c '%G' "$old_data_dir" 2>/dev/null || echo "root")
            owner="${override_user:-$owner}"
            group="${override_group:-$group}"
            chown "$owner:$group" "$tmp_dir"

            local perms
            perms=$(stat -c '%a' "$old_data_dir" 2>/dev/null || echo "755")
            chmod "$perms" "$tmp_dir"

            echo "Data copied to tmp directory, performing atomic mv..."

            mv "$tmp_dir" "$persistent_dir" || {
                echo "ERROR: atomic mv failed"
                return 1
            }

            echo "Clearing old data directory: $old_data_dir"
            find "$old_data_dir" -mindepth 1 -delete
        fi
    fi

    # Add bind mount to fstab if not already present
    if ! grep -q "$old_data_dir" /etc/fstab 2>/dev/null; then
        echo "$persistent_dir $old_data_dir none bind 0 0" >> /etc/fstab
        echo "Added bind mount to /etc/fstab"
    fi

    # Don't wait for fstab reload, use mount explicitly
    mount --bind "$persistent_dir" "$old_data_dir"

    if [[ $(stat -L -c %d:%i "$persistent_dir") != $(stat -L -c %d:%i "$old_data_dir") ]]; then
        echo "Bind mount failed! Please debug the problem"
        exit 1
    fi

    if [[ "$(pwd)" == "$old_data_dir"* ]]; then
        # We've migrated path which our process used as CWD, fix it
        cd "$(pwd)"
    fi
}

# Migrate service data to persistent storage with bind mount, with stop-start cycle
# Args:
#   $1 - path to the old data directory (e.g., /var/lib/postgresql/18/main)
#   $2 - path to the persistent directory (e.g., /persist/postgresql)
#   $3 - space-separated list of systemd services to stop/start, may be empty
#   $4 - (optional) owner user to apply to persistent_dir (default: inherited from old_data_dir)
#   $5 - (optional) owner group to apply to persistent_dir (default: inherited from old_data_dir)
migrate_to_persistent_stop_start() {
    local old_data_dir="$1"
    local persistent_dir="$2"
    local services="$3"
    local override_user="${4:-}"
    local override_group="${5:-}"

    # Stop services (if any)
    if [[ -n "$services" ]]; then
        echo "Stopping services: $services"
        for service in $services; do
            echo "Stopping $service..."
            systemctl stop "$service"
        done
    fi

    if [[ -n "$services" ]]; then
        for service in $services; do
            while systemctl is-active --quiet "$service"; do
                echo "$service is still active, waiting..."
                sleep 0.1
            done
        done
    fi

    migrate_to_persistent "$old_data_dir" "$persistent_dir" "$override_user" "$override_group"

    # Start services again
    if [[ -n "$services" ]]; then
        echo "Starting services: $services"
        for service in $services; do
            echo "Starting $service..."
            systemctl start "$service"
        done
    fi
}

# Migrate service data to persistent storage with bind mount, with restart
# Args:
#   $1 - path to the old data directory (e.g., /var/lib/postgresql/18/main)
#   $2 - path to the persistent directory (e.g., /persist/postgresql)
#   $3 - space-separated list of systemd services to stop/start, may be empty
#   $4 - (optional) owner user to apply to persistent_dir (default: inherited from old_data_dir)
#   $5 - (optional) owner group to apply to persistent_dir (default: inherited from old_data_dir)
migrate_to_persistent_restart() {
    local old_data_dir="$1"
    local persistent_dir="$2"
    local services="$3"
    local override_user="${4:-}"
    local override_group="${5:-}"

    migrate_to_persistent "$old_data_dir" "$persistent_dir" "$override_user" "$override_group"

    # Restart services
    if [[ -n "$services" ]]; then
        echo "Restarting services: $services"
        for service in $services; do
            echo "Restarting $service..."
            systemctl restart "$service"
        done
    fi
}

generate_secure_password()
{
    echo $(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
}

# Generate config from template, if it doesn't exist
# Args:
#   $1 - path to target config
try_generate_config() {
    local config_file="$1"
    local config_template="${config_file}.j2"

    if [[ -f "$config_file" ]]; then
        echo "Config file $config_file already exists, do nothing"
        return 0
    fi

    if [[ ! -f "$config_template" ]]; then
        echo "ERROR: Config template $config_template not found"
        return 1
    fi

    j2 "$config_template" -o "$config_file"

    echo "Config file created at $config_file"
}

setup_postgresql_user_and_db() {
    local pg_user="$1"
    local pg_pass="$2"
    local pg_db="$3"

    echo "Starting PostgreSQL..."
    systemctl enable --now postgresql

    # Wait for PostgreSQL to be ready
    local retries=30
    while ! sudo -u postgres psql -tAc "SELECT 1" >/dev/null 2>&1; do
        if [[ $retries -eq 0 ]]; then
            echo "ERROR: PostgreSQL failed to start"
            return 1
        fi
        echo "Waiting for PostgreSQL to start..."
        sleep 0.5
        ((retries--))
    done

    # Create user if not exists, or update password if exists
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$pg_user'" | grep -q 1; then
        echo "Creating PostgreSQL user $pg_user..."
        sudo -u postgres psql -c "CREATE ROLE $pg_user WITH LOGIN PASSWORD '$pg_pass';"
    else
        echo "PostgreSQL user $pg_user already exists, updating password..."
        sudo -u postgres psql -c "ALTER ROLE $pg_user WITH PASSWORD '$pg_pass';"
    fi

    # Create database if not exists
    if ! sudo -u postgres psql -XtAc "SELECT 1 FROM pg_database WHERE datname='$pg_db'" | grep -q 1; then
        echo "Creating PostgreSQL database $pg_db..."
        sudo -u postgres psql -c "CREATE DATABASE $pg_db OWNER $pg_user;"
    else
        echo "PostgreSQL database $pg_db already exists."
    fi
}

wait_for_db() {
    local pg_user="$1"
    local pg_pass="$2"
    local pg_db="$3"
    local endpoints="$4"
    local max_attempts="${5:-600}"
    local attempt=1

    echo "Waiting for database to be available (max ${max_attempts} attempts)..."

    while [ "$attempt" -le "$max_attempts" ]; do
        # Try to connect to database using psql
        if PGPASSWORD="$pg_pass" psql -h "$endpoints" -U "$pg_user" -d "$pg_db" -c "SELECT 1;" >/dev/null 2>&1; then
            echo "Database is available after $attempt attempts"
            return 0
        fi

        echo "Attempt $attempt: Database not ready, waiting 1 second..."
        sleep 1
        attempt=$((attempt + 1))
    done
    echo "ERROR: Database not available after $max_attempts attempts"
    return 1
}
