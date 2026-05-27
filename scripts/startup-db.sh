#!/usr/bin/env bash
# =============================================================================
# Startup script for the DB VM.
# Installs Postgres 16 and configures it to listen on the VPC interface.
# We *do not* expose Postgres to the internet — the firewall rule in chapter 08
# only allows traffic from inside the subnet (10.10.0.0/24).
# =============================================================================
set -euo pipefail

# 1) Install Postgres 16 from the official PostgreSQL (PGDG) apt repo.
#    Debian 12 "bookworm" only ships postgresql-15 in its default repos, so we
#    add apt.postgresql.org to get 16. (See https://www.postgresql.org/download/linux/debian/)
apt-get update -y
apt-get install -y curl ca-certificates gnupg lsb-release

install -d /usr/share/postgresql-common/pgdg
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc

CODENAME="$(lsb_release -cs)"   # e.g. "bookworm"
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list

apt-get update -y
apt-get install -y postgresql-16

# 2) Make Postgres listen on all interfaces (the firewall is what restricts who).
PG_CONF=/etc/postgresql/16/main/postgresql.conf
PG_HBA=/etc/postgresql/16/main/pg_hba.conf

sed -ri "s/^#?listen_addresses\\s*=.*/listen_addresses = '*'/" "${PG_CONF}"

# 3) Allow password auth from inside the subnet only.
#    NOTE: this is intentionally narrow — only 10.10.0.0/24.
cat >> "${PG_HBA}" <<'EOF'

# Allow connections from the app subnet (inserted by startup-db.sh).
host    all             all             10.10.0.0/24            md5
EOF

systemctl restart postgresql

# 4) Create the database, user, and password.
#    The password is passed in via VM metadata key `db-password` (set by the
#    pipeline). For a manual test you can hardcode one and rotate it later.
DB_USER="${DB_USER:-taskboard}"
DB_NAME="${DB_NAME:-taskboard}"
DB_PASSWORD="$(curl -fsSL -H 'Metadata-Flavor: Google' \
    http://metadata.google.internal/computeMetadata/v1/instance/attributes/db-password 2>/dev/null || echo 'change-me-please')"

sudo -u postgres psql <<SQL
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
      CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASSWORD}';
   END IF;
END
\$\$;

CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
SQL

date -Iseconds > /var/log/startup-complete.log
echo "[startup-db] done"
