FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive

# Base utils
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server sudo curl git wget ca-certificates gnupg2 lsb-release \
      vim less unzip bash procps passwd dos2unix coreutils \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/sshd

# SSH durcissement basique
RUN sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
 && sed -i 's@^#\?AuthorizedKeysFile .*@AuthorizedKeysFile .ssh/authorized_keys@' /etc/ssh/sshd_config

# ------- MariaDB + Apache + PHP + phpMyAdmin -------
# Ajout du dépôt MariaDB (11.4 LTS) pour Debian 12 (bookworm)
RUN apt-get update && apt-get install -y --no-install-recommends gnupg2 ca-certificates curl \
 && curl -fsSL https://mariadb.org/mariadb_release_signing_key.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/mariadb.gpg \
 && echo "deb [signed-by=/etc/apt/trusted.gpg.d/mariadb.gpg] https://mirror.mariadb.org/repo/11.4/debian bookworm main" > /etc/apt/sources.list.d/mariadb.list

# Paquets serveur web + PHP + MariaDB
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      mariadb-server mariadb-client \
      apache2 php php-mysql php-mbstring php-zip php-gd php-json php-curl php-xml \
      unzip \
 && rm -rf /var/lib/apt/lists/*

# Installer phpMyAdmin (depuis archive officielle)
RUN mkdir -p /usr/share/phpmyadmin \
 && curl -fsSL https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip -o /tmp/pma.zip \
 && unzip -q /tmp/pma.zip -d /usr/share \
 && mv /usr/share/phpMyAdmin-*-all-languages/* /usr/share/phpmyadmin/ \
 && rm -rf /usr/share/phpMyAdmin-*-all-languages /tmp/pma.zip \
 && mkdir -p /usr/share/phpmyadmin/tmp \
 && chown -R www-data:www-data /usr/share/phpmyadmin

# Config Apache pour écouter sur 5432 et servir phpMyAdmin
RUN sed -i 's/^Listen .*/Listen 5432/' /etc/apache2/ports.conf \
 && cat > /etc/apache2/sites-available/phpmyadmin.conf <<'EOF'
<VirtualHost *:5432>
    ServerAdmin webmaster@localhost
    DocumentRoot /usr/share/phpmyadmin
    <Directory /usr/share/phpmyadmin>
        Options FollowSymLinks
        DirectoryIndex index.php
        AllowOverride All
        Require all granted
        php_admin_value upload_tmp_dir /usr/share/phpmyadmin/tmp
        php_admin_value session.save_path /usr/share/phpmyadmin/tmp
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/phpmyadmin_error.log
    CustomLog ${APACHE_LOG_DIR}/phpmyadmin_access.log combined
</VirtualHost>
EOF
RUN a2dissite 000-default.conf >/dev/null 2>&1 || true \
 && a2ensite phpmyadmin.conf \
 && a2enmod rewrite

# Entrypoint
COPY <<'EOT' /usr/local/bin/entrypoint.sh
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'code=$?; echo "[ERROR] Entrypoint failed with exit code ${code}"; exit ${code}' ERR

echo "[INFO] Entrypoint starting..."

USER=debian
PWFILE="/home/${USER}/.initial_password"

# --- Créer utilisateur système 'debian' si besoin, générer mot de passe ---
echo "[INFO] Ensuring home directory exists: /home/${USER}"
mkdir -p "/home/${USER}"

if id -u "${USER}" >/dev/null 2>&1; then
  echo "[INFO] User '${USER}' already exists."
else
  echo "[INFO] Creating user '${USER}'..."
  useradd -m -d "/home/${USER}" -s /bin/bash "${USER}"
fi

echo "[INFO] Fixing ownership on /home/${USER}"
chown -R "${USER}:${USER}" "/home/${USER}"

echo "[INFO] Adding '${USER}' to sudoers (NOPASSWD)"
usermod -aG sudo "${USER}" || true
echo "${USER} ALL=(ALL:ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${USER}"
chmod 440 "/etc/sudoers.d/${USER}"

if [ -f "${PWFILE}" ]; then
  PASS="$(cat "${PWFILE}")"
  echo "[INFO] Reusing existing password from ${PWFILE}"
else
  echo "[INFO] Generating a new random password..."
  set +o pipefail
  PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
  set -o pipefail
  if [ -z "${PASS}" ]; then
    PASS="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
  fi
  echo "${PASS}" > "${PWFILE}"
  chown "${USER}:${USER}" "${PWFILE}"
  chmod 600 "${PWFILE}"
fi

echo "[INFO] Applying password to user '${USER}'"
echo "${USER}:${PASS}" | chpasswd

# --- SSH préparation ---
echo "[INFO] Preparing ~/.ssh directory"
su - "${USER}" -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh" || true

echo "[INFO] Preparing /var/run/sshd"
mkdir -p /var/run/sshd && chmod 755 /var/run/sshd

echo "[INFO] Generating SSH host keys if missing"
ssh-keygen -A || true
for k in /etc/ssh/ssh_host_*_key; do
  [ -f "$k" ] && chmod 600 "$k"
done

# --- MariaDB init & démarrage ---
echo "[INFO] Initializing MariaDB datadir if needed"
mkdir -p /var/lib/mysql
chown -R mysql:mysql /var/lib/mysql
if [ ! -d "/var/lib/mysql/mysql" ]; then
  mariadb-install-db --user=mysql --datadir=/var/lib/mysql --skip-test-db >/dev/null
fi

echo "[INFO] Starting MariaDB..."
mysqld_safe --user=mysql --datadir=/var/lib/mysql --skip-log-error &

# Attendre que MariaDB réponde
echo -n "[INFO] Waiting for MariaDB to be ready"
for i in $(seq 1 60); do
  if mysqladmin ping --silent 2>/dev/null; then echo " - up"; break; fi
  echo -n "."
  sleep 1
  if [ "$i" -eq 60 ]; then echo " - timeout"; exit 1; fi
done

# Sécurisation + comptes: root et superuser 'debian' avec même mot de passe
echo "[INFO] Securing MariaDB and creating users"
mysql --protocol=socket -uroot <<SQL
-- Forcer root à utiliser un mot de passe (désactive unix_socket)
UPDATE mysql.user SET plugin='mysql_native_password' WHERE User='root' AND Host='localhost';
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${PASS}';

-- Créer super utilisateur 'debian' (tous hôtes) avec même mot de passe
CREATE USER IF NOT EXISTS 'debian'@'%' IDENTIFIED BY '${PASS}';
CREATE USER IF NOT EXISTS 'debian'@'localhost' IDENTIFIED BY '${PASS}';
GRANT ALL PRIVILEGES ON *.* TO 'debian'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'debian'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

# --- phpMyAdmin config runtime (blowfish secret, host par défaut) ---
if [ ! -f /usr/share/phpmyadmin/config.inc.php ]; then
  echo "[INFO] Generating phpMyAdmin config"
  BLOWFISH=$(openssl rand -base64 32 | tr -d '\n' || echo 'changemechangemechangeme123456')
  cat > /usr/share/phpmyadmin/config.inc.php <<PMA
<?php
\$cfg = [];
\$cfg['blowfish_secret'] = '${BLOWFISH}';
\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = '127.0.0.1';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['TempDir'] = '/usr/share/phpmyadmin/tmp';
PMA
  chown www-data:www-data /usr/share/phpmyadmin/config.inc.php
fi

# --- Apache démarrage (port 5432) ---
echo "[INFO] Starting Apache on port 5432..."
apache2ctl -D FOREGROUND &

echo "[INFO] Container ready."
echo "[INFO] Credentials -> user=debian  password=${PASS}"
echo "[INFO] MariaDB    -> superuser 'debian' / root password = ${PASS}"
echo "[INFO] phpMyAdmin -> http://localhost:5432  (utilise 'debian' / ou 'root')"

# --- Démarrer sshd en avant-plan ---
echo "[INFO] Starting sshd in foreground..."
exec /usr/sbin/sshd -D -e
EOT

RUN dos2unix /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22 5432
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
