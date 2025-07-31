#!/bin/bash

#===============================================================================
# Simple Nextcloud Backup Script
# 
# A streamlined backup solution for Nextcloud installations using rsync and mysqldump.
# Supports multiple servers with SSH key and password authentication.
#
# Created by: RyderAsking
# Version: 1.0.0
# 
# Usage: ./nextcloud-backup.sh [command] [options]
# Commands:
#   backup [server]     - Backup specified server or all servers
#   list [server]       - List available backups
#   cleanup [server]    - Clean old backups based on retention policy
#   test [server]       - Test server connection and configuration
#   --create-config     - Generate default configuration files
#   --help              - Show this help message
#   --version           - Show version information
#===============================================================================

set -euo pipefail

# Script metadata
readonly SCRIPT_NAME="Simple Nextcloud Backup"
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_AUTHOR="RyderAsking"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration paths
readonly CONFIG_DIR="${SCRIPT_DIR}/config"
readonly MAIN_CONFIG="${CONFIG_DIR}/backup.conf"
readonly SERVERS_CONFIG="${CONFIG_DIR}/servers.conf"
readonly LOG_DIR="${SCRIPT_DIR}/logs"

# Default backup root (can be overridden by config)
BACKUP_ROOT="${SCRIPT_DIR}/backups"

# Default settings
DEFAULT_RETENTION_COUNT=7
DEFAULT_DB_PORT=3306
DEFAULT_COMPRESSION_LEVEL=6
DEFAULT_SSH_TIMEOUT=30

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Create log directory if it doesn't exist
    mkdir -p "$LOG_DIR"
    
    # Log to file
    echo "[$timestamp] [$level] $message" >> "$LOG_DIR/backup.log"
    
    # Also output to console with colors
    case "$level" in
        "INFO")  echo -e "${BLUE}[INFO]${NC} $message" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
        "WARNING") echo -e "${YELLOW}[WARNING]${NC} $message" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $message" ;;
        *) echo "[$level] $message" ;;
    esac
}

get_timestamp() {
    date '+%Y-%m-%d_%H-%M-%S'
}

#===============================================================================
# CONFIGURATION FUNCTIONS
#===============================================================================

create_default_config() {
    log "INFO" "Creating default configuration files..."
    
    mkdir -p "$CONFIG_DIR"
    
    # Create main configuration
    cat > "$MAIN_CONFIG" << 'EOF'
# Simple Nextcloud Backup Configuration
# Edit these settings according to your environment

# Backup settings
BACKUP_ROOT="./backups"
RETENTION_COUNT=7
COMPRESSION_LEVEL=6
PARALLEL_TRANSFERS=2

# SSH settings
SSH_TIMEOUT=30

# Database settings
DB_TIMEOUT=300
EOF

    # Create servers configuration template
    cat > "$SERVERS_CONFIG" << 'EOF'
# Server Configuration
# Define your Nextcloud servers here
# Format: [server_name]

# Example server configuration:
# [production]
# enabled=true
# ssh_host=nextcloud.example.com
# ssh_user=backup
# ssh_port=22
# ssh_auth_method=key                    # Options: key, password
# ssh_key=/path/to/ssh/key              # Required if ssh_auth_method=key
# ssh_pass=your_ssh_password            # Required if ssh_auth_method=password
# nextcloud_path=/var/www/nextcloud
# web_user=www-data
# db_host=localhost
# db_port=3306
# db_name=nextcloud
# db_user=nextcloud_backup
# db_pass=your_database_password
# retention_count=7

[example]
enabled=false
ssh_host=your.nextcloud.server
ssh_user=backup
ssh_port=22
ssh_auth_method=key
ssh_key=/home/backup/.ssh/id_rsa
ssh_pass=
nextcloud_path=/var/www/nextcloud
web_user=www-data
db_host=localhost
db_port=3306
db_name=nextcloud
db_user=backup_user
db_pass=your_password
retention_count=7
EOF

    log "SUCCESS" "Configuration files created in $CONFIG_DIR"
    log "INFO" "Please edit $SERVERS_CONFIG to configure your servers"
}

