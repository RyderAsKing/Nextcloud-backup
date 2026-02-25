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

# Source library modules
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/ssh.sh"
source "${SCRIPT_DIR}/lib/backup.sh"
source "${SCRIPT_DIR}/lib/cleanup.sh"
source "${SCRIPT_DIR}/lib/list.sh"

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
    # Handle special arguments first (before loading config)
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
                local servers
                mapfile -t servers < <(list_servers)
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
                local servers
                mapfile -t servers < <(list_servers)
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
                local servers
                mapfile -t servers < <(list_servers)
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