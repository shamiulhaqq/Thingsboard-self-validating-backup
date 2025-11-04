#!/usr/bin/env bash
# ============================================================
# ThingsBoard Automated, Self-Validating Backup (Non-Docker)
# Validates each backup by restoring it into a temp DB (tbv).
# Keeps backups only if validation passes.
# Safe for cron, overlap-safe (flock), email alerts on failure.
# ============================================================

set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ------------- CONFIGURABLE PARAMETERS ----------------
BACKUP_DIR="/var/backups/thingsboard"      # Folder to store backups
LOG_FILE="/var/log/tb-backup.log"          # Central run log
DB_NAME="thingsboard"                      # Live ThingsBoard DB name
TBV_DB="tbv"                               # Temporary validation DB
MAX_RETRIES=5                              # Attempts per run on failure
SLEEP_BASE=180                             # Backoff base in seconds (3m, 6m, 9m…)
ALERT_EMAIL="you@example.com"              # Where to send failure alerts
TZ_OFFSET="+0500"                          # Timezone offset for drift cutoff parsing
# ------------------------------------------------------

# ---- Resolve binaries explicitly (cron-safe) ----
PG_DUMP="$(command -v pg_dump)"
PG_RESTORE="$(command -v pg_restore)"
PSQL="$(command -v psql)"
TAR="$(command -v tar)"
MAIL_BIN="$(command -v mail || true)"

# ---- Simple logger: writes to log file and to stderr (NOT stdout) ----
ts(){ date "+%Y-%m-%d %H:%M:%S %Z"; }
log(){
  local msg="[$(ts)] $*"
  echo "$msg" >> "$LOG_FILE"
  echo "$msg" >&2
}

# ---- Send alert email if all attempts fail (mailutils required) ----
send_alert(){
  local subject="[ALERT] ThingsBoard Backup Validation Failed on $(hostname)"
  local body="All attempts failed. See $LOG_FILE and $BACKUP_DIR for details."
  if [ -n "$MAIL_BIN" ]; then
    echo "$body" | "$MAIL_BIN" -s "$subject" "$ALERT_EMAIL" || true
  else
    log "⚠ mailutils not installed; could not send alert email"
  fi
}

# ---- Ensure required directories, permissions and log exist ----
ensure_env(){
  # Log file
  touch "$LOG_FILE"; chmod 644 "$LOG_FILE"

  # Backup dir: root:postgres with setgid and group write so postgres can write/restore
  mkdir -p "$BACKUP_DIR"
  chown root:postgres "$BACKUP_DIR" || true
  chmod 2770 "$BACKUP_DIR"         # drwxrws---
  umask 007                        # new files default to 660/770 in this shell

  # Lock dir for flock
  mkdir -p /var/lock
}

# ---------- STEP 1: Create a backup set ----------
# Returns the timestamp (TS) via stdout; logs go to file/stderr only.
do_backup(){
  local TS DUMP
  TS="$(date +%F_%H%M)"                     # e.g. 2025-11-04_1541
  log "📦 Starting backup (TS=${TS})"

  # 1) DB dump (postgres user writes to BACKUP_DIR)
  DUMP="$BACKUP_DIR/tb_db_${TS}.dump"
  sudo -u postgres "$PG_DUMP" -Fc -d "$DB_NAME" -f "$DUMP"
  chgrp postgres "$DUMP" || true
  chmod 640 "$DUMP"

  # Sanity: dump must exist and be non-empty
  if [ ! -s "$DUMP" ]; then
    log "❌ Dump file missing/empty: $DUMP"
    return 1
  fi

  # 2) Config snapshot (non-fatal if absent)
  "$TAR" -czf "$BACKUP_DIR/tb_conf_${TS}.tar.gz" /etc/thingsboard 2>/dev/null || true

  # 3) Data directory (non-docker installs typically use one of these)
  if [ -d /usr/share/thingsboard/data ]; then
    "$TAR" -czf "$BACKUP_DIR/tb_data_${TS}.tar.gz" /usr/share/thingsboard/data
  elif [ -d /var/lib/thingsboard ]; then
    "$TAR" -czf "$BACKUP_DIR/tb_data_${TS}.tar.gz" /var/lib/thingsboard
  fi

  # 4) PE license (ignored on CE)
  if [ -f /etc/thingsboard/conf/thingsboard-license.conf ]; then
    "$TAR" -czf "$BACKUP_DIR/tb_license_${TS}.tar.gz" /etc/thingsboard/conf/thingsboard-license.conf 2>/dev/null || true
  fi

  # 5) Branding/web assets (if present)
  if   [ -d /usr/share/thingsboard/static ]; then
    "$TAR" -czf "$BACKUP_DIR/tb_ui_branding_${TS}.tar.gz" /usr/share/thingsboard/static
  elif [ -d /usr/share/thingsboard/ui ]; then
    "$TAR" -czf "$BACKUP_DIR/tb_ui_branding_${TS}.tar.gz" /usr/share/thingsboard/ui
  fi

  log "✅ Backup files created for TS=${TS}"
  echo "$TS"
}

