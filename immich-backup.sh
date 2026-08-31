#!/usr/bin/env bash
# immich-backup — Back up Immich photos + database to any rclone remote
# https://github.com/matthewkulina/immich-backup-unraid
#
# Designed for Unraid + Immich. Works with Backblaze B2, Wasabi, S3,
# or any rclone-supported remote.
#
# Usage:
#   immich-backup.sh                  # Full backup
#   immich-backup.sh --dry-run        # Show what would happen
#   immich-backup.sh --db-only        # DB dump + upload only (skip photos)
#   immich-backup.sh --photos-only    # Photo sync only (skip DB dump)
#   immich-backup.sh --no-stop        # Don't stop containers (live backup)

set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Defaults ────────────────────────────────────────────────────
CONF_FILE="${IMMICH_BACKUP_CONF:-/mnt/user/appdata/immich-backup/immich-backup.conf}"
RCLONE_REMOTE="b2:immich-backup"
PHOTOS_DIR="/mnt/user/pictures"
BACKUP_DIR="/mnt/user/immich-backup"
STOP_CONTAINERS="true"
CONTAINER_SERVER="immich-server"
CONTAINER_ML="immich-machine-learning"
CONTAINER_DB="immich-postgres"
CONTAINER_REDIS="immich-redis"
DB_CONTAINER="$CONTAINER_DB"
DB_USER="postgres"
DB_NAME="immich"
RETAIN_DUMPS=7
TRANSFERS=4
CHECKERS=8
BUFFER_SIZE="16M"
BWLIMIT="0"
EXCLUDE_DIRS="immich-gen/**"
WEBHOOK_URL=""
LOG_DIR="${BACKUP_DIR}/logs"
RETAIN_LOGS=30

# ─── Parse args ──────────────────────────────────────────────────
DRY_RUN=false
DB_ONLY=false
PHOTOS_ONLY=false
NO_STOP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY_RUN=true; shift ;;
        --db-only)      DB_ONLY=true; shift ;;
        --photos-only)  PHOTOS_ONLY=true; shift ;;
        --no-stop)      NO_STOP=true; shift ;;
        --conf)         CONF_FILE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: immich-backup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --dry-run       Show what would happen without doing it"
            echo "  --db-only       DB dump + upload only (skip photos)"
            echo "  --photos-only   Photo sync only (skip DB dump)"
            echo "  --no-stop       Don't stop containers (live backup)"
            echo "  --conf FILE     Path to config file"
            echo "  -h, --help      Show this help"
            echo ""
            echo "Config: ${CONF_FILE}"
            echo "Version: ${VERSION}"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Load config ─────────────────────────────────────────────────
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
    DB_CONTAINER="${DB_CONTAINER:-$CONTAINER_DB}"
fi

if [[ "$NO_STOP" == "true" ]]; then
    STOP_CONTAINERS="false"
fi

DB_DUMP_DIR="${BACKUP_DIR}/db-dumps"
LOG_FILE="${LOG_DIR}/backup-$(date +%Y%m%d-%H%M%S).log"

# ─── Helpers ─────────────────────────────────────────────────────
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
warn()  { log "WARN: $*"; }
die()   { log "FATAL: $*"; exit 1; }

notify() {
    local msg="$1"
    if [[ -n "$WEBHOOK_URL" ]]; then
        curl -sf -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"content\": \"${msg}\"}" \
            >/dev/null 2>&1 || warn "Webhook notification failed"
    fi
}

elapsed() {
    local start=$1
    local end=$(date +%s)
    local diff=$((end - start))
    printf '%02d:%02d:%02d' $((diff/3600)) $(((diff%3600)/60)) $((diff%60))
}

# ─── Init ────────────────────────────────────────────────────────
START_TIME=$(date +%s)
mkdir -p "$DB_DUMP_DIR" "$LOG_DIR"

