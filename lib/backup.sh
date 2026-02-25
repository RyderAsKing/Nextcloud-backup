#!/bin/bash

#===============================================================================
# Backup Functions
#===============================================================================

enable_maintenance_mode() {
    local server="$1"

    if [[ -z "$server" ]]; then
        log "ERROR" "Server name is required for maintenance mode"
        return 1
    fi

    local nextcloud_path
    nextcloud_path=$(get_server_config "$server" "nextcloud_path")

    if [[ -z "$nextcloud_path" ]]; then
        log "ERROR" "Nextcloud path not configured for server $server"
        return 1
    fi

    log "INFO" "Enabling maintenance mode for $server"

    local occ_command="cd '$nextcloud_path' && sudo -u www-data php occ maintenance:mode --on"

    if execute_remote_command "$server" "$occ_command" "enable maintenance mode"; then
        log "SUCCESS" "Maintenance mode enabled for $server"
        return 0
    else
        log "ERROR" "Failed to enable maintenance mode for $server"
        return 1
    fi
}

disable_maintenance_mode() {
    local server="$1"

    if [[ -z "$server" ]]; then
        log "ERROR" "Server name is required for maintenance mode"
        return 1
    fi

    local nextcloud_path
    nextcloud_path=$(get_server_config "$server" "nextcloud_path")

    if [[ -z "$nextcloud_path" ]]; then
        log "ERROR" "Nextcloud path not configured for server $server"
        return 1
    fi

    log "INFO" "Disabling maintenance mode for $server"

    local occ_command="cd '$nextcloud_path' && sudo -u www-data php occ maintenance:mode --off"

    if execute_remote_command "$server" "$occ_command" "disable maintenance mode"; then
        log "SUCCESS" "Maintenance mode disabled for $server"
        return 0
    else
        log "ERROR" "Failed to disable maintenance mode for $server"
        return 1
    fi
}

backup_database() {
    local server="$1"
    local backup_dir="$2"

    if [[ -z "$server" || -z "$backup_dir" ]]; then
        log "ERROR" "Server and backup directory are required for database backup"
        return 1
    fi

    local db_host db_port db_name db_user db_pass
    local ssh_host ssh_user ssh_auth_method ssh_pass
    db_host=$(get_server_config "$server" "db_host")
    db_port=$(get_server_config "$server" "db_port")
    db_name=$(get_server_config "$server" "db_name")
    db_user=$(get_server_config "$server" "db_user")
    db_pass=$(get_server_config "$server" "db_pass")
    ssh_host=$(get_server_config "$server" "ssh_host")
    ssh_user=$(get_server_config "$server" "ssh_user")
    ssh_auth_method=$(get_server_config "$server" "ssh_auth_method")
    ssh_pass=$(get_server_config "$server" "ssh_pass")

    # Validate database configuration
    if [[ -z "$db_host" ]]; then  log "ERROR" "Database host not configured for server $server";  return 1; fi
    if [[ -z "$db_name" ]]; then  log "ERROR" "Database name not configured for server $server";  return 1; fi
    if [[ -z "$db_user" ]]; then  log "ERROR" "Database user not configured for server $server";  return 1; fi
    if [[ -z "$db_pass" ]]; then  log "ERROR" "Database password not configured for server $server"; return 1; fi
    if [[ -z "$ssh_host" || -z "$ssh_user" ]]; then
        log "ERROR" "SSH configuration incomplete for server $server"
        return 1
    fi

    db_port="${db_port:-$DEFAULT_DB_PORT}"
    ssh_auth_method="${ssh_auth_method:-password}"

    log "INFO" "Backing up database for $server (host: $db_host, database: $db_name)"

    local dump_file="$backup_dir/database.sql"
    local dump_command="timeout $DB_TIMEOUT mysqldump -h $db_host -P $db_port -u $db_user -p'$db_pass' --single-transaction --routines --triggers --add-drop-table --create-options --disable-keys --extended-insert --quick --lock-tables=false $db_name"

    mkdir -p "$backup_dir"
    log "INFO" "Starting database dump to $dump_file"

    local ssh_command
    ssh_command=$(build_ssh_command "$server") || return 1

    local dump_success=false
    if [[ "$ssh_auth_method" == "password" ]]; then
        if SSHPASS="$ssh_pass" $ssh_command "$ssh_user@$ssh_host" "$dump_command" > "$dump_file" 2>/dev/null; then
            dump_success=true
        fi
    else
        if $ssh_command "$ssh_user@$ssh_host" "$dump_command" > "$dump_file" 2>/dev/null; then
            dump_success=true
        fi
    fi

    if [[ "$dump_success" == "true" ]]; then
        if [[ -s "$dump_file" ]]; then
            local file_size line_count
            file_size=$(du -h "$dump_file" | cut -f1)
            line_count=$(wc -l < "$dump_file")
            log "SUCCESS" "Database backup completed for $server (size: $file_size, lines: $line_count)"
            if head -n 10 "$dump_file" | grep -q "MySQL dump"; then
                log "INFO" "Database dump file appears valid"
            else
                log "WARNING" "Database dump file may be invalid (no MySQL dump header found)"
            fi
            return 0
        else
            log "ERROR" "Database backup file is empty for $server"
            return 1
        fi
    else
        log "ERROR" "Database backup failed for $server"
        return 1
    fi
}

