# Simple Nextcloud Backup Script

A streamlined backup solution for Nextcloud installations using rsync and mysqldump. Supports multiple servers with both SSH key and password authentication.

## Features

- **Simple & Lightweight**: Single script with minimal dependencies
- **Multi-Server Support**: Backup multiple Nextcloud instances
- **Dual SSH Authentication**: Both SSH key and password authentication supported
- **Database Backup**: MySQL/MariaDB dump with single-transaction consistency
- **File Synchronization**: Efficient rsync-based file backup
- **Maintenance Mode**: Automatic maintenance mode during backup
- **Retention Management**: Configurable backup retention policies
- **Logging**: Comprehensive logging with colored console output

## Quick Start

1. **Download the script**:

   ```bash
   wget https://raw.githubusercontent.com/RyderAsKing/Nextcloud-backup/refs/heads/main/nextcloud-backup.sh
   chmod +x nextcloud-backup.sh
   ```

2. **Generate configuration**:

   ```bash
   ./nextcloud-backup.sh --create-config
   ```

3. **Edit server configuration**:

   ```bash
   nano config/servers.conf
   ```

4. **Test connection**:

   ```bash
   ./nextcloud-backup.sh test your-server
   ```

5. **Run backup**:
   ```bash
   ./nextcloud-backup.sh backup your-server
   ```

## Installation

### Prerequisites

- **Local System**: `rsync`, `ssh`, `mysql` client
- **For Password Authentication**: `sshpass` package
- **Remote Server**: SSH access, `mysqldump`, `rsync`, Nextcloud with OCC command

### Setup

1. **Clone or download the script**:

   ```bash
   git clone https://github.com/RyderAsKing/Nextcloud-backup.git
   cd nextcloud-backup
   ```

2. **Make script executable**:

   ```bash
   chmod +x nextcloud-backup.sh
   ```

3. **Install sshpass (for password authentication)**:

   ```bash
   # Ubuntu/Debian
   sudo apt-get install sshpass

   # CentOS/RHEL
   sudo yum install sshpass

   # macOS
   brew install hudochenkov/sshpass/sshpass
   ```

4. **Generate default configuration**:
   ```bash
   ./nextcloud-backup.sh --create-config
   ```

## Configuration

### Main Configuration (`config/backup.conf`)

```bash
# Backup settings
BACKUP_ROOT="./backups"          # Where to store backups
RETENTION_COUNT=7                # Number of backups to keep
COMPRESSION_LEVEL=6              # Compression level (1-9)
PARALLEL_TRANSFERS=2             # Parallel rsync transfers

# SSH settings
SSH_TIMEOUT=30                   # SSH connection timeout

# Database settings
DB_TIMEOUT=300                   # Database dump timeout
```

### Server Configuration (`config/servers.conf`)

#### SSH Key Authentication Example

```ini
[production]
enabled=true
ssh_host=nextcloud.example.com
ssh_user=backup
ssh_port=22
ssh_auth_method=key
ssh_key=/home/backup/.ssh/id_rsa
nextcloud_path=/var/www/nextcloud
web_user=www-data
db_host=localhost
db_port=3306
db_name=nextcloud
db_user=backup_user
db_pass=your_password
retention_count=7
```

#### SSH Password Authentication Example

```ini
[production]
enabled=true
ssh_host=nextcloud.example.com
ssh_user=backup
ssh_port=22
ssh_auth_method=password
ssh_pass="your_ssh_password"
nextcloud_path=/var/www/nextcloud
web_user=www-data
db_host=localhost
db_port=3306
db_name=nextcloud
db_user=backup_user
db_pass="your_database_password"
retention_count=7
```

**Important Notes:**

- Passwords can be enclosed in quotes to handle special characters
- The script automatically removes surrounding quotes from configuration values
- Use `ssh_auth_method=key` for SSH key authentication
- Use `ssh_auth_method=password` for password authentication

## Usage

### Commands

```bash
# Backup commands
./nextcloud-backup.sh backup all           # Backup all enabled servers
./nextcloud-backup.sh backup production    # Backup specific server

# List backups
./nextcloud-backup.sh list production      # List backups for server

# Cleanup old backups
./nextcloud-backup.sh cleanup all          # Clean all servers
./nextcloud-backup.sh cleanup production   # Clean specific server

# Test connections
./nextcloud-backup.sh test all             # Test all enabled servers
./nextcloud-backup.sh test production      # Test specific server

# Configuration
./nextcloud-backup.sh --create-config      # Generate default config
./nextcloud-backup.sh --help               # Show help
./nextcloud-backup.sh --version            # Show version
```

### Examples

**Daily backup of all servers**:

```bash
./nextcloud-backup.sh backup all
```

**Backup specific server with verbose output**:

```bash
./nextcloud-backup.sh backup production 2>&1 | tee backup.log
```

**Clean old backups (keep only latest 5)**:

```bash
# Edit retention_count=5 in servers.conf, then:
./nextcloud-backup.sh cleanup production
```