log "=== immich-backup v${VERSION} started ==="
log "Config: ${CONF_FILE}"
log "Remote: ${RCLONE_REMOTE}"
log "Mode:   dry_run=${DRY_RUN} db_only=${DB_ONLY} photos_only=${PHOTOS_ONLY} stop=${STOP_CONTAINERS}"

# ─── Pre-flight ──────────────────────────────────────────────────
if ! command -v rclone &>/dev/null; then
    die "rclone not found. Install via Unraid Community Apps (Plugins tab)."
fi

if ! command -v docker &>/dev/null; then
    die "docker not found."
fi

if ! rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE%%:*}:"; then
    die "rclone remote '${RCLONE_REMOTE%%:*}' not configured. Run: rclone config"
fi

if [[ "$PHOTOS_ONLY" != "true" ]]; then
    if ! docker ps --format '{{.Names}}' | grep -q "^${DB_CONTAINER}$"; then
        die "${DB_CONTAINER} container not running."
    fi
fi

if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY RUN — no changes will be made."
fi

# ─── Step 1: Database dump ──────────────────────────────────────
DUMP_FILE=""
DUMP_SIZE="0"

if [[ "$PHOTOS_ONLY" != "true" ]]; then
    log "Step 1/4: Dumping Immich database..."
    DUMP_FILE="${DB_DUMP_DIR}/immich-$(date +%Y%m%d).sql.gz"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "  [dry-run] Would dump to ${DUMP_FILE}"
    else
        docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" --clean --if-exists \
            2>>"$LOG_FILE" | gzip > "$DUMP_FILE"

        DUMP_SIZE=$(du -h "$DUMP_FILE" | cut -f1)
        log "  Database dump: ${DUMP_FILE} (${DUMP_SIZE})"
    fi
else
    log "Step 1/4: Skipping database dump (--photos-only)"
fi

# ─── Step 2: Stop containers ────────────────────────────────────
if [[ "$STOP_CONTAINERS" == "true" && "$DB_ONLY" != "true" ]]; then
    log "Step 2/4: Stopping Immich containers..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log "  [dry-run] Would stop: ${CONTAINER_SERVER} ${CONTAINER_ML} ${CONTAINER_DB} ${CONTAINER_REDIS}"
    else
        for c in "$CONTAINER_SERVER" "$CONTAINER_ML" "$CONTAINER_DB" "$CONTAINER_REDIS"; do
            if docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
                docker stop "$c" >>"$LOG_FILE" 2>&1 && log "  Stopped $c" || warn "Failed to stop $c"
            else
                log "  $c already stopped"
            fi
        done
    fi
else
    log "Step 2/4: Skipping container stop"
fi

# ─── Step 3: Sync to remote ─────────────────────────────────────
RCLONE_ERRORS=0

if [[ "$DB_ONLY" != "true" ]]; then
    log "Step 3/4: Syncing photos to ${RCLONE_REMOTE}/photos..."
    RCLONE_ARGS=(
        sync
        "$PHOTOS_DIR"
        "${RCLONE_REMOTE}/photos"
        --transfers="$TRANSFERS"
        --checkers="$CHECKERS"
        --buffer-size="$BUFFER_SIZE"
        --fast-list
        --bwlimit="$BWLIMIT"
        --exclude "$EXCLUDE_DIRS"
        --log-file="$LOG_FILE"
        --log-level=INFO
        --stats=30s
    )

    if [[ "$DRY_RUN" == "true" ]]; then
        RCLONE_ARGS+=(--dry-run)
    fi

    rclone "${RCLONE_ARGS[@]}" 2>>"$LOG_FILE" || { warn "rclone photos sync had errors"; RCLONE_ERRORS=$((RCLONE_ERRORS + 1)); }
fi

