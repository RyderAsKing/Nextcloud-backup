#!/bin/bash

#===============================================================================
# SSH and Connection Functions
#===============================================================================

# Outputs the SSH command prefix to stdout; also exports SSHPASS when needed.
# Usage: build_ssh_command <server>
# Returns non-zero on configuration error.
build_ssh_command() {
    local server="$1"

    local ssh_host ssh_user ssh_port ssh_key ssh_auth_method ssh_pass
    ssh_host=$(get_server_config "$server" "ssh_host")
    ssh_user=$(get_server_config "$server" "ssh_user")
    ssh_port=$(get_server_config "$server" "ssh_port")
    ssh_key=$(get_server_config "$server" "ssh_key")
    ssh_auth_method=$(get_server_config "$server" "ssh_auth_method")
    ssh_pass=$(get_server_config "$server" "ssh_pass")

    ssh_port="${ssh_port:-22}"
    ssh_auth_method="${ssh_auth_method:-password}"

    if [[ -z "$ssh_host" || -z "$ssh_user" ]]; then
        log "ERROR" "SSH host and user are required for server $server"
        return 1
    fi

    case "$ssh_auth_method" in
        "key")
            local key_opts=""
            if [[ -n "$ssh_key" ]]; then
                if [[ ! -f "$ssh_key" ]]; then
                    log "ERROR" "SSH key file not found: $ssh_key"
                    return 1
                fi
                key_opts="-i '$ssh_key' "
                log "INFO" "Using SSH key: $ssh_key"
            else
                log "INFO" "Using default SSH key authentication"
            fi
            echo "ssh ${key_opts}-p $ssh_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=no -o ConnectTimeout=$SSH_TIMEOUT"
            ;;
        "password")
            if [[ -z "$ssh_pass" ]]; then
                log "ERROR" "SSH password not specified for server $server"
                return 1
            fi
            if ! command -v sshpass &> /dev/null; then
                log "ERROR" "sshpass is required for password authentication but not found"
                log "ERROR" "Please install sshpass: sudo apt-get install sshpass"
                return 1
            fi
            log "INFO" "Using SSH password authentication"
            echo "sshpass -e ssh -p $ssh_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=yes -o PubkeyAuthentication=no -o ConnectTimeout=$SSH_TIMEOUT"
            ;;
        *)
            log "ERROR" "Unknown SSH authentication method: $ssh_auth_method"
            return 1
            ;;
    esac
}

test_ssh_connection() {
    local server="$1"

    if [[ -z "$server" ]]; then
        log "ERROR" "Server name is required for SSH test"
        return 1
    fi

    local ssh_host ssh_user ssh_port ssh_auth_method ssh_pass
    ssh_host=$(get_server_config "$server" "ssh_host")
    ssh_user=$(get_server_config "$server" "ssh_user")
    ssh_port=$(get_server_config "$server" "ssh_port")
    ssh_auth_method=$(get_server_config "$server" "ssh_auth_method")
    ssh_pass=$(get_server_config "$server" "ssh_pass")

    ssh_port="${ssh_port:-22}"
    ssh_auth_method="${ssh_auth_method:-password}"

    log "INFO" "Testing SSH connection to $server ($ssh_user@$ssh_host:$ssh_port)"
    log "INFO" "Authentication method: $ssh_auth_method"

    local ssh_command
    ssh_command=$(build_ssh_command "$server") || return 1

    log "INFO" "Attempting SSH connection..."

    local ssh_output exit_code
    if [[ "$ssh_auth_method" == "password" ]]; then
        ssh_output=$(SSHPASS="$ssh_pass" $ssh_command "$ssh_user@$ssh_host" "echo 'SSH_TEST_OK'" 2>&1)
        exit_code=$?
    else
        ssh_output=$($ssh_command "$ssh_user@$ssh_host" "echo 'SSH_TEST_OK'" 2>&1)
        exit_code=$?
    fi

    log "INFO" "SSH exit code: $exit_code"
    log "INFO" "SSH output: '$ssh_output'"

    if [[ $exit_code -eq 0 ]] && [[ "$ssh_output" == *"SSH_TEST_OK"* ]]; then
        log "SUCCESS" "SSH connection test passed for $server"
        return 0
    else
        log "ERROR" "SSH connection test failed for $server (exit code: $exit_code)"
        [[ -n "$ssh_output" ]] && log "ERROR" "SSH output: $ssh_output"
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

    local ssh_host ssh_user ssh_auth_method ssh_pass
    ssh_host=$(get_server_config "$server" "ssh_host")
    ssh_user=$(get_server_config "$server" "ssh_user")
    ssh_auth_method=$(get_server_config "$server" "ssh_auth_method")
    ssh_pass=$(get_server_config "$server" "ssh_pass")

    ssh_auth_method="${ssh_auth_method:-password}"

    log "INFO" "Executing $description on $server"

    local ssh_command
    ssh_command=$(build_ssh_command "$server") || return 1

    local output exit_code
    if [[ "$ssh_auth_method" == "password" ]]; then
        output=$(SSHPASS="$ssh_pass" $ssh_command "$ssh_user@$ssh_host" "$command" 2>&1)
        exit_code=$?
    else
        output=$($ssh_command "$ssh_user@$ssh_host" "$command" 2>&1)
        exit_code=$?
    fi

    if [[ $exit_code -eq 0 ]]; then
        log "SUCCESS" "Remote command executed successfully on $server"
        [[ -n "$output" ]] && log "INFO" "Command output: $output"
        return 0
    else
        log "ERROR" "Remote command failed on $server (exit code: $exit_code)"
        [[ -n "$output" ]] && log "ERROR" "Command output: $output"
        return 1
    fi
}
