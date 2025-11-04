# ThingsBoard Self-Validating Backup (Non-Docker)

This project provides a **fully automated and self-validating backup system** for **ThingsBoard CE / PE (non-docker)** deployments.

Each backup is **automatically tested** by restoring it into a temporary validation database (`tbv`) before being kept permanently.  
This ensures **no corrupted / partial backups** are stored — improving disaster recovery reliability.

---

## 🚀 Key Features

| Feature | Description |
|--------|-------------|
| Safe Database Backup | Uses `pg_dump -Fc` custom format |
| Config + Data Backup | Saves `/etc/thingsboard` + `/usr/share/thingsboard/data` or `/var/lib/thingsboard` |
| Backup Validation | Restores backup → `tbv` and verifies metadata |
| Telemetry Drift Check | Ensures minimal data loss during snapshot |
| Intelligent Auto-Retry | Retries backup with increasing wait time if drift exceeds limit |
| Cron & Lock Safe | Uses `/var/lock/tb-backup.lock` to avoid overlapping runs |
| Email Alerts | Sends alert if all retries fail |
| Works with CE & PE | Licenses & UI branding backed up if present |

---

## 📂 Backup Output Folder

```text
/var/backups/thingsboard/
├── tb_db_YYYY-MM-DD_HHMM.dump
├── tb_conf_YYYY-MM-DD_HHMM.tar.gz
├── tb_data_YYYY-MM-DD_HHMM.tar.gz
├── tb_license_YYYY-MM-DD_HHMM.tar.gz      (PE only)
└── tb_ui_branding_YYYY-MM-DD_HHMM.tar.gz  (if present)



---

## ✅ Prerequisites (Run Once)

```bash
sudo apt update
sudo apt install -y postgresql-client mailutils

sudo mkdir -p /var/backups/thingsboard
sudo chown root:postgres /var/backups/thingsboard
sudo chmod 2770 /var/backups/thingsboard

sudo touch /var/log/tb-backup.log
sudo chmod 644 /var/log/tb-backup.log



sudo cp tb-backup.sh /usr/local/bin/tb-backup.sh
sudo chmod +x /usr/local/bin/tb-backup.sh


ALERT_EMAIL="your@email.com"

Test Backup Manually
sudo /usr/local/bin/tb-backup.sh

check logs
tail -f /var/log/tb-backup.log



Schedule Daily Automatic Backup
sudo crontab -e
0 2 * * * /usr/local/bin/tb-backup.sh >> /var/log/tb-backup.log 2>&1
This runs backup every day at 2:00 AM.


Optional: Restore Test
LATEST=$(ls -1 /var/backups/thingsboard/tb_db_*.dump | tail -n1)

sudo -u postgres psql -c "DROP DATABASE IF EXISTS tbrestore;"
sudo -u postgres psql -c "CREATE DATABASE tbrestore;"
sudo -u postgres pg_restore --clean --if-exists --no-owner --no-privileges \
  -d tbrestore "$LATEST"