if [[ "$PHOTOS_ONLY" != "true" ]]; then
    log "Step 3/4: Syncing DB dumps to ${RCLONE_REMOTE}/db-dumps..."
    RCLONE_ARGS=(
        sync
        "$DB_DUMP_DIR"
        "${RCLONE_REMOTE}/db-dumps"
        --transfers=2
        --fast-list
        --log-file="$LOG_FILE"
        --log-level=INFO
    )

    if [[ "$DRY_RUN" == "true" ]]; then
        RCLONE_ARGS+=(--dry-run)
    fi

    rclone "${RCLONE_ARGS[@]}" 2>>"$LOG_FILE" || { warn "rclone db-dumps sync had errors"; RCLONE_ERRORS=$((RCLONE_ERRORS + 1)); }
fi

# ─── Step 4: Restart containers ─────────────────────────────────
if [[ "$STOP_CONTAINERS" == "true" && "$DB_ONLY" != "true" ]]; then
    log "Step 4/4: Starting Immich containers..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log "  [dry-run] Would start: ${CONTAINER_REDIS} ${CONTAINER_DB} ${CONTAINER_ML} ${CONTAINER_SERVER}"
    else
        for c in "$CONTAINER_REDIS" "$CONTAINER_DB" "$CONTAINER_ML" "$CONTAINER_SERVER"; do
            docker start "$c" >>"$LOG_FILE" 2>&1 && log "  Started $c" || warn "Failed to start $c"
        done

        log "  Waiting for health checks..."
        sleep 15

        if docker ps --format '{{.Names}} {{.Status}}' | grep -q "${CONTAINER_SERVER}.*healthy"; then
            log "  ${CONTAINER_SERVER} is healthy."
        else
            warn "${CONTAINER_SERVER} may still be starting."
        fi
    fi
else
    log "Step 4/4: Skipping container restart"
fi

# ─── Cleanup ─────────────────────────────────────────────────────
if [[ "$DRY_RUN" != "true" ]]; then
    # Prune old local DB dumps
    if [[ -d "$DB_DUMP_DIR" ]]; then
        PRUNED=$(ls -1t "${DB_DUMP_DIR}"/immich-*.sql.gz 2>/dev/null | tail -n +$((RETAIN_DUMPS + 1)) | wc -l)
        ls -1t "${DB_DUMP_DIR}"/immich-*.sql.gz 2>/dev/null | tail -n +$((RETAIN_DUMPS + 1)) | while read -r old; do
            rm -f "$old"
        done
        [[ "$PRUNED" -gt 0 ]] && log "Pruned ${PRUNED} old DB dump(s)"
    fi

    # Prune old logs
    find "$LOG_DIR" -name "backup-*.log" -mtime +"$RETAIN_LOGS" -delete 2>/dev/null || true
fi

# ─── Summary ─────────────────────────────────────────────────────
DURATION=$(elapsed "$START_TIME")

if [[ "$DRY_RUN" != "true" && "$PHOTOS_ONLY" != "true" ]]; then
    PHOTO_COUNT=$(find "$PHOTOS_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.heic" -o -iname "*.heif" -o -iname "*.mp4" -o -iname "*.mov" -o -iname "*.dng" -o -iname "*.cr2" -o -iname "*.nef" \) 2>/dev/null | wc -l)
    TOTAL_SIZE=$(du -sh "$PHOTOS_DIR" 2>/dev/null | cut -f1)
else
    PHOTO_COUNT="?"
    TOTAL_SIZE="?"
fi

log "=== Backup Complete ==="
log "  Duration:  ${DURATION}"
log "  Photos:    ${PHOTO_COUNT} files (${TOTAL_SIZE})"
log "  DB dump:   ${DUMP_SIZE}"
log "  Remote:    ${RCLONE_REMOTE}"
log "  Errors:    ${RCLONE_ERRORS}"
log "  Log:       ${LOG_FILE}"

SUMMARY="immich-backup: ${DURATION} | ${PHOTO_COUNT} photos (${TOTAL_SIZE}) | DB ${DUMP_SIZE} | errors=${RCLONE_ERRORS}"
notify "$SUMMARY"

if [[ "$RCLONE_ERRORS" -gt 0 ]]; then
    exit 1
fi
