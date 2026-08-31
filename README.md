# immich-backup-unraid

Automated backup of [Immich](https://immich.app/) photos and database to cloud storage from [Unraid](https://unraid.net/).

Works with **Backblaze B2**, **Wasabi**, **AWS S3**, or any [rclone](https://rclone.org/)-supported remote.

## What it does

1. **Dumps the Immich PostgreSQL database** (via `pg_dump` inside the container)
2. **Stops Immich containers** (optional, for consistent backups)
3. **Syncs photos + DB dumps** to your cloud remote via rclone
4. **Restarts Immich containers**
5. **Prunes old local DB dumps** (configurable retention)
6. **Sends a webhook notification** on completion (optional)

## Requirements

- Unraid server with [Immich](https://immich.app/) installed
- [rclone plugin](https://forums.unraid.net/topic/116722-plugin-rclone/) installed on Unraid
- [User Scripts plugin](https://forums.unraid.net/topic/48286-plugin-ca-user-scripts/) installed on Unraid
- A cloud storage account (Backblaze B2 recommended)

## Quick start

### 1. Set up rclone remote

SSH into your Unraid server and configure your cloud storage:

```bash
rclone config
```

For **Backblaze B2**:
1. Create a free account at [backblaze.com](https://www.backblaze.com/)
2. Go to **B2 Cloud Storage** → **Application Keys** → **Add a New Application Key**
3. Create a bucket (e.g. `immich-backup`)
4. In `rclone config`, choose `New remote` → name it `b2` → select `Backblaze B2` → enter your key ID and application key

Test it works:

```bash
rclone lsd b2:
```

### 2. Install the backup script

```bash
# Create config directory
mkdir -p /mnt/user/appdata/immich-backup

# Copy the config file
cp immich-backup.conf.example /mnt/user/appdata/immich-backup/immich-backup.conf

# Edit the config
nano /mnt/user/appdata/immich-backup/immich-backup.conf
```

At minimum, set:
- `RCLONE_REMOTE` — your remote and bucket (e.g. `b2:immich-backup`)
- `PHOTOS_DIR` — where Immich stores photos (your `/data` mount)

### 3. Copy the script to Unraid

```bash
# Copy to User Scripts directory
mkdir -p /boot/config/plugins/user.scripts/scripts/immich-backup
cp immich-backup.sh /boot/config/plugins/user.scripts/scripts/immich-backup/script
chmod +x /boot/config/plugins/user.scripts/scripts/immich-backup/script
```

### 4. Schedule it

In the Unraid webUI: **Plugins** → **User Scripts** → **immich-backup** → set a schedule.

Recommended: **daily at 3:00 AM** (after Immich's nightly maintenance):

```
0 3 * * *
```

Or run it manually from the User Scripts page.

## Usage

```bash
# Full backup (default)
immich-backup.sh

# Preview what would happen
immich-backup.sh --dry-run

# Only back up the database
immich-backup.sh --db-only

# Only back up photos (skip DB dump)
immich-backup.sh --photos-only

# Don't stop containers (live backup)
immich-backup.sh --no-stop

# Use a custom config file
immich-backup.sh --conf /path/to/custom.conf
```

## Configuration

See [`immich-backup.conf.example`](immich-backup.conf.example) for all options.

| Option | Default | Description |
|--------|---------|-------------|
| `RCLONE_REMOTE` | `b2:immich-backup` | rclone remote:bucket |
| `PHOTOS_DIR` | `/mnt/user/pictures` | Immich photo storage |
| `STOP_CONTAINERS` | `true` | Stop containers during backup |
| `RETAIN_DUMPS` | `7` | Keep last N local DB dumps |
| `TRANSFERS` | `4` | rclone parallel transfers |
| `BWLIMIT` | `0` | Bandwidth limit (e.g. `50M`) |
| `WEBHOOK_URL` | *(empty)* | Webhook for notifications |

## Notifications

Set `WEBHOOK_URL` in your config to receive a POST on completion. Works with:

- **Discord**: Use a Discord webhook URL
- **Slack**: Use a Slack incoming webhook URL
- **ntfy**: `https://ntfy.sh/your-topic`
- **Gotify**: `https://gotify.example.com/message?token=YOUR_TOKEN`

## Directory structure

```
/mnt/user/appdata/immich-backup/
├── immich-backup.conf          # Your config
├── db-dumps/
│   ├── immich-20260831.sql.gz  # Nightly DB dumps
│   ├── immich-20260901.sql.gz
│   └── ...                     # (retained per RETAIN_DUMPS)
└── logs/
    ├── backup-20260831-030000.log
    └── ...                     # (retained per RETAIN_LOGS)
```

## Restoring

### Database only

```bash
# Download the dump from your remote
rclone copy b2:immich-backup/db-dumps/immich-20260831.sql.gz /tmp/

# Stop Immich
docker stop immich-server immich-machine-learning

# Restore
gunzip -c /tmp/immich-20260831.sql.gz | docker exec -i immich-postgres psql -U postgres -d immich

# Start Immich
docker start immich-redis immich-postgres immich-machine-learning immich-server
```

### Full restore (photos + database)

```bash
# Download photos
rclone copy b2:immich-backup/photos /mnt/user/pictures --progress

# Download and restore DB (see above)
rclone copy b2:immich-backup/db-dumps /mnt/user/immich-backup/db-dumps --progress
gunzip -c /mnt/user/immich-backup/db-dumps/immich-YYYYMMDD.sql.gz \
    | docker exec -i immich-postgres psql -U postgres -d immich
```

## Cost estimate

| Storage | Backblaze B2 | Wasabi | AWS S3 Standard |
|---------|-------------|--------|-----------------|
| 500 GB | ~$3/mo | ~$3.50/mo | ~$11.50/mo |
| 1 TB | ~$6/mo | ~$7/mo | ~$23/mo |
| 2 TB | ~$12/mo | ~$14/mo | ~$46/mo |

Backblaze B2 offers 10 GB free. Egress is free for the first 3x your stored data per day.

## License

MIT
