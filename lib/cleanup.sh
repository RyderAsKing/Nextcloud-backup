#!/bin/bash

#===============================================================================
# Cleanup Functions
#===============================================================================

cleanup_old_backups() {
    local server="$1"

    if [[ -z "$server" ]]; then
        log "ERROR" "Server name is required for cleanup"
        return 1
    fi

    local retention_count
    retention_count=$(get_server_config "$server" "retention_count")
    retention_count="${retention_count:-$RETENTION_COUNT}"

    local server_backup_dir="$BACKUP_ROOT/$server"

    if [[ ! -d "$server_backup_dir" ]]; then
        log "WARNING" "No backup directory found for server $server: $server_backup_dir"
        return 0
    fi

    log "INFO" "Starting cleanup for server $server (keeping $retention_count backups)"

    # Get list of backup directories sorted by date (oldest first)
    local backup_dirs
    mapfile -t backup_dirs < <(find "$server_backup_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort)
    local total_backups=${#backup_dirs[@]}

    log "INFO" "Debug: Found backup directories:"
    for debug_dir in "${backup_dirs[@]}"; do
        log "INFO" "  - $(basename "$debug_dir")"
    done

    if [[ $total_backups -eq 0 ]]; then
        log "INFO" "No backups found for server $server"
        return 0
    fi

    log "INFO" "Found $total_backups backup(s) for server $server"

    if [[ $total_backups -le $retention_count ]]; then
        log "INFO" "Current backup count ($total_backups) is within retention limit ($retention_count), no cleanup needed"
        return 0
    fi

    local backups_to_remove=$(( total_backups - retention_count ))
    local removed_count=0
    local failed_count=0

    log "INFO" "Need to remove $backups_to_remove old backup(s)"

    for (( i=0; i<backups_to_remove; i++ )); do
        local backup_dir="${backup_dirs[$i]}"
        local backup_name
        backup_name=$(basename "$backup_dir")

        local backup_size="unknown"
        [[ -d "$backup_dir" ]] && backup_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1 || echo "unknown")

        log "INFO" "Removing old backup ($((i+1))/$backups_to_remove): $backup_name (size: $backup_size)"

        if [[ -d "$backup_dir" ]]; then
            set +e
            rm -rf "$backup_dir" 2>/dev/null
            local rm_exit_code=$?

            if [[ $rm_exit_code -eq 0 ]]; then
                log "SUCCESS" "Removed backup: $backup_name"
                (( removed_count++ ))
            else
                log "ERROR" "Failed to remove backup: $backup_name (exit code: $rm_exit_code)"
                log "INFO" "Attempting alternative removal method for: $backup_name"
                chmod -R 755 "$backup_dir" 2>/dev/null
                rm -rf "$backup_dir" 2>/dev/null
                local alt_rm_exit_code=$?

                if [[ $alt_rm_exit_code -eq 0 ]]; then
                    log "SUCCESS" "Removed backup with alternative method: $backup_name"
                    (( removed_count++ ))
                else
                    log "ERROR" "Alternative removal also failed for backup: $backup_name"
                    (( failed_count++ ))
                fi
            fi
            set -e
        else
            log "WARNING" "Backup directory no longer exists: $backup_name"
            (( removed_count++ ))
        fi

        log "INFO" "Progress: $((i+1))/$backups_to_remove completed (removed: $removed_count, failed: $failed_count)"
    done

    local remaining_dirs actual_remaining
    mapfile -t remaining_dirs < <(find "$server_backup_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort)
    actual_remaining=${#remaining_dirs[@]}

    if [[ $failed_count -eq 0 ]]; then
        log "SUCCESS" "Cleanup completed for server $server: removed $removed_count backup(s)"
        log "INFO" "Verification: $actual_remaining backup directories actually remain"

        if [[ $actual_remaining -eq $retention_count ]]; then
            log "SUCCESS" "Cleanup verification passed: exactly $retention_count backups remain"
        elif [[ $actual_remaining -lt $retention_count ]]; then
            log "WARNING" "Cleanup removed more backups than expected: $actual_remaining remain (expected $retention_count)"
        else
            log "ERROR" "Cleanup incomplete: $actual_remaining remain (expected $retention_count)"
            return 1
        fi
        return 0
    else
        log "WARNING" "Cleanup completed with errors for server $server: removed $removed_count, failed $failed_count"
        log "INFO" "Verification: $actual_remaining backup directories actually remain after partial cleanup"
        return 1
    fi
}
