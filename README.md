# ThingsBoard Self-Validating Backup (Non-Docker)

This repository provides a **fully automated and self-validating backup system** for **ThingsBoard CE/PE** (non-docker installations).

Each backup is **verified** by restoring it into a temporary validation database (`tbv`) **before** it is kept.  
This ensures **no corrupted or partial backups are ever stored**, improving reliability and disaster recovery assurance.

---

## Features

| Feature | Description |
|--------|-------------|
| Safe Database Backup | Uses `pg_dump -Fc` (compressed custom format) |
| Config + Data Backup | Saves `/etc/thingsboard` + `/usr/share/thingsboard/data` or `/var/lib/thingsboard` |
| Automatic Validation | Restores backup → `tbv` and verifies metadata consistency |
| Telemetry Drift Check | Ensures no significant telemetry loss during snapshot |
| Intelligent Retry System | Retries with exponential backoff if drift is high |
| Cron-Safe + Lock Protected | Uses `/var/lock/tb-backup.lock` to avoid overlapping runs |
| Email Alerts on Failure | Sends alerts when all retries fail |
| Works on CE & PE | PE license file backed up if present |

---

## Backup Output Structure
/var/backups/thingsboard/
├── tb_db_YYYY-MM-DD_HHMM.dump
├── tb_conf_YYYY-MM-DD_HHMM.tar.gz
├── tb_data_YYYY-MM-DD_HHMM.tar.gz
├── tb_license_YYYY-MM-DD_HHMM.tar.gz     # Only if PE license exists
└── tb_ui_branding_YYYY-MM-DD_HHMM.tar.gz # Only if custom UI assets exist

---

## Prerequisites

Install required tools:

## bash
sudo apt update
sudo apt install -y postgresql-client mailutils

Package                  Used For
postgresql-client    pg_dump, pg_restore, psql
mailutils            Sends email alerts

Setup Directories & Logging

## bash
sudo mkdir -p /var/backups/thingsboard
sudo chown root:postgres /var/backups/thingsboard
sudo chmod 2770 /var/backups/thingsboard

sudo touch /var/log/tb-backup.log
sudo chmod 644 /var/log/tb-backup.log

Install the Backup Script
Paste the script from tb-backup.sh in this repository.
Then:
sudo chmod +x /usr/local/bin/tb-backup.sh

Update the script variable ALERT_EMAIL="you@example.com"
⸻

Manual Backup Test (Run Once Before Cron)
sudo /usr/local/bin/tb-backup.sh
tail -f /var/log/tb-backup.log

Check backup files:
ls -lh /var/backups/thingsboard | tail -n 10

Check validation DB exists:
sudo -u postgres psql -l | grep tbv


⏱ Schedule Automatic Daily Backups
sudo crontab -e

add:
0 2 * * * /usr/local/bin/tb-backup.sh >> /var/log/tb-backup.log 2>&1
This runs the backup every day at 2:00 AM.



Restore Drill (Safe Test Restore)
LATEST=$(ls -1 /var/backups/thingsboard/tb_db_*.dump | tail -n1)
sudo -u postgres psql -c "DROP DATABASE IF EXISTS tbrestore;"
sudo -u postgres psql -c "CREATE DATABASE tbrestore;"
sudo -u postgres pg_restore --clean --if-exists --no-owner --no-privileges -d tbrestore "$LATEST"


Troubleshooting

Symptom                                                              Fix
permission denied writing dump                      sudo chmod 2770 /var/backups/thingsboard
Backup skipped                                      Another run active → sudo rm -f /var/lock/tb-backup.lock
pg_restore error                                    Test dump → pg_restore -l <dump>
No alert emails                                     Ensure mailutils installed + outbound mail allowed

