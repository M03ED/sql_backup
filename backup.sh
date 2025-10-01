#!/bin/bash

while getopts "c:" opt; do
    case $opt in
    c)
        CONFIG_FILE="$OPTARG"
        ;;
    *)
        echo "Usage: $0 -c <config_file>"
        exit 1
        ;;
    esac
done

if [ -z "$CONFIG_FILE" ]; then
    echo "Error: Config file not specified. Use -c <config_file>"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found at $CONFIG_FILE"
    exit 1
fi

get_config() {
    jq -r "$1 // \"\"" "$CONFIG_FILE"
}

# Global configurations
BACKUP_DIR="/tmp/backup"
BACKUP_INTERVAL_TIME=$(get_config '.backup_interval_time')
BOT_TOKEN=$(get_config '.telegram.bot_token')
CHAT_ID=$(get_config '.telegram.chat_id')
DISCORD_BACKUP_URL=$(get_config '.discord.backup_url')

SLEEP_TIME=$((BACKUP_INTERVAL_TIME * 60))

SQL_FILE_NAME="$BACKUP_DIR/db_backup.sql"
SPLIT_PATH="$BACKUP_DIR/split"

# Size limits in bytes
TELEGRAM_MAX_SIZE=$((49 * 1024 * 1024)) # 49MB
DISCORD_MAX_SIZE=$((7 * 1024 * 1024))   # 7MB

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"
mkdir -p "$SPLIT_PATH"