load_config() {
    if [[ ! -f "$MAIN_CONFIG" ]]; then
        log "ERROR" "Main configuration file not found: $MAIN_CONFIG"
        log "INFO" "Run with --create-config to generate default configuration"
        exit 1
    fi
    
    source "$MAIN_CONFIG"
    
    # Handle BACKUP_ROOT - make it absolute if it's relative
    if [[ -n "${BACKUP_ROOT:-}" ]]; then
        # If BACKUP_ROOT is relative, make it relative to script directory
        if [[ "$BACKUP_ROOT" != /* ]]; then
            BACKUP_ROOT="${SCRIPT_DIR}/${BACKUP_ROOT#./}"
        fi
    else
        BACKUP_ROOT="${SCRIPT_DIR}/backups"
    fi
    
    # Set other defaults if not specified
    RETENTION_COUNT="${RETENTION_COUNT:-$DEFAULT_RETENTION_COUNT}"
    COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-$DEFAULT_COMPRESSION_LEVEL}"
    PARALLEL_TRANSFERS="${PARALLEL_TRANSFERS:-2}"
    SSH_TIMEOUT="${SSH_TIMEOUT:-30}"
    DB_TIMEOUT="${DB_TIMEOUT:-300}"
}

get_server_config() {
    local server="$1"
    local key="$2"
    
    if [[ ! -f "$SERVERS_CONFIG" ]]; then
        log "ERROR" "Servers configuration file not found: $SERVERS_CONFIG"
        exit 1
    fi
    
    # Parse INI-style configuration and remove quotes
    local value=$(awk -F= -v server="[$server]" -v key="$key" '
        $0 == server { in_section = 1; next }
        /^\[/ { in_section = 0 }
        in_section && $1 == key { print $2; exit }
    ' "$SERVERS_CONFIG")
    
    # Remove surrounding quotes if present
    echo "$value" | sed 's/^"//; s/"$//'
}

list_servers() {
    if [[ ! -f "$SERVERS_CONFIG" ]]; then
        log "ERROR" "Servers configuration file not found: $SERVERS_CONFIG"
        exit 1
    fi
    
    grep '^\[' "$SERVERS_CONFIG" | sed 's/\[//g; s/\]//g' | grep -v '^$'
}

is_server_enabled() {
    local server="$1"
    local enabled=$(get_server_config "$server" "enabled")
    [[ "$enabled" == "true" ]]
}

#===============================================================================
# SSH AND CONNECTION FUNCTIONS
#===============================================================================

test_ssh_connection() {
    local server="$1"
    
    if [[ -z "$server" ]]; then
        log "ERROR" "Server name is required for SSH test"
        return 1
    fi
    
    local ssh_host=$(get_server_config "$server" "ssh_host")
    local ssh_user=$(get_server_config "$server" "ssh_user")
    local ssh_port=$(get_server_config "$server" "ssh_port")
    local ssh_key=$(get_server_config "$server" "ssh_key")
    local ssh_auth_method=$(get_server_config "$server" "ssh_auth_method")
    local ssh_pass=$(get_server_config "$server" "ssh_pass")
    
    ssh_port="${ssh_port:-22}"
    ssh_auth_method="${ssh_auth_method:-password}"
    
    if [[ -z "$ssh_host" || -z "$ssh_user" ]]; then
        log "ERROR" "SSH host and user are required for server $server"
        return 1
    fi
    
    log "INFO" "Testing SSH connection to $server ($ssh_user@$ssh_host:$ssh_port)"
    log "INFO" "Authentication method: $ssh_auth_method"
    
    # Build SSH command based on authentication method
    local ssh_command=""
    
    case "$ssh_auth_method" in
        "key")
            if [[ -n "$ssh_key" ]]; then
                if [[ ! -f "$ssh_key" ]]; then
                    log "ERROR" "SSH key file not found: $ssh_key"
                    return 1
                fi
                ssh_command="ssh -i '$ssh_key' -p $ssh_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=no -o ConnectTimeout=$SSH_TIMEOUT"
                log "INFO" "Using SSH key: $ssh_key"
            else
                ssh_command="ssh -p $ssh_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=no -o ConnectTimeout=$SSH_TIMEOUT"
                log "INFO" "Using default SSH key authentication"
            fi
            ;;
        "password")
            if [[ -z "$ssh_pass" ]]; then
                log "ERROR" "SSH password not specified for server $server"
                return 1
            fi
            
            # Check if sshpass is available
            if ! command -v sshpass &> /dev/null; then
                log "ERROR" "sshpass is required for password authentication but not found"
                log "ERROR" "Please install sshpass: sudo apt-get install sshpass"
                return 1
            fi
            
            # Use sshpass with environment variable to avoid shell escaping issues
            export SSHPASS="$ssh_pass"
            ssh_command="sshpass -e ssh -p $ssh_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=yes -o PubkeyAuthentication=no -o ConnectTimeout=$SSH_TIMEOUT"
            log "INFO" "Using SSH password authentication"
            ;;
        *)
            log "ERROR" "Unknown SSH authentication method: $ssh_auth_method"
            return 1
            ;;
    esac
    
    # Test SSH connection with simple command
    local test_command="echo 'SSH_TEST_OK'"
    
    log "INFO" "Attempting SSH connection..."
    log "INFO" "SSH command: $ssh_command"
    log "INFO" "Target: $ssh_user@$ssh_host"
    log "INFO" "Test command: $test_command"
    
    local ssh_output
    local exit_code
    
    # Execute SSH command with proper environment handling
    if [[ "$ssh_auth_method" == "password" ]]; then
        # For password authentication, ensure SSHPASS is available in the subshell
        ssh_output=$(SSHPASS="$ssh_pass" $ssh_command "$ssh_user@$ssh_host" "$test_command" 2>&1)
        exit_code=$?
    else
        # For key authentication
        ssh_output=$($ssh_command "$ssh_user@$ssh_host" "$test_command" 2>&1)
        exit_code=$?
    fi
    
    log "INFO" "SSH exit code: $exit_code"
    log "INFO" "SSH output: '$ssh_output'"
    
    if [[ $exit_code -eq 0 ]] && [[ "$ssh_output" == *"SSH_TEST_OK"* ]]; then
        log "SUCCESS" "SSH connection test passed for $server"
        return 0
    else
        log "ERROR" "SSH connection test failed for $server (exit code: $exit_code)"
        if [[ -n "$ssh_output" ]]; then
            log "ERROR" "SSH output: $ssh_output"
        fi
        log "ERROR" "Please verify SSH credentials and network connectivity"
        return 1
    fi
}

execute_remote_command() {
    local server="$1"
    local command="$2"
    local description="${3:-remote command}"
    
    if [[ -z "$server" || -z "$command" ]]; then
        log "ERROR" "Server and command are required for remote execution"
        return 1
    fi
    
    local ssh_host=$(get_server_config "$server" "ssh_host")
    local ssh_user=$(get_server_config "$server" "ssh_user")
    local ssh_port=$(get_server_config "$server" "ssh_port")
    local ssh_key=$(get_server_config "$server" "ssh_key")
    local ssh_auth_method=$(get_server_config "$server" "ssh_auth_method")
    local ssh_pass=$(get_server_config "$server" "ssh_pass")
    
    ssh_port="${ssh_port:-22}"
    ssh_auth_method="${ssh_auth_method:-password}"
    
    if [[ -z "$ssh_host" || -z "$ssh_user" ]]; then
        log "ERROR" "SSH host and user are required for server $server"
        return 1
    fi
    
    log "INFO" "Executing $description on $server"
    
    # Build SSH command based on authentication method
    local ssh_command=""
    
    case "$ssh_auth_method" in
        "key")
            if [[ -n "$ssh_key" ]]; then
                if [[ ! -f "$ssh_key" ]]; then
                    log "ERROR" "SSH key file not found: $ssh_key"
                    return 1
                fi
                ssh_command="ssh -i '$ssh_key' -p $ssh_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=no -o ConnectTimeout=$SSH_TIMEOUT"
            else
                ssh_command="ssh -p $ssh_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=no -o ConnectTimeout=$SSH_TIMEOUT"
            fi
            ;;
        "password")
            if [[ -z "$ssh_pass" ]]; then
                log "ERROR" "SSH password not specified for server $server"
                return 1
            fi
            
            # Check if sshpass is available
            if ! command -v sshpass &> /dev/null; then
                log "ERROR" "sshpass is required for password authentication but not found"
                log "ERROR" "Please install sshpass: sudo apt-get install sshpass"
                return 1
            fi
            
            # Use sshpass with environment variable to avoid shell escaping issues
            export SSHPASS="$ssh_pass"
            ssh_command="sshpass -e ssh -p $ssh_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=yes -o PubkeyAuthentication=no -o ConnectTimeout=$SSH_TIMEOUT"
            ;;
        *)
            log "ERROR" "Unknown SSH authentication method: $ssh_auth_method"
            return 1
            ;;
    esac
    
    # Execute the remote command
    local output
    local exit_code
    
    # Execute SSH command with proper environment handling
    if [[ "$ssh_auth_method" == "password" ]]; then
        # For password authentication, ensure SSHPASS is available in the subshell
        output=$(SSHPASS="$ssh_pass" $ssh_command "$ssh_user@$ssh_host" "$command" 2>&1)
        exit_code=$?
    else
        # For key authentication
        output=$($ssh_command "$ssh_user@$ssh_host" "$command" 2>&1)
        exit_code=$?
    fi
    
    if [[ $exit_code -eq 0 ]]; then
        log "SUCCESS" "Remote command executed successfully on $server"
        if [[ -n "$output" ]]; then
            log "INFO" "Command output: $output"
        fi
        return 0
    else
        log "ERROR" "Remote command failed on $server (exit code: $exit_code)"
        if [[ -n "$output" ]]; then
            log "ERROR" "Command output: $output"
        fi
        return 1
    fi
}

#===============================================================================
# BACKUP FUNCTIONS
#===============================================================================

enable_maintenance_mode() {
    local server="$1"
    
    if [[ -z "$server" ]]; then
        log "ERROR" "Server name is required for maintenance mode"
        return 1
    fi
    
    local nextcloud_path=$(get_server_config "$server" "nextcloud_path")
    
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
    
    local nextcloud_path=$(get_server_config "$server" "nextcloud_path")
    
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
    
    local db_host=$(get_server_config "$server" "db_host")
    local db_port=$(get_server_config "$server" "db_port")
    local db_name=$(get_server_config "$server" "db_name")
    local db_user=$(get_server_config "$server" "db_user")
    local db_pass=$(get_server_config "$server" "db_pass")
    local ssh_host=$(get_server_config "$server" "ssh_host")
    local ssh_user=$(get_server_config "$server" "ssh_user")
    local ssh_port=$(get_server_config "$server" "ssh_port")
    local ssh_auth_method=$(get_server_config "$server" "ssh_auth_method")
    local ssh_key=$(get_server_config "$server" "ssh_key")
    local ssh_pass=$(get_server_config "$server" "ssh_pass")
    
    # Validate database configuration
    if [[ -z "$db_host" ]]; then
        log "ERROR" "Database host not configured for server $server"
        return 1
    fi
    
    if [[ -z "$db_name" ]]; then
        log "ERROR" "Database name not configured for server $server"
        return 1
    fi
    
    if [[ -z "$db_user" ]]; then
        log "ERROR" "Database user not configured for server $server"
        return 1
    fi
    
    if [[ -z "$db_pass" ]]; then
        log "ERROR" "Database password not configured for server $server"
        return 1
    fi
    
    if [[ -z "$ssh_host" || -z "$ssh_user" ]]; then
        log "ERROR" "SSH configuration incomplete for server $server"
        return 1
    fi
    
    db_port="${db_port:-$DEFAULT_DB_PORT}"
    ssh_port="${ssh_port:-22}"
    ssh_auth_method="${ssh_auth_method:-password}"
    
    log "INFO" "Backing up database for $server (host: $db_host, database: $db_name)"
    
    local dump_file="$backup_dir/database.sql"
    local dump_command="timeout $DB_TIMEOUT mysqldump -h $db_host -P $db_port -u $db_user -p'$db_pass' --single-transaction --routines --triggers --add-drop-table --create-options --disable-keys --extended-insert --quick --lock-tables=false $db_name"
    
    # Create backup directory if it doesn't exist
    mkdir -p "$backup_dir"
    
    log "INFO" "Starting database dump to $dump_file"
    
    # Build SSH command based on authentication method
    local ssh_command=""
    
    case "$ssh_auth_method" in
        "key")
            if [[ -n "$ssh_key" ]]; then
                if [[ ! -f "$ssh_key" ]]; then
                    log "ERROR" "SSH key file not found: $ssh_key"
                    return 1
                fi
                ssh_command="ssh -i '$ssh_key' -p $ssh_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=no"
            else
                ssh_command="ssh -p $ssh_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=no"
            fi
            ;;
        "password")
            if [[ -z "$ssh_pass" ]]; then
                log "ERROR" "SSH password not specified for server $server"
                return 1
            fi
            
            # Check if sshpass is available
            if ! command -v sshpass &> /dev/null; then
                log "ERROR" "sshpass is required for password authentication but not found"
                log "ERROR" "Please install sshpass: sudo apt-get install sshpass"
                return 1
            fi
            
            # Use sshpass with environment variable to avoid shell escaping issues
            export SSHPASS="$ssh_pass"
            ssh_command="sshpass -e ssh -p $ssh_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=yes -o PubkeyAuthentication=no"
            ;;
        *)
            log "ERROR" "Unknown SSH authentication method: $ssh_auth_method"
            return 1
            ;;
    esac
    
    # Execute mysqldump remotely and save to local file
    local dump_success=false
    
    if [[ "$ssh_auth_method" == "password" ]]; then
        # For password authentication, ensure SSHPASS is available
        if SSHPASS="$ssh_pass" $ssh_command "$ssh_user@$ssh_host" "$dump_command" > "$dump_file" 2>/dev/null; then
            dump_success=true
        fi
    else
        # For key authentication
        if $ssh_command "$ssh_user@$ssh_host" "$dump_command" > "$dump_file" 2>/dev/null; then
            dump_success=true
        fi
    fi
    
    if [[ "$dump_success" == "true" ]]; then
        if [[ -s "$dump_file" ]]; then
            local file_size=$(du -h "$dump_file" | cut -f1)
            local line_count=$(wc -l < "$dump_file")
            log "SUCCESS" "Database backup completed for $server (size: $file_size, lines: $line_count)"
            
            # Basic validation of dump file
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
    
    local ssh_host=$(get_server_config "$server" "ssh_host")
    local ssh_user=$(get_server_config "$server" "ssh_user")
    local ssh_port=$(get_server_config "$server" "ssh_port")
    local ssh_key=$(get_server_config "$server" "ssh_key")
    local ssh_auth_method=$(get_server_config "$server" "ssh_auth_method")
    local ssh_pass=$(get_server_config "$server" "ssh_pass")
    local nextcloud_path=$(get_server_config "$server" "nextcloud_path")
    
    ssh_port="${ssh_port:-22}"
    ssh_auth_method="${ssh_auth_method:-password}"
    
    if [[ -z "$ssh_host" || -z "$ssh_user" || -z "$nextcloud_path" ]]; then
        log "ERROR" "SSH and Nextcloud configuration incomplete for server $server"
        return 1
    fi
    
    log "INFO" "Starting file synchronization for $server"
    log "INFO" "Source: $ssh_user@$ssh_host:$nextcloud_path"
    log "INFO" "Destination: $backup_dir"
    
    # Build SSH command for rsync based on authentication method
    local ssh_command=""
    
    case "$ssh_auth_method" in
        "key")
            if [[ -n "$ssh_key" ]]; then
                if [[ ! -f "$ssh_key" ]]; then
                    log "ERROR" "SSH key file not found: $ssh_key"
                    return 1
                fi
                ssh_command="ssh -i '$ssh_key' -p $ssh_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=no"
            else
                ssh_command="ssh -p $ssh_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=no"
            fi
            ;;
        "password")
            if [[ -z "$ssh_pass" ]]; then
                log "ERROR" "SSH password not specified for server $server"
                return 1
            fi
            
            # Check if sshpass is available
            if ! command -v sshpass &> /dev/null; then
                log "ERROR" "sshpass is required for password authentication but not found"
                log "ERROR" "Please install sshpass: sudo apt-get install sshpass"
                return 1
            fi
            
            ssh_command="sshpass -e ssh -p $ssh_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=yes -o PubkeyAuthentication=no"
            ;;
        *)
            log "ERROR" "Unknown SSH authentication method: $ssh_auth_method"
            return 1
            ;;
    esac
    
    # Build rsync options
    local rsync_opts="-avz --compress-level=$COMPRESSION_LEVEL --delete --stats"
    rsync_opts="$rsync_opts --exclude=data/*/cache --exclude=data/*/thumbnails --exclude=data/*/files_trashbin"
    rsync_opts="$rsync_opts --exclude=data/*/files_versions --exclude=data/appdata_*/preview"
    rsync_opts="$rsync_opts -e '$ssh_command'"
    
    # Create backup directories
    mkdir -p "$backup_dir"/{config,data,apps}
    
    local sync_success=true
    
    # Sync config directory
    log "INFO" "Syncing config directory for $server"
    local config_source="$ssh_user@$ssh_host:$nextcloud_path/config/"
    local config_dest="$backup_dir/config/"
    
    if [[ "$ssh_auth_method" == "password" ]]; then
        if SSHPASS="$ssh_pass" eval "rsync $rsync_opts '$config_source' '$config_dest'" 2>&1 | tee -a "$LOG_DIR/backup.log"; then
            local config_files=$(find "$backup_dir/config" -type f 2>/dev/null | wc -l)
            log "SUCCESS" "Config sync completed for $server ($config_files files)"
        else
            log "ERROR" "Config sync failed for $server"
            sync_success=false
        fi
    else
        if eval "rsync $rsync_opts '$config_source' '$config_dest'" 2>&1 | tee -a "$LOG_DIR/backup.log"; then
            local config_files=$(find "$backup_dir/config" -type f 2>/dev/null | wc -l)
            log "SUCCESS" "Config sync completed for $server ($config_files files)"
        else
            log "ERROR" "Config sync failed for $server"
            sync_success=false
        fi
    fi
    
    # Sync data directory
    log "INFO" "Syncing data directory for $server (this may take a while)"
    local data_source="$ssh_user@$ssh_host:$nextcloud_path/data/"
    local data_dest="$backup_dir/data/"
    
    if [[ "$ssh_auth_method" == "password" ]]; then
        if SSHPASS="$ssh_pass" eval "rsync $rsync_opts '$data_source' '$data_dest'" 2>&1 | tee -a "$LOG_DIR/backup.log"; then
            local data_size=$(du -sh "$backup_dir/data" 2>/dev/null | cut -f1)
            log "SUCCESS" "Data sync completed for $server (size: $data_size)"
        else
            log "ERROR" "Data sync failed for $server"
            sync_success=false
        fi
    else
        if eval "rsync $rsync_opts '$data_source' '$data_dest'" 2>&1 | tee -a "$LOG_DIR/backup.log"; then
            local data_size=$(du -sh "$backup_dir/data" 2>/dev/null | cut -f1)
            log "SUCCESS" "Data sync completed for $server (size: $data_size)"
        else
            log "ERROR" "Data sync failed for $server"
            sync_success=false
        fi
    fi
    
    # Sync apps directory
    log "INFO" "Syncing apps directory for $server"
    local apps_source="$ssh_user@$ssh_host:$nextcloud_path/apps/"
    local apps_dest="$backup_dir/apps/"
    
    if [[ "$ssh_auth_method" == "password" ]]; then
        if SSHPASS="$ssh_pass" eval "rsync $rsync_opts '$apps_source' '$apps_dest'" 2>&1 | tee -a "$LOG_DIR/backup.log"; then
            local apps_count=$(find "$backup_dir/apps" -maxdepth 1 -type d 2>/dev/null | wc -l)
            log "SUCCESS" "Apps sync completed for $server ($apps_count apps)"
        else
            log "WARNING" "Apps sync failed for $server (continuing anyway)"
            # Don't fail the entire backup for apps sync failure
        fi
    else
        if eval "rsync $rsync_opts '$apps_source' '$apps_dest'" 2>&1 | tee -a "$LOG_DIR/backup.log"; then
            local apps_count=$(find "$backup_dir/apps" -maxdepth 1 -type d 2>/dev/null | wc -l)
            log "SUCCESS" "Apps sync completed for $server ($apps_count apps)"
        else
            log "WARNING" "Apps sync failed for $server (continuing anyway)"
            # Don't fail the entire backup for apps sync failure
        fi
    fi
    
    if [[ "$sync_success" == "true" ]]; then
        local total_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
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
    local end_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    log "INFO" "Creating backup metadata for $server"
    
    # Gather backup statistics
    local db_files=$(ls -la "$backup_dir"/*.sql 2>/dev/null | wc -l)
    local config_files=$(find "$backup_dir/config" -type f 2>/dev/null | wc -l)
    local data_files=$(find "$backup_dir/data" -type f 2>/dev/null | wc -l)
    local apps_count=$(find "$backup_dir/apps" -maxdepth 1 -type d 2>/dev/null | tail -n +2 | wc -l)
    local total_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
    
    # Get database file size if exists
    local db_size="N/A"
    local db_file=$(ls "$backup_dir"/*.sql 2>/dev/null | head -n1)
    if [[ -f "$db_file" ]]; then
        db_size=$(du -sh "$db_file" 2>/dev/null | cut -f1)
    fi
    
    # Get server configuration for metadata
    local ssh_host=$(get_server_config "$server" "ssh_host")
    local nextcloud_path=$(get_server_config "$server" "nextcloud_path")
    local db_name=$(get_server_config "$server" "db_name")
    
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

    if [[ ! -f "$metadata_file" ]]; then
        log "ERROR" "Failed to create metadata file: $metadata_file"
        return 1
    fi
    
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
    
    local start_time=$(date '+%Y-%m-%d %H:%M:%S')
    local backup_success=true
    local maintenance_enabled=false
    
    log "INFO" "Starting backup for server: $server"
    log "INFO" "Backup started at: $start_time"
    
    # Validate server configuration
    local ssh_host=$(get_server_config "$server" "ssh_host")
    local ssh_user=$(get_server_config "$server" "ssh_user")
    local nextcloud_path=$(get_server_config "$server" "nextcloud_path")
    local db_name=$(get_server_config "$server" "db_name")
    
    if [[ -z "$ssh_host" || -z "$ssh_user" || -z "$nextcloud_path" || -z "$db_name" ]]; then
        log "ERROR" "Incomplete configuration for server $server"
        log "ERROR" "Required: ssh_host, ssh_user, nextcloud_path, db_name"
        return 1
    fi
    
    local timestamp=$(get_timestamp)
    local backup_dir="$BACKUP_ROOT/$server/$timestamp"
    
    # Create backup directory
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
    
    # Backup database (continue even if maintenance mode failed)
    log "INFO" "Starting database backup for $server"
    if backup_database "$server" "$backup_dir"; then
        log "SUCCESS" "Database backup completed for $server"
    else
        log "ERROR" "Database backup failed for $server"
        backup_success=false
    fi
    
    # Sync files (continue even if database backup failed)
    log "INFO" "Starting file synchronization for $server"
    if sync_files "$server" "$backup_dir"; then
        log "SUCCESS" "File synchronization completed for $server"
    else
        log "ERROR" "File synchronization failed for $server"
        backup_success=false
    fi
    
    # Disable maintenance mode if it was enabled
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
    
    local end_time=$(date '+%Y-%m-%d %H:%M:%S')
    local backup_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
    
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

#===============================================================================
# CLEANUP FUNCTIONS
#===============================================================================

cleanup_old_backups() {
    local server="$1"
    local retention_count=$(get_server_config "$server" "retention_count")
    retention_count="${retention_count:-$RETENTION_COUNT}"
    
    if [[ -z "$server" ]]; then
        log "ERROR" "Server name is required for cleanup"
        return 1
    fi
    
    local server_backup_dir="$BACKUP_ROOT/$server"
    
    if [[ ! -d "$server_backup_dir" ]]; then
        log "WARNING" "No backup directory found for server $server: $server_backup_dir"
        return 0
    fi
    
    log "INFO" "Starting cleanup for server $server (keeping $retention_count backups)"
    
    # Get list of backup directories sorted by date (oldest first)
    local backup_dirs=($(find "$server_backup_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort))
    local total_backups=${#backup_dirs[@]}
    
    if [[ $total_backups -eq 0 ]]; then
        log "INFO" "No backups found for server $server"
        return 0
    fi
    
    log "INFO" "Found $total_backups backup(s) for server $server"
    
    if [[ $total_backups -le $retention_count ]]; then
        log "INFO" "Current backup count ($total_backups) is within retention limit ($retention_count), no cleanup needed"
        return 0
    fi
    
    local backups_to_remove=$((total_backups - retention_count))
    local removed_count=0
    local failed_count=0
    
    log "INFO" "Need to remove $backups_to_remove old backup(s)"
    
    # Remove oldest backups
    for ((i=0; i<backups_to_remove; i++)); do
        local backup_dir="${backup_dirs[$i]}"
        local backup_name=$(basename "$backup_dir")
        local backup_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
        
        log "INFO" "Removing old backup: $backup_name (size: $backup_size)"
        
        if rm -rf "$backup_dir" 2>/dev/null; then
            log "SUCCESS" "Removed backup: $backup_name"
            ((removed_count++))
        else
            log "ERROR" "Failed to remove backup: $backup_name"
            ((failed_count++))
        fi
    done
    
    # Summary
    if [[ $failed_count -eq 0 ]]; then
        log "SUCCESS" "Cleanup completed for server $server: removed $removed_count backup(s)"
        log "INFO" "Remaining backups: $((total_backups - removed_count))"
        return 0
    else
        log "WARNING" "Cleanup completed with errors for server $server: removed $removed_count, failed $failed_count"
        return 1
    fi
}

#===============================================================================
# LIST FUNCTIONS
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
    local backup_dirs=($(find "$server_backup_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort -r))
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
        local backup_name=$(basename "$backup_dir")
        local backup_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
        local backup_date=""
        local backup_time=""
        local db_status="No"
        local backup_status="Incomplete"
        
        # Parse backup name (format: YYYYMMDD_HHMMSS)
        if [[ $backup_name =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
            backup_date="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
            backup_time="${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
        else
            backup_date="$backup_name"
            backup_time=""
        fi
        
        # Check for database backup
        if ls "$backup_dir"/*.sql >/dev/null 2>&1; then
            local db_file=$(ls "$backup_dir"/*.sql 2>/dev/null | head -n1)
            local db_size=$(du -sh "$db_file" 2>/dev/null | cut -f1)
            db_status="Yes ($db_size)"
        fi
        
        # Check backup completeness
        if [[ -f "$backup_dir/backup_info.txt" ]] && [[ -d "$backup_dir/config" ]] && [[ -d "$backup_dir/data" ]]; then
            backup_status="Complete"
            ((valid_backups++))
        else
            backup_status="Incomplete"
            ((invalid_backups++))
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

#===============================================================================
# MAIN FUNCTIONS
#===============================================================================

show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Usage: $0 [command] [options]

Commands:
  backup [server|all]     Backup specified server or all enabled servers
  list [server]           List available backups for server
  cleanup [server|all]    Clean old backups for server or all servers
  test [server|all]       Test server connection and configuration
  --create-config         Generate default configuration files
  --help                  Show this help message
  --version               Show version information

Examples:
  $0 --create-config      # Create default configuration
  $0 backup all           # Backup all enabled servers
  $0 backup production    # Backup specific server
  $0 list production      # List backups for server
  $0 cleanup all          # Clean old backups for all servers
  $0 test production      # Test server connection

Configuration:
  Edit $SERVERS_CONFIG to configure your servers
  Edit $MAIN_CONFIG for global settings

EOF
}

show_version() {
    echo "$SCRIPT_NAME v$SCRIPT_VERSION"
}

main() {
    # Handle special arguments first
    case "${1:-}" in
        "--create-config")
            create_default_config
            exit 0
            ;;
        "--help"|"-h")
            show_help
            exit 0
            ;;
        "--version"|"-v")
            show_version
            exit 0
            ;;
    esac
    
    # Load configuration
    load_config
    
    # Ensure backup root exists
    mkdir -p "$BACKUP_ROOT"
    
    local command="${1:-}"
    local target="${2:-}"
    
    case "$command" in
        "backup")
            if [[ "$target" == "all" || -z "$target" ]]; then
                log "INFO" "Starting backup for all enabled servers"
                local servers=($(list_servers))
                for server in "${servers[@]}"; do
                    if is_server_enabled "$server"; then
                        backup_server "$server"
                    fi
                done
            else
                backup_server "$target"
            fi
            ;;
        "list")
            if [[ -z "$target" ]]; then
                log "ERROR" "Please specify a server name"
                exit 1
            fi
            list_backups "$target"
            ;;
        "cleanup")
            if [[ "$target" == "all" || -z "$target" ]]; then
                log "INFO" "Cleaning up old backups for all servers"
                local servers=($(list_servers))
                for server in "${servers[@]}"; do
                    cleanup_old_backups "$server"
                done
            else
                cleanup_old_backups "$target"
            fi
            ;;
        "test")
            if [[ "$target" == "all" || -z "$target" ]]; then
                log "INFO" "Testing all enabled servers"
                local servers=($(list_servers))
                for server in "${servers[@]}"; do
                    if is_server_enabled "$server"; then
                        test_ssh_connection "$server"
                    fi
                done
            else
                test_ssh_connection "$target"
            fi
            ;;
        *)
            log "ERROR" "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"