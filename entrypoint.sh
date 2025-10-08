#!/usr/bin/env bash
set -Eeuo pipefail

# --- traps propres pour arrêter les services lancés en arrière-plan ---
mdb_pid=""
apache_pid=""

cleanup() {
  echo "[INFO] Stopping services..."
  if [ -n "${apache_pid}" ] && kill -0 "${apache_pid}" 2>/dev/null; then
    apache2ctl -k graceful-stop || true
    kill "${apache_pid}" 2>/dev/null || true
  fi
  if [ -S /run/mysqld/mysqld.sock ]; then
    mysqladmin --protocol=socket --socket=/run/mysqld/mysqld.sock shutdown -uroot -p"${PASS}" 2>/dev/null || true
  fi
  if [ -n "${mdb_pid}" ] && kill -0 "${mdb_pid}" 2>/dev/null; then
    kill "${mdb_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "[INFO] Entrypoint starting..."

# --------------------------------------------------------------------
# 0) Variables de base
# --------------------------------------------------------------------
USER=debian
PWFILE="/home/${USER}/.initial_password"
MYSQL_DATADIR="/var/lib/mysql"
MYSQL_SOCKET="/run/mysqld/mysqld.sock"
APACHE_VHOST="/etc/apache2/sites-available/phpmyadmin.conf"
PMA_DIR="/usr/share/phpmyadmin"
PMA_TMP="${PMA_DIR}/tmp"
PMA_CFG="${PMA_DIR}/config.inc.php"

# Mot de passe : utilise $PASSWORD si fourni, sinon génère/relit fichier
if [ -f "${PWFILE}" ]; then
  PASS="$(cat "${PWFILE}")"
else
  if [ -n "${PASSWORD:-}" ]; then
    PASS="${PASSWORD}"
  else
    PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
    [ -z "${PASS}" ] && PASS="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
  fi
  mkdir -p "/home/${USER}"
  echo "${PASS}" > "${PWFILE}"
  chown "${USER}:${USER}" "${PWFILE}"
  chmod 600 "${PWFILE}"
fi

# --------------------------------------------------------------------
# 1) Utilisateur système 'debian' + SSH
# --------------------------------------------------------------------
if ! id -u "${USER}" >/dev/null 2>&1; then
  useradd -m -d "/home/${USER}" -s /bin/bash "${USER}"
fi
chown -R "${USER}:${USER}" "/home/${USER}"
usermod -aG sudo "${USER}" || true
echo "${USER} ALL=(ALL:ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${USER}"
chmod 440 "/etc/sudoers.d/${USER}"

echo "${USER}:${PASS}" | chpasswd

su - "${USER}" -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh" || true

mkdir -p /var/run/sshd && chmod 755 /var/run/sshd
ssh-keygen -A || true
for k in /etc/ssh/ssh_host_*_key; do [ -f "$k" ] && chmod 600 "$k"; done

# --------------------------------------------------------------------
# 2) phpMyAdmin + Apache (port 8080) - idempotent
# --------------------------------------------------------------------
if ! grep -qE '^Listen[[:space:]]+8080' /etc/apache2/ports.conf 2>/dev/null; then
  sed -i 's/^Listen .*/Listen 8080/' /etc/apache2/ports.conf || echo "Listen 8080" >> /etc/apache2/ports.conf
fi

mkdir -p "${PMA_TMP}"
chown -R www-data:www-data "${PMA_DIR}"

if [ ! -f "${PMA_CFG}" ]; then
  echo "[INFO] Generating phpMyAdmin config"
  BLOWFISH=$(openssl rand -base64 32 | tr -d '\n' || echo 'changemechangemechangeme123456')
  cat > "${PMA_CFG}" <<PMA
<?php
\$cfg = [];
\$cfg['blowfish_secret'] = '${BLOWFISH}';
\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = '127.0.0.1';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['TempDir'] = '${PMA_TMP}';
PMA
  chown www-data:www-data "${PMA_CFG}"
fi

# --------------------------------------------------------------------
# 3) MariaDB : init + démarrage + sécurisation
# --------------------------------------------------------------------
echo "[INFO] Initializing MariaDB datadir if needed"
mkdir -p "${MYSQL_DATADIR}" /run/mysqld
chown -R mysql:mysql "${MYSQL_DATADIR}" /run/mysqld

if [ ! -d "${MYSQL_DATADIR}/mysql" ]; then
  echo "[INFO] Running mariadb-install-db..."
  mariadb-install-db --user=mysql --datadir="${MYSQL_DATADIR}" --skip-test-db
fi

echo "[INFO] Starting MariaDB..."
mariadbd \
  --user=mysql \
  --datadir="${MYSQL_DATADIR}" \
  --socket="${MYSQL_SOCKET}" \
  --bind-address=127.0.0.1 \
  --log-error="${MYSQL_DATADIR}/mariadb.err" \
  --pid-file=/run/mysqld/mariadb.pid &
mdb_pid=$!

# Attendre readiness
echo -n "[INFO] Waiting for MariaDB to be ready"
for i in $(seq 1 60); do
  if [ -S "${MYSQL_SOCKET}" ] && mysqladmin --protocol=socket --socket="${MYSQL_SOCKET}" ping --silent 2>/dev/null; then
    echo " - up"; break
  fi
  if ! kill -0 "$mdb_pid" 2>/dev/null; then echo " - mariadbd exited"; exit 1; fi
  echo -n "."; sleep 1
done

# Sécurisation + super utilisateur 'debian' (même mot de passe)
echo "[INFO] Securing MariaDB and creating users"

# Toujours utiliser le client 'mariadb' (évite l'avertissement "Deprecated program name")
MARIADB_CLI=(mariadb --protocol=socket --socket="${MYSQL_SOCKET}" -uroot --batch --skip-column-names)

# Détermine comment se connecter (sans mot de passe au 1er run, avec ensuite)
if "${MARIADB_CLI[@]}" -e "SELECT 1" >/dev/null 2>&1; then
  AUTH=("${MARIADB_CLI[@]}")
else
  AUTH=("${MARIADB_CLI[@]}" -p"${PASS}")
fi

# Exécute le SQL de sécurisation/création (idempotent)
"${AUTH[@]}" <<SQL
-- met un mot de passe à root (idempotent)
ALTER USER IF EXISTS 'root'@'localhost' IDENTIFIED BY '${PASS}';
-- crée l'utilisateur 'debian' si absent
CREATE USER IF NOT EXISTS 'debian'@'%' IDENTIFIED BY '${PASS}';
CREATE USER IF NOT EXISTS 'debian'@'localhost' IDENTIFIED BY '${PASS}';
GRANT ALL PRIVILEGES ON *.* TO 'debian'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'debian'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

# --------------------------------------------------------------------
# 4) Apache (phpMyAdmin sur :8080)
# --------------------------------------------------------------------
echo "[INFO] Starting Apache on port 8080..."
apache2ctl -D FOREGROUND &
apache_pid=$!

# Petit healthcheck interne
for i in $(seq 1 10); do
  if curl -fsS "http://127.0.0.1:8080/" >/dev/null 2>&1; then
    echo "[INFO] phpMyAdmin reachable on http://127.0.0.1:8080/"
    break
  fi
  sleep 1
done

# --------------------------------------------------------------------
# 5) Infos & démarrage sshd au premier plan
# --------------------------------------------------------------------
echo "[INFO] Container ready."
echo "[INFO] Credentials saved in ${PWFILE} for user 'debian'."
echo "[INFO] MariaDB socket=${MYSQL_SOCKET} port=3306"
echo "[INFO] phpMyAdmin -> http://localhost:8080  (use 'debian' or 'root')"

echo "[CREDENTIALS] user=debian password=${PASS}"

echo "[INFO] Starting sshd in foreground..."
exec /usr/sbin/sshd -D -e
