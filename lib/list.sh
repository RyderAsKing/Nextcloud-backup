#!/bin/bash

#===============================================================================
# List Functions
#===============================================================================

list_backups() {
    local server="$1"

    if [[ -z "$server" ]]; then
        log "ERROR" "Server name is required for listing backups"
        return 1
    fi

    local server_backup_dir="$BACKUP_ROOT/$server"

    if [[ ! -d "$server_backup_dir" ]]; then
        log "WARNING" "No backup directory found for server $server: $server_backup_dir"
        echo "No backups found for server: $server"
        return 0
    fi

    log "INFO" "Listing backups for server: $server"

    # Get list of backup directories sorted by date (newest first)
    local backup_dirs
    mapfile -t backup_dirs < <(find "$server_backup_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort -r)
    local total_backups=${#backup_dirs[@]}

    if [[ $total_backups -eq 0 ]]; then
        echo "No backups found for server: $server"
        log "INFO" "No backups found for server $server"
        return 0
    fi

    echo ""
    echo "Backups for server: $server"
    echo "=========================="
    echo "Total backups: $total_backups"
    echo ""
    printf "%-20s %-12s %-15s %-s\n" "Backup Date/Time" "Size" "Database" "Status"
    printf "%-20s %-12s %-15s %-s\n" "----------------" "----" "--------" "------"

    local valid_backups=0
    local invalid_backups=0

    for backup_dir in "${backup_dirs[@]}"; do
        local backup_name
        backup_name=$(basename "$backup_dir")
        local backup_size
        backup_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
        local backup_date="" backup_time=""
        local db_status="No"
        local backup_status="Incomplete"

        # Parse backup name (format: YYYY-MM-DD_HH-MM-SS)
        if [[ $backup_name =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})$ ]]; then
            backup_date="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
            backup_time="${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
        else
            backup_date="$backup_name"
        fi

        # Check for database backup
        if ls "$backup_dir"/*.sql >/dev/null 2>&1; then
            local db_file db_size_val
            db_file=$(ls "$backup_dir"/*.sql 2>/dev/null | head -n1)
            db_size_val=$(du -sh "$db_file" 2>/dev/null | cut -f1)
            db_status="Yes ($db_size_val)"
        fi

        # Check backup completeness
        if [[ -f "$backup_dir/backup_info.txt" ]] && [[ -d "$backup_dir/config" ]] && [[ -d "$backup_dir/data" ]]; then
            backup_status="Complete"
            (( valid_backups++ ))
        else
            backup_status="Incomplete"
            (( invalid_backups++ ))
        fi

        local datetime_display="$backup_date $backup_time"
        printf "%-20s %-12s %-15s %-s\n" "$datetime_display" "$backup_size" "$db_status" "$backup_status"
    done

    echo ""
    echo "Summary:"
    echo "  Valid backups: $valid_backups"
    echo "  Invalid backups: $invalid_backups"
    echo "  Backup directory: $server_backup_dir"
    echo ""

    if [[ $invalid_backups -gt 0 ]]; then
        log "WARNING" "Found $invalid_backups incomplete backup(s) for server $server"
        return 1
    else
        log "SUCCESS" "Listed $valid_backups backup(s) for server $server"
        return 0
    fi
}