# Remove the backup set for a given TS (used on failed validation)
delete_backup_set(){
  local TS="$1"
  log "🧹 Deleting failed backup set (TS=$TS)"
  rm -f "$BACKUP_DIR"/tb_*_"$TS".dump "$BACKUP_DIR"/tb_*_"$TS".tar.gz || true
}

# ---------- STEP 2: Restore the dump into tbv (validation DB) ----------
restore_to_tbv(){
  local TS="$1"
  local DUMP="$BACKUP_DIR/tb_db_${TS}.dump"
  log "🔁 Restoring $DUMP into validation DB '$TBV_DB'"
  sudo -u postgres "$PSQL" -c "DROP DATABASE IF EXISTS $TBV_DB;" >/dev/null
  sudo -u postgres "$PSQL" -c "CREATE DATABASE $TBV_DB;" >/dev/null
  sudo -u postgres "$PG_RESTORE" --clean --if-exists --no-owner --no-privileges -d "$TBV_DB" "$DUMP"
}

# ---------- STEP 3a: Metadata parity check (must match exactly) ----------
validate_metadata(){
  log "🔍 Validating metadata parity (device/dashboard/tenant/rule_chain)"
  local LDEV TDEV LDASH TDASH LTEN TTEN LRULE TRULE
  LDEV=$( sudo -u postgres "$PSQL" -d "$DB_NAME" -At -c "SELECT COUNT(*) FROM device;" )
  TDEV=$( sudo -u postgres "$PSQL" -d "$TBV_DB" -At -c "SELECT COUNT(*) FROM device;" )
  LDASH=$(sudo -u postgres "$PSQL" -d "$DB_NAME" -At -c "SELECT COUNT(*) FROM dashboard;")
  TDASH=$(sudo -u postgres "$PSQL" -d "$TBV_DB" -At -c "SELECT COUNT(*) FROM dashboard;")
  LTEN=$( sudo -u postgres "$PSQL" -d "$DB_NAME" -At -c "SELECT COUNT(*) FROM tenant;" )
  TTEN=$( sudo -u postgres "$PSQL" -d "$TBV_DB" -At -c "SELECT COUNT(*) FROM tenant;" )
  LRULE=$(sudo -u postgres "$PSQL" -d "$DB_NAME" -At -c "SELECT COUNT(*) FROM rule_chain;")
  TRULE=$(sudo -u postgres "$PSQL" -d "$TBV_DB" -At -c "SELECT COUNT(*) FROM rule_chain;")
  log "   Devices    live=$LDEV  vs backup=$TDEV"
  log "   Dashboards live=$LDASH vs backup=$TDASH"
  log "   Tenants    live=$LTEN  vs backup=$TTEN"
  log "   RuleChains live=$LRULE vs backup=$TRULE"
  if [ "$LDEV" -ne "$TDEV" ] || [ "$LDASH" -ne "$TDASH" ] || [ "$LTEN" -ne "$TTEN" ] || [ "$LRULE" -ne "$TRULE" ]; then
    log "❌ Metadata mismatch"
    return 1
  fi
  log "✅ Metadata OK"
  return 0
}

