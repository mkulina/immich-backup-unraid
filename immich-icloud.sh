#!/usr/bin/env bash
# immich-icloud — Authenticate with iCloud and pull photos to Tower
# Part of immich-backup-unraid: https://github.com/mkulina/immich-backup-unraid
#
# This script manages the icloudpd Docker container to download photos
# from iCloud to a local directory that Immich can import.
#
# Usage:
#   immich-icloud.sh setup          # Install container + authenticate
#   immich-icloud.sh pull           # Run a one-time pull
#   immich-icloud.sh status         # Check sync status
#   immich-icloud.sh logs           # View container logs
#   immich-icloud.sh reauth         # Re-authenticate (cookie expired)

set -euo pipefail

VERSION="1.0.0"
CONF_FILE="${IMMICH_BACKUP_CONF:-/mnt/user/appdata/immich-backup/immich-backup.conf}"

# ─── Defaults ────────────────────────────────────────────────────
ICLOUD_CONTAINER="icloudpd"
ICLOUD_DOWNLOAD_DIR="/mnt/user/pictures/iCloud"
ICLOUD_CONFIG_DIR="/mnt/user/appdata/icloudpd"
ICLOUD_APPLE_ID=""
ICLOUD_TIMEZONE="America/New_York"
ICLOUD_DOWNLOAD_INTERVAL="86400"  # 24h
ICLOUD_PHOTO_SIZE="original"
ICLOUD_FOLDER_STRUCTURE="{:%Y/%m/%d}"

# ─── Load config ─────────────────────────────────────────────────
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

# ─── Parse args ──────────────────────────────────────────────────
ACTION="${1:-help}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "FATAL: $*"; exit 1; }

# ─── Actions ─────────────────────────────────────────────────────
do_setup() {
    log "=== iCloud Photos Downloader Setup ==="

    if [[ -z "$ICLOUD_APPLE_ID" ]]; then
        read -rp "Enter your Apple ID (email): " ICLOUD_APPLE_ID
    fi

    if [[ -z "$ICLOUD_APPLE_ID" ]]; then
        die "Apple ID is required."
    fi

    # Create directories
    mkdir -p "$ICLOUD_DOWNLOAD_DIR" "$ICLOUD_CONFIG_DIR"

    # Create .mounted file (required by icloudpd to start syncing)
    touch "$ICLOUD_DOWNLOAD_DIR/.mounted"

    log "Pulling icloudpd Docker image..."
    docker pull boredazfcuk/icloudpd:latest

    log "Creating container..."
    # Remove existing container if it exists
    docker rm -f "$ICLOUD_CONTAINER" 2>/dev/null || true

    docker create \
        --name "$ICLOUD_CONTAINER" \
        --restart unless-stopped \
        -e "APPLE_ID=${ICLOUD_APPLE_ID}" \
        -e "TZ=${ICLOUD_TIMEZONE}" \
        -e "download_path=/home/user/iCloud" \
        -e "folder_structure=${ICLOUD_FOLDER_STRUCTURE}" \
        -e "photo_size=${ICLOUD_PHOTO_SIZE}" \
        -e "download_interval=${ICLOUD_DOWNLOAD_INTERVAL}" \
        -e "authentication_type=MFA" \
        -e "initialise=true" \
        -e "notification_days=7" \
        -v "${ICLOUD_CONFIG_DIR}:/config" \
        -v "${ICLOUD_DOWNLOAD_DIR}:/home/user/iCloud" \
        boredazfcuk/icloudpd:latest

    log "Container created. Starting for authentication..."
    docker start "$ICLOUD_CONTAINER"

    log ""
    log "============================================"
    log "  iCloud Authentication Required"
    log "============================================"
    log ""
    log "The container is running and will prompt for your"
    log "Apple ID password and 2FA code."
    log ""
    log "Watch the logs and follow the prompts:"
    log "  docker logs -f $ICLOUD_CONTAINER"
    log ""
    log "Or run this to complete authentication:"
    log "  docker exec -it $ICLOUD_CONTAINER sync-icloud.sh --Initialise"
    log ""
    log "After authentication, photos will sync every ${ICLOUD_DOWNLOAD_INTERVAL}s."
    log "Download location: ${ICLOUD_DOWNLOAD_DIR}"
    log "============================================"
}