sync_files() {
    local server="$1"
    local backup_dir="$2"

    if [[ -z "$server" || -z "$backup_dir" ]]; then
        log "ERROR" "Server and backup directory are required for file sync"
        return 1
    fi

    local ssh_host ssh_user ssh_auth_method ssh_pass nextcloud_path
    ssh_host=$(get_server_config "$server" "ssh_host")
    ssh_user=$(get_server_config "$server" "ssh_user")
    ssh_auth_method=$(get_server_config "$server" "ssh_auth_method")
    ssh_pass=$(get_server_config "$server" "ssh_pass")
    nextcloud_path=$(get_server_config "$server" "nextcloud_path")

    ssh_auth_method="${ssh_auth_method:-password}"

    if [[ -z "$ssh_host" || -z "$ssh_user" || -z "$nextcloud_path" ]]; then
        log "ERROR" "SSH and Nextcloud configuration incomplete for server $server"
        return 1
    fi

    log "INFO" "Starting file synchronization for $server"
    log "INFO" "Source: $ssh_user@$ssh_host:$nextcloud_path"
    log "INFO" "Destination: $backup_dir"

    local ssh_command
    ssh_command=$(build_ssh_command "$server") || return 1

    local rsync_opts="-avz --compress-level=$COMPRESSION_LEVEL --delete --stats"
    rsync_opts="$rsync_opts --exclude=data/*/cache --exclude=data/*/thumbnails --exclude=data/*/files_trashbin"
    rsync_opts="$rsync_opts --exclude=data/*/files_versions --exclude=data/appdata_*/preview"
    rsync_opts="$rsync_opts -e '$ssh_command'"

    mkdir -p "$backup_dir"/{config,data,apps}

    local sync_success=true

    # Helper: run rsync for a given source/dest pair
    _run_rsync() {
        local source="$1" dest="$2" rsync_exit
        if [[ "$ssh_auth_method" == "password" ]]; then
            SSHPASS="$ssh_pass" eval "rsync $rsync_opts '$source' '$dest'" 2>&1 | tee -a "$LOG_DIR/backup.log"
        else
            eval "rsync $rsync_opts '$source' '$dest'" 2>&1 | tee -a "$LOG_DIR/backup.log"
        fi
        rsync_exit=${PIPESTATUS[0]}
        return $rsync_exit
    }

    # Sync config directory
    log "INFO" "Syncing config directory for $server"
    if _run_rsync "$ssh_user@$ssh_host:$nextcloud_path/config/" "$backup_dir/config/"; then
        local config_files
        config_files=$(find "$backup_dir/config" -type f 2>/dev/null | wc -l)
        log "SUCCESS" "Config sync completed for $server ($config_files files)"
    else
        log "ERROR" "Config sync failed for $server"
        sync_success=false
    fi

    # Sync data directory
    log "INFO" "Syncing data directory for $server (this may take a while)"
    if _run_rsync "$ssh_user@$ssh_host:$nextcloud_path/data/" "$backup_dir/data/"; then
        local data_size
        data_size=$(du -sh "$backup_dir/data" 2>/dev/null | cut -f1)
        log "SUCCESS" "Data sync completed for $server (size: $data_size)"
    else
        log "ERROR" "Data sync failed for $server"
        sync_success=false
    fi

    # Sync apps directory
    log "INFO" "Syncing apps directory for $server"
    if _run_rsync "$ssh_user@$ssh_host:$nextcloud_path/apps/" "$backup_dir/apps/"; then
        local apps_count
        apps_count=$(find "$backup_dir/apps" -maxdepth 1 -type d 2>/dev/null | wc -l)
        log "SUCCESS" "Apps sync completed for $server ($apps_count apps)"
    else
        log "WARNING" "Apps sync failed for $server (continuing anyway)"
    fi

    if [[ "$sync_success" == "true" ]]; then
        local total_size
        total_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
        log "SUCCESS" "File synchronization completed for $server (total size: $total_size)"
        return 0
    else
        log "ERROR" "File synchronization failed for $server"
        return 1
    fi
}

create_backup_metadata() {
    local server="$1"
    local backup_dir="$2"
    local start_time="$3"

    if [[ -z "$server" || -z "$backup_dir" ]]; then
        log "ERROR" "Missing parameters for metadata creation"
        return 1
    fi

    if [[ ! -d "$backup_dir" ]]; then
        log "ERROR" "Backup directory does not exist: $backup_dir"
        return 1
    fi

    local metadata_file="$backup_dir/backup_info.txt"
    local end_time
    end_time=$(date '+%Y-%m-%d %H:%M:%S')

    log "INFO" "Creating backup metadata for $server"

    local db_files config_files data_files apps_count total_size db_size
    db_files=$(ls -la "$backup_dir"/*.sql 2>/dev/null | wc -l)
    config_files=$(find "$backup_dir/config" -type f 2>/dev/null | wc -l)
    data_files=$(find "$backup_dir/data" -type f 2>/dev/null | wc -l)
    apps_count=$(find "$backup_dir/apps" -maxdepth 1 -type d 2>/dev/null | tail -n +2 | wc -l)
    total_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)

    db_size="N/A"
    local db_file
    db_file=$(ls "$backup_dir"/*.sql 2>/dev/null | head -n1)
    [[ -f "$db_file" ]] && db_size=$(du -sh "$db_file" 2>/dev/null | cut -f1)

    local ssh_host nextcloud_path db_name
    ssh_host=$(get_server_config "$server" "ssh_host")
    nextcloud_path=$(get_server_config "$server" "nextcloud_path")
    db_name=$(get_server_config "$server" "db_name")

    cat > "$metadata_file" << EOF
Nextcloud Backup Information
============================
Server: $server
SSH Host: $ssh_host
Nextcloud Path: $nextcloud_path
Database Name: $db_name
Start Time: $start_time
End Time: $end_time
Backup Directory: $backup_dir
Script Version: $SCRIPT_VERSION

Backup Statistics:
==================
Database Files: $db_files file(s) (Size: $db_size)
Config Files: $config_files file(s)
Data Files: $data_files file(s)
Apps: $apps_count app(s)
Total Backup Size: $total_size

Backup Structure:
=================
$(find "$backup_dir" -maxdepth 2 -type d 2>/dev/null | sort)

Generated by: Nextcloud Backup Script v$SCRIPT_VERSION
Generated at: $(date '+%Y-%m-%d %H:%M:%S')
EOF

    if [[ -f "$metadata_file" ]]; then
        log "SUCCESS" "Backup metadata created successfully for $server"
        log "INFO" "Metadata file: $metadata_file"
        return 0
    else
        log "ERROR" "Failed to create backup metadata for $server"
        return 1
    fi
}

backup_server() {
    local server="$1"

    if [[ -z "$server" ]]; then
        log "ERROR" "Server name is required for backup"
        return 1
    fi

    if ! is_server_enabled "$server"; then
        log "WARNING" "Server $server is disabled, skipping"
        return 0
    fi

    local start_time
    start_time=$(date '+%Y-%m-%d %H:%M:%S')
    local backup_success=true
    local maintenance_enabled=false

    log "INFO" "Starting backup for server: $server"
    log "INFO" "Backup started at: $start_time"

    # Validate server configuration
    local ssh_host ssh_user nextcloud_path db_name
    ssh_host=$(get_server_config "$server" "ssh_host")
    ssh_user=$(get_server_config "$server" "ssh_user")
    nextcloud_path=$(get_server_config "$server" "nextcloud_path")
    db_name=$(get_server_config "$server" "db_name")

    if [[ -z "$ssh_host" || -z "$ssh_user" || -z "$nextcloud_path" || -z "$db_name" ]]; then
        log "ERROR" "Incomplete configuration for server $server"
        log "ERROR" "Required: ssh_host, ssh_user, nextcloud_path, db_name"
        return 1
    fi

    local timestamp
    timestamp=$(get_timestamp)
    local backup_dir="$BACKUP_ROOT/$server/$timestamp"

    log "INFO" "Creating backup directory: $backup_dir"
    if ! mkdir -p "$backup_dir"; then
        log "ERROR" "Failed to create backup directory: $backup_dir"
        return 1
    fi

    # Test SSH connection
    log "INFO" "Testing SSH connection to $server ($ssh_host)"
    if ! test_ssh_connection "$server"; then
        log "ERROR" "Cannot connect to $server, skipping backup"
        return 1
    fi
    log "SUCCESS" "SSH connection test passed for $server"

    # Enable maintenance mode
    log "INFO" "Enabling maintenance mode for $server"
    if enable_maintenance_mode "$server"; then
        maintenance_enabled=true
        log "SUCCESS" "Maintenance mode enabled for $server"
    else
        log "ERROR" "Failed to enable maintenance mode for $server"
        backup_success=false
    fi

    # Backup database
    log "INFO" "Starting database backup for $server"
    if backup_database "$server" "$backup_dir"; then
        log "SUCCESS" "Database backup completed for $server"
    else
        log "ERROR" "Database backup failed for $server"
        backup_success=false
    fi

    # Sync files
    log "INFO" "Starting file synchronization for $server"
    if sync_files "$server" "$backup_dir"; then
        log "SUCCESS" "File synchronization completed for $server"
    else
        log "ERROR" "File synchronization failed for $server"
        backup_success=false
    fi

    # Disable maintenance mode
    if [[ "$maintenance_enabled" == "true" ]]; then
        log "INFO" "Disabling maintenance mode for $server"
        if disable_maintenance_mode "$server"; then
            log "SUCCESS" "Maintenance mode disabled for $server"
        else
            log "WARNING" "Failed to disable maintenance mode for $server - manual intervention may be required"
        fi
    fi

    # Create backup metadata
    log "INFO" "Creating backup metadata for $server"
    if create_backup_metadata "$server" "$backup_dir" "$start_time"; then
        log "SUCCESS" "Backup metadata created for $server"
    else
        log "WARNING" "Failed to create backup metadata for $server"
    fi

    local end_time backup_size
    end_time=$(date '+%Y-%m-%d %H:%M:%S')
    backup_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)

    if [[ "$backup_success" == "true" ]]; then
        log "SUCCESS" "Backup completed successfully for $server"
        log "SUCCESS" "Backup location: $backup_dir"
        log "INFO" "Backup size: $backup_size"
        log "INFO" "Backup duration: $start_time to $end_time"
        return 0
    else
        log "ERROR" "Backup completed with errors for $server"
        log "INFO" "Partial backup location: $backup_dir"
        log "INFO" "Backup size: $backup_size"
        log "INFO" "Backup duration: $start_time to $end_time"
        return 1
    fi
}