# ---------- STEP 3b: Telemetry drift check up to snapshot ----------
# Uses TS from filename to compute a cutoff; compares live vs tbv counts <= cutoff.
compute_drift(){
  local TS="$1"
  local FN_TS="${TS/_/ }"      # "YYYY-MM-DD HHMM"
  FN_TS="${FN_TS:0:13}:00"     # "YYYY-MM-DD HH:MM:00"
  local EPOCH_S
  EPOCH_S=$(date -d "$FN_TS $TZ_OFFSET" +%s)
  local CUT_MS=$((EPOCH_S*1000))

  local LIVE_UP TBV_UP DRIFT
  LIVE_UP=$(sudo -u postgres "$PSQL" -d "$DB_NAME" -At -c "SELECT COUNT(*) FROM ts_kv WHERE ts <= $CUT_MS;")
  TBV_UP=$( sudo -u postgres "$PSQL" -d "$TBV_DB"  -At -c "SELECT COUNT(*) FROM ts_kv WHERE ts <= $CUT_MS;")
  DRIFT=$((LIVE_UP - TBV_UP))
  log "📊 Telemetry up to snapshot: live=$LIVE_UP | backup=$TBV_UP | drift=$DRIFT"
  echo "$DRIFT"
}

# ---------- STEP 4: Dynamic thresholds (based on actual load) ----------
# Computes PASS/WARN bands using backup duration and current write rate.
dynamic_thresholds(){
  local DURATION="$1"   # seconds
  local TPM TPS EXPECT
  TPM=$(sudo -u postgres "$PSQL" -d "$DB_NAME" -At -c \
"SELECT COUNT(*) FROM ts_kv WHERE ts > extract(epoch from now())*1000 - (60*1000);")
  TPS=$(( TPM / 60 ))            # rows per second
  EXPECT=$(( TPS * DURATION ))   # expected rows during backup window
  DRIFT_OK=$((   EXPECT * 5  ))  # pass band
  DRIFT_WARN=$(( EXPECT * 15 ))  # warn-acceptable band
  log "⚖ Dynamic thresholds: TPM=$TPM, duration=${DURATION}s, expected=$EXPECT, PASS≤$DRIFT_OK, WARN≤$DRIFT_WARN"
}

# ---------- STEP 5: Classify outcome ----------
classify_and_log(){
  local DRIFT="$1"
  if [ "$DRIFT" -le "$DRIFT_OK" ]; then
    log "✅ Backup Stable (low drift)"; return 0
  elif [ "$DRIFT" -le "$DRIFT_WARN" ]; then
    log "⚠️  Backup Acceptable (moderate load)"; return 0
  else
    log "❌ Drift too high — retry needed"; return 1
  fi
}

# ---------- MAIN ORCHESTRATION ----------
main(){
  ensure_env

  # Single-run lock: avoid overlapping backups (cron or manual)
  exec 9>/var/lock/tb-backup.lock
  if ! flock -n 9; then
    log "⛔ Skipped: another backup is running (lock held)"
    exit 0
  fi

  local ATTEMPT=1
  while [ "$ATTEMPT" -le "$MAX_RETRIES" ]; do
    log "================ Attempt $ATTEMPT/$MAX_RETRIES ================"
    local START END DURATION TS DRIFT

    START=$(date +%s)
    TS="$(do_backup 2>>"$LOG_FILE")"      # capture TS only from stdout
    restore_to_tbv "$TS"

    # 1) Metadata parity
    if ! validate_metadata; then
      END=$(date +%s); DURATION=$((END-START))
      log "⏱ Duration: ${DURATION}s (metadata failed)"
      delete_backup_set "$TS"
    else
      # 2) Drift check
      DRIFT="$(compute_drift "$TS")"
      END=$(date +%s); DURATION=$((END-START))
      log "⏱ Duration: ${DURATION}s"
      dynamic_thresholds "$DURATION"

      if classify_and_log "$DRIFT"; then
        log "🎉 Backup validated and kept (TS=$TS)"
        log "--------------------------------------------------------------"
        return 0
      else
        delete_backup_set "$TS"
      fi
    fi

    # Retry/Alert
    if [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; then
      local WAIT=$((SLEEP_BASE * ATTEMPT))
      log "⏳ Retrying in $WAIT seconds..."
      sleep "$WAIT"
    else
      log "🚨 All attempts failed — sending email alert"
      send_alert
      log "--------------------------------------------------------------"
      return 1
    fi
    ATTEMPT=$((ATTEMPT+1))
  done
}

main "$@"