get_env_var() {
    local env_file="$1"
    shift

    if [[ ! -f "$env_file" ]]; then
        echo "Error: Environment file '$env_file' not found." >&2
        return 1
    fi

    while [[ $# -gt 0 ]]; do
        local var_name="$1"

        local var_value=$(grep -E "^$var_name\s*=" "$env_file" | sed -E 's/^[^=]*=\s*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')

        if [[ -n "$var_value" ]]; then
            DB_URL="$var_value"
            return 0
        fi

        shift
    done

    echo "Error: No non-empty variable found in the environment file." >&2
    DB_URL=""
    return 1
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] - $1"
}

get_file_size() {
    local file_path="$1"
    if [[ -f "$file_path" ]]; then
        stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

split_file() {
    local file_path="$1"
    local max_size="$2"
    local platform="$3"

    local file_name=$(basename "$file_path")
    local split_dir="$SPLIT_PATH/${platform}_${file_name%.*}"

    mkdir -p "$split_dir"

    # Split file into chunks
    split -b "$max_size" "$file_path" "$split_dir/part_"

    # Rename parts with proper extensions
    local part_num=1
    for part in "$split_dir"/part_*; do
        if [[ -f "$part" ]]; then
            mv "$part" "$split_dir/${file_name}.part$(printf "%03d" $part_num)"
            ((part_num++))
        fi
    done

    echo "$split_dir"
}

send_backup_to_telegram() {
    local file_path="$1"
    local file_size=$(get_file_size "$file_path")

    if [[ $file_size -gt $TELEGRAM_MAX_SIZE ]]; then
        log "File size ($file_size bytes) exceeds Telegram limit. Splitting into parts..."
        local split_dir=$(split_file "$file_path" "$TELEGRAM_MAX_SIZE" "telegram")

        # Send each part
        local part_count=$(ls -1 "$split_dir"/*.part* 2>/dev/null | wc -l)
        log "Sending $part_count parts to Telegram..."

        for part in "$split_dir"/*.part*; do
            if [[ -f "$part" ]]; then
                local part_name=$(basename "$part")
                log "Sending part: $part_name"
                curl -F chat_id="$CHAT_ID" -F document=@"$part" -F caption="Part: $part_name" "https://api.telegram.org/bot$BOT_TOKEN/sendDocument"
                echo # New line for readability
            fi
        done

        # Clean up split files
        rm -rf "$split_dir"
    else
        log "Sending complete file to Telegram ($(($file_size / 1024 / 1024))MB)"
        curl -F chat_id="$CHAT_ID" -F document=@"$file_path" "https://api.telegram.org/bot$BOT_TOKEN/sendDocument"
        echo # New line for readability
    fi
}

send_backup_to_discord() {
    local file_path="$1"
    local file_size=$(get_file_size "$file_path")
    local message="Here is your backup"

    if [[ $file_size -gt $DISCORD_MAX_SIZE ]]; then
        log "File size ($file_size bytes) exceeds Discord limit. Splitting into parts..."
        local split_dir=$(split_file "$file_path" "$DISCORD_MAX_SIZE" "discord")

        # Send each part
        local part_count=$(ls -1 "$split_dir"/*.part* 2>/dev/null | wc -l)
        log "Sending $part_count parts to Discord..."

        for part in "$split_dir"/*.part*; do
            if [[ -f "$part" ]]; then
                local part_name=$(basename "$part")
                local part_message="$message - Part: $part_name"
                log "Sending part: $part_name"
                curl -X POST -H "Content-Type: multipart/form-data" -F "content=$part_message" -F "file=@$part" "$DISCORD_BACKUP_URL"
                echo # New line for readability
            fi
        done

        # Clean up split files
        rm -rf "$split_dir"
    else
        log "Sending complete file to Discord ($(($file_size / 1024 / 1024))MB)"
        curl -X POST -H "Content-Type: multipart/form-data" -F "content=$message" -F "file=@$file_path" "$DISCORD_BACKUP_URL"
        echo # New line for readability
    fi
}

make_tar_file() {
    local full_path=$1
    shift
    local additional_files=("$@")

    tar czvf "$full_path" "${additional_files[@]}" || {
        echo "tar command failed"
        return 1
    }
}

backup_sqlite() {
    local full_path=$1
    local backup_name=$2
    local db_path=$3
    shift 3

    local additional_files=("$@")
    local file_path="$BACKUP_DIR/$backup_name.sqlite3"
    cp "$db_path" "$file_path"
    make_tar_file "$full_path" "$file_path" "${additional_files[@]}"

    # Clean up temporary sqlite file
    rm -f "$file_path"
    return 0
}

backup_mysql() {
    local full_path=$1
    local container_name=$2
    local docker_path=$3
    local database=$4
    local username=$5
    local password=$6
    shift 6
    local additional_files=("$@")

    log "MySQL Backup - User: $username, DB: $database"

    if ! output=$(docker compose -f "$docker_path" exec "$container_name" mysqldump -u"$username" -p"$password" "$database" 2>&1 >"$SQL_FILE_NAME"); then
        if [[ "$output" == *"Enter password:"* || "$output" == *"Access denied"* ]]; then
            log "Error: Authentication failed for MySQL backup. Please check credentials."
            return 1
        else
            log "Error during MySQL backup: $output"
            return 1
        fi
    fi

    make_tar_file "$full_path" "$SQL_FILE_NAME" "$docker_path" "${additional_files[@]}"
    return 0
}

backup_mariadb() {
    local full_path=$1
    local container_name=$2
    local docker_path=$3
    local database=$4
    local username=$5
    local password=$6
    shift 6
    local additional_files=("$@")

    log "MariaDB Backup - User: $username, DB: $database"

    if ! output=$(docker compose -f "$docker_path" exec "$container_name" mariadb-dump -u"$username" -p"$password" "$database" 2>&1 >"$SQL_FILE_NAME"); then
        if [[ "$output" == *"Enter password:"* || "$output" == *"Access denied"* ]]; then
            log "Error: Authentication failed for MariaDB backup. Please check credentials."
            return 1
        else
            log "Error during MariaDB backup: $output"
            return 1
        fi
    fi

    make_tar_file "$full_path" "$SQL_FILE_NAME" "$docker_path" "${additional_files[@]}"
    return 0
}

backup_postgresql() {
    local full_path=$1
    local container_name=$2
    local docker_path=$3
    local database=$4
    local username=$5
    local password=$6
    shift 6
    local additional_files=("$@")

    log "PostgreSQL/TimescaleDB Backup - User: $username, DB: $database"

    if ! output=$(docker compose -f "$docker_path" exec -e PGPASSWORD="$password" "$container_name" pg_dump -U "$username" -d "$database" 2>&1 >"$SQL_FILE_NAME"); then
        if [[ "$output" == *"password authentication failed"* || "$output" == *"FATAL"* ]]; then
            log "Error: Authentication failed for PostgreSQL/TimescaleDB backup. Please check credentials."
            return 1
        else
            log "Error during PostgreSQL/TimescaleDB backup: $output"
            return 1
        fi
    fi

    make_tar_file "$full_path" "$SQL_FILE_NAME" "$docker_path" "${additional_files[@]}"
    return 0
}

parse_sqlalchemy_url() {
    local input_string="$1"

    # Extract the part after the protocol and before the @ sign
    local credentials_part=$(echo "$input_string" | sed -n 's/.*:\/\/\(.*\)@.*/\1/p')
    
    # Extract username and password from the credentials part
    local username=$(echo "$credentials_part" | cut -d ':' -f 1)
    local password=$(echo "$credentials_part" | cut -d ':' -f 2)
    
    # Extract the database name from the end of the URL
    local database=$(echo "$input_string" | sed -n 's/.*\/\([^/]*\)$/\1/p' | cut -d '?' -f 1)

    echo "$username" "$password" "$database"
}

parse_gorm_url() {
    local input_string="$1"
    local username password database credentials_part

    # Check if it's PostgreSQL format (postgresql:// or postgres://)
    if [[ "$input_string" =~ ^postgres(ql)?:// ]]; then
        # PostgreSQL format: postgresql://user:password@host:port/database
        credentials_part=$(echo "$input_string" | sed -n 's/.*:\/\/\(.*\)@.*/\1/p')
        username=$(echo "$credentials_part" | cut -d ':' -f 1)
        password=$(echo "$credentials_part" | cut -d ':' -f 2)
        database=$(echo "$input_string" | sed -n 's/.*\/\([^/?]*\).*/\1/p')
    else
        # MySQL format: user:password@tcp(host:port)/database
        username=$(echo "$input_string" | cut -d ':' -f 1)
        password=$(echo "$input_string" | sed -n 's/^[^:]*:\([^@]*\)@tcp.*/\1/p')
        database=$(echo "$input_string" | sed -n 's/.*\/\([^?]*\).*/\1/p' | cut -d '?' -f 1)
    fi

    echo "$username" "$password" "$database"
}

cleanup_temp_files() {
    # Clean up any remaining temporary files
    rm -f "$SQL_FILE_NAME"
    # Clean up any leftover split directories
    rm -rf "$SPLIT_PATH"/telegram_*
    rm -rf "$SPLIT_PATH"/discord_*
}

process_database() {
    local index=$1

    local db_name=$(get_config ".databases[$index].db_name")
    local db_type=$(get_config ".databases[$index].type")
    local env_path=$(get_config ".databases[$index].env_path")
    local container_name=$(get_config ".databases[$index].container_name")
    local docker_path=$(get_config ".databases[$index].docker_path")
    local url_format=$(get_config ".databases[$index].url_format")

    get_env_var "$env_path" "DATABASE_URL" "SQLALCHEMY_DATABASE_URL"
    local external_paths=$(jq -r ".databases[$index].external | join(\" \")" "$CONFIG_FILE")

    log "DB Type: $db_type, URL Format: $url_format"
    log "DB URL: $DB_URL"

    if [[ $db_type == "sqlite" ]]; then
        DB_URL="${DB_URL#sqlite:///}"
    else
        case $url_format in
        "sqlalchemy")
            log "Using parse_sqlalchemy_url"
            credentials=($(parse_sqlalchemy_url "$DB_URL"))
            ;;
        "gorm")
            log "Using parse_gorm_url"
            credentials=($(parse_gorm_url "$DB_URL"))
            ;;
        *)
            log "Unsupported URL format: $url_format"
            return
            ;;
        esac
    fi

    local username=${credentials[0]}
    local password=${credentials[1]}
    local database=${credentials[2]}

    if [[ -z "$db_name" ]]; then
        db_name="$database"
    fi

    log "Starting backup for $db_name..."
    local file_name="$db_name-$(date '+%Y-%m-%d_%H-%M-%S').tar.gz"
    local full_path="$BACKUP_DIR/$file_name"

    case $db_type in
    "sqlite")
        if backup_sqlite "$full_path" "$db_name" "$DB_URL" $external_paths; then
            log "SQLite backup completed for $db_name"
        else
            log "SQLite backup failed for $db_name"
            return
        fi
        ;;
    "mysql")
        if backup_mysql "$full_path" "$container_name" "$docker_path" "$database" "$username" "$password" $external_paths; then
            log "MySQL backup completed for $db_name"
        else
            log "MySQL backup failed for $db_name"
            return
        fi
        ;;
    "mariadb")
        if backup_mariadb "$full_path" "$container_name" "$docker_path" "$database" "$username" "$password" $external_paths; then
            log "MariaDB backup completed for $db_name"
        else
            log "MariaDB backup failed for $db_name"
            return
        fi
        ;;
    "postgresql"|"timescaledb")
        if backup_postgresql "$full_path" "$container_name" "$docker_path" "$database" "$username" "$password" $external_paths; then
            log "PostgreSQL/TimescaleDB backup completed for $db_name"
        else
            log "PostgreSQL/TimescaleDB backup failed for $db_name"
            return
        fi
        ;;
    *)
        log "Unsupported database type: $db_type"
        return
        ;;
    esac

    if [[ -f "$full_path" ]]; then
        local file_size=$(get_file_size "$full_path")
        log "Backup file created: $file_name (Size: $(($file_size / 1024 / 1024))MB)"

        # Send to both platforms
        send_backup_to_telegram "$full_path"
        send_backup_to_discord "$full_path"

        # Clean up the main backup file after sending
        rm -f "$full_path"
        log "Backup file $file_name sent and cleaned up"
    else
        log "Error: Backup file was not created for $db_name"
    fi

    # Clean up any temporary files
    cleanup_temp_files
}

# Trap to ensure cleanup on script exit
trap cleanup_temp_files EXIT

# Main loop
log "Backup script started. Backup directory: $BACKUP_DIR"
log "Telegram size limit: $(($TELEGRAM_MAX_SIZE / 1024 / 1024))MB, Discord size limit: $(($DISCORD_MAX_SIZE / 1024 / 1024))MB"

while true; do
    DATABASE_COUNT=$(jq '.databases | length' "$CONFIG_FILE")
    log "Processing $DATABASE_COUNT databases..."

    for ((i = 0; i < DATABASE_COUNT; i++)); do
        process_database "$i"
    done

    log "All databases processed. Sleeping for $SLEEP_TIME seconds..."
    sleep "$SLEEP_TIME"
done
