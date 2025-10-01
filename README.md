# M03ED Backup
You Can Use This Script To Make Backup From `gorm` or `sqlalchemy` Database On Telegram And Discord.
- PostgreSQL, TimescaleDB, MySQL, MariaDB and SQlite3 Are Supported.

# Usage
### Step 1
First You Need To Install `tar` And `curl`.
```bash
apt install tar curl
```
Then Change The Directory.
```bash
cd /opt
```
Download Project.
```bash 
git clone "https://github.com/M03ED/sql_backup.git"
```
Enter Project Folder
```bash
cd /opt/sql_backup
```

### Step 2
Set-up Your `config.json` file.
```json
{
    "backup_dir": "/tmp/sql-backup",
    "backup_interval_time": 60, // interval per minutes
    "telegram": {
        "bot_token": "your-telegram-bot-token", // replace with telegram bot token, max to 50mb backup
        "chat_id": "your-chat-id" // replace with your telegram id, you can find it with https://t.me/username_to_id_bot
    },
    "discord": {
        "backup_url": "your-discord-webhook-url" // replace with discord webhook, max to 10mb backup
    },
    "databases": [
        {
            "type": "timescaledb", //can be timescaledb, postgresql, mysql, mariadb or sqlite 
            "env_path": "/opt/pasarguard/.env",
            "docker_path": "/opt/pasarguard/docker-compose.yml",
            "container_name": "mariadb", // database container name
            "url_format":"sqlalchemy", // can be sqlalchemy or gorm, use sqlalchemy for pasarguard
            "external": [
                "/var/lib/pasarguard/certs",
                "/var/lib/pasarguard/templates",
                "/var/lib/pasarguard/xray_config.json"
            ] // any file or folder you need to add to backup file
        }
    ] // list of database's, you can add many as you want
}
```

### Step 3
Run following command to install service.
```bash
sudo bash install_service.sh
```

Now You Have Your Backup On Telegram And Discord.

To see script output you can use this command
```shell
journalctl -xeu sql-backup.service
```