## SSH Authentication Setup

### Option 1: SSH Key Authentication (Recommended)

1. **Generate SSH key pair** (if not exists):

   ```bash
   ssh-keygen -t rsa -b 4096 -f ~/.ssh/nextcloud_backup
   ```

2. **Copy public key to server**:

   ```bash
   ssh-copy-id -i ~/.ssh/nextcloud_backup.pub backup@nextcloud.example.com
   ```

3. **Test connection**:

   ```bash
   ssh -i ~/.ssh/nextcloud_backup backup@nextcloud.example.com "echo 'Connection successful'"
   ```

4. **Update configuration**:
   ```ini
   ssh_auth_method=key
   ssh_key=/home/backup/.ssh/nextcloud_backup
   ```

### Option 2: SSH Password Authentication

1. **Install sshpass**:

   ```bash
   sudo apt-get install sshpass
   ```

2. **Update configuration**:

   ```ini
   ssh_auth_method=password
   ssh_pass="your_ssh_password"
   ```

3. **Test connection**:
   ```bash
   ./nextcloud-backup.sh test your-server
   ```

## Backup Process

The script performs the following steps:

1. **Pre-backup checks**:

   - Verify SSH connection
   - Check server configuration

2. **Enable maintenance mode**:

   - Put Nextcloud in maintenance mode
   - Prevent user access during backup

3. **Database backup**:

   - Create consistent database dump
   - Use single-transaction for InnoDB

4. **File synchronization**:

   - Sync config directory
   - Sync data directory (excluding cache/thumbnails)
   - Sync apps directory

5. **Post-backup tasks**:

   - Disable maintenance mode
   - Create backup metadata
   - Log backup completion

6. **Cleanup**:
   - Remove old backups based on retention policy

## Backup Structure

```
backups/
├── production/
│   ├── 2025-01-20_14-30-15/
│   │   ├── database.sql
│   │   ├── config/
│   │   ├── data/
│   │   ├── apps/
│   │   └── backup_info.txt
│   └── 2025-01-19_14-30-10/
│       └── ...
└── development/
    └── ...
```

## Scheduling

### Using Cron

Add to crontab (`crontab -e`):

```bash
# Daily backup at 2 AM
0 2 * * * /path/to/nextcloud-backup.sh backup all >> /var/log/nextcloud-backup.log 2>&1

# Weekly cleanup on Sunday at 3 AM
0 3 * * 0 /path/to/nextcloud-backup.sh cleanup all >> /var/log/nextcloud-backup.log 2>&1
```

### Using Systemd

Create service file `/etc/systemd/system/nextcloud-backup.service`:

```ini
[Unit]
Description=Nextcloud Backup
After=network.target

[Service]
Type=oneshot
User=backup
ExecStart=/path/to/nextcloud-backup.sh backup all
```

Create timer file `/etc/systemd/system/nextcloud-backup.timer`:

```ini
[Unit]
Description=Run Nextcloud Backup Daily
Requires=nextcloud-backup.service

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

Enable and start:

```bash
sudo systemctl enable nextcloud-backup.timer
sudo systemctl start nextcloud-backup.timer
```

## Troubleshooting

### Common Issues

**SSH Connection Failed**:

- **For Key Authentication**:
  - Verify SSH key permissions: `chmod 600 ~/.ssh/nextcloud_backup`
  - Test manual SSH connection
  - Check firewall settings
- **For Password Authentication**:
  - Ensure `sshpass` is installed
  - Verify password is correct and properly quoted in config
  - Check if server allows password authentication

**Database Backup Failed**:

- Verify database credentials
- Check database user permissions
- Ensure mysqldump is available on remote server

**File Sync Failed**:

- Check disk space on backup destination
- Verify rsync is available on both systems
- Check file permissions on Nextcloud directories

**Maintenance Mode Issues**:

- Verify web user configuration
- Check Nextcloud OCC command availability
- Ensure proper sudo permissions

### Log Files

Logs are stored in `logs/backup.log`:

```bash
# View recent logs
tail -f logs/backup.log

# Search for errors
grep ERROR logs/backup.log

# View specific server logs
grep "production" logs/backup.log
```

## Security Considerations

- **SSH Keys**: Use dedicated SSH keys with restricted permissions (recommended)
- **Passwords**: Store in configuration files with restricted access (`chmod 600`)
- **File Permissions**: Ensure backup files are not world-readable
- **Network Security**: Prefer SSH key authentication over passwords
- **Backup Storage**: Consider encrypting backup storage location

## Performance Optimization

- **Parallel Transfers**: Adjust `PARALLEL_TRANSFERS` based on network capacity
- **Compression**: Balance `COMPRESSION_LEVEL` vs CPU usage
- **Excludes**: Add custom excludes for large unnecessary files
- **Network**: Use `--bwlimit` in rsync for bandwidth limiting
- **Storage**: Use fast storage for backup destination

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Support

- **Issues**: Report bugs and feature requests on GitHub
- **Documentation**: Check this README and inline comments