do_pull() {
    log "=== Running one-time iCloud pull ==="

    if ! docker ps --format '{{.Names}}' | grep -q "^${ICLOUD_CONTAINER}$"; then
        die "icloudpd container not running. Run: immich-icloud.sh setup"
    fi

    log "Triggering sync..."
    docker exec "$ICLOUD_CONTAINER" sync-icloud.sh --ForceSync

    # Wait for sync to complete
    log "Waiting for sync to complete (check logs for progress)..."
    sleep 5

    # Count downloaded files
    local count
    count=$(find "$ICLOUD_DOWNLOAD_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.heic" -o -iname "*.png" -o -iname "*.mp4" -o -iname "*.mov" -o -iname "*.dng" \) 2>/dev/null | wc -l)
    local size
    size=$(du -sh "$ICLOUD_DOWNLOAD_DIR" 2>/dev/null | cut -f1)

    log "Sync complete. ${count} files (${size}) in ${ICLOUD_DOWNLOAD_DIR}"
}

do_status() {
    log "=== iCloud Sync Status ==="

    if ! docker ps -a --format '{{.Names}}' | grep -q "^${ICLOUD_CONTAINER}$"; then
        log "Container not installed. Run: immich-icloud.sh setup"
        return 1
    fi

    local status
    status=$(docker ps --format '{{.Status}}' --filter "name=${ICLOUD_CONTAINER}")
    if [[ -z "$status" ]]; then
        log "Container: stopped"
    else
        log "Container: ${status}"
    fi

    local count
    count=$(find "$ICLOUD_DOWNLOAD_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.heic" -o -iname "*.png" -o -iname "*.mp4" -o -iname "*.mov" -o -iname "*.dng" \) 2>/dev/null | wc -l)
    local size
    size=$(du -sh "$ICLOUD_DOWNLOAD_DIR" 2>/dev/null | cut -f1)

    log "Photos: ${count} files (${size})"
    log "Location: ${ICLOUD_DOWNLOAD_DIR}"

    # Check last sync time from logs
    local last_sync
    last_sync=$(docker logs --tail 20 "$ICLOUD_CONTAINER" 2>&1 | grep -i "download" | tail -1)
    if [[ -n "$last_sync" ]]; then
        log "Last activity: ${last_sync}"
    fi
}

do_logs() {
    docker logs --tail 50 -f "$ICLOUD_CONTAINER" 2>&1
}

do_reauth() {
    log "=== Re-authenticating with iCloud ==="
    log "Stopping container..."
    docker stop "$ICLOUD_CONTAINER" 2>/dev/null || true

    log "Removing old keyring..."
    docker exec "$ICLOUD_CONTAINER" rm -f /config/.mounted 2>/dev/null || true

    log "Starting with initialise=true..."
    docker start "$ICLOUD_CONTAINER"

    log "Follow the prompts in the logs:"
    log "  docker logs -f $ICLOUD_CONTAINER"
    log "  docker exec -it $ICLOUD_CONTAINER sync-icloud.sh --Initialise"
}

do_help() {
    echo "immich-icloud v${VERSION} — iCloud Photos Downloader for Immich"
    echo ""
    echo "Usage: immich-icloud.sh <command>"
    echo ""
    echo "Commands:"
    echo "  setup     Install icloudpd container and start authentication"
    echo "  pull      Run a one-time photo pull from iCloud"
    echo "  status    Check sync status and photo count"
    echo "  logs      Follow container logs"
    echo "  reauth    Re-authenticate when MFA cookie expires"
    echo "  help      Show this help"
    echo ""
    echo "Config: ${CONF_FILE}"
    echo ""
    echo "After setup, add Immich external library at:"
    echo "  /mnt/user/pictures/iCloud"
}

# ─── Main ────────────────────────────────────────────────────────
case "$ACTION" in
    setup)  do_setup ;;
    pull)   do_pull ;;
    status) do_status ;;
    logs)   do_logs ;;
    reauth) do_reauth ;;
    help|--help|-h) do_help ;;
    *) echo "Unknown command: $ACTION"; do_help; exit 1 ;;
esac