#!/bin/bash

#===============================================================================
# Configuration Functions
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
