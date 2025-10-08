FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive
ARG PMA_VERSION=5.2.2

# Base utils + tini (PID 1)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini openssh-server sudo curl wget ca-certificates gnupg2 lsb-release \
      vim less unzip bash procps passwd dos2unix coreutils \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/sshd

# SSH durcissement basique
RUN sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
 && sed -i 's@^#\?AuthorizedKeysFile .*@AuthorizedKeysFile .ssh/authorized_keys@' /etc/ssh/sshd_config

# ------- MariaDB + Apache + PHP + phpMyAdmin -------
# Dépôt MariaDB 11.4 LTS
RUN apt-get update && apt-get install -y --no-install-recommends gnupg2 ca-certificates curl \
 && curl -fsSL https://mariadb.org/mariadb_release_signing_key.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/mariadb.gpg \
 && echo "deb [signed-by=/etc/apt/trusted.gpg.d/mariadb.gpg] https://mirror.mariadb.org/repo/11.4/debian bookworm main" > /etc/apt/sources.list.d/mariadb.list

# Paquets serveur web + PHP + MariaDB
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      mariadb-server mariadb-client \
      apache2 php libapache2-mod-php \
      php-mysql php-mbstring php-zip php-gd php-json php-curl php-xml \
      unzip \
 && rm -rf /var/lib/apt/lists/*

# Installer phpMyAdmin (version pinée)
RUN set -eux; \
  base="https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}"; \
  f="phpMyAdmin-${PMA_VERSION}-all-languages.zip"; \
  curl -fsSLo "/tmp/${f}"        "$base/${f}"; \
  curl -fsSLo "/tmp/${f}.sha256" "$base/${f}.sha256"; \
  (cd /tmp && sha256sum -c "${f}.sha256"); \
  unzip -q "/tmp/${f}" -d /usr/share; \
  mv "/usr/share/phpMyAdmin-${PMA_VERSION}-all-languages" /usr/share/phpmyadmin; \
  rm -f "/tmp/${f}" "/tmp/${f}.sha256"; \
  mkdir -p /usr/share/phpmyadmin/tmp; \
  chown -R www-data:www-data /usr/share/phpmyadmin

# Apache écoute sur 8080 et vhost phpMyAdmin
RUN sed -i 's/^Listen .*/Listen 8080/' /etc/apache2/ports.conf \
 && cat > /etc/apache2/sites-available/phpmyadmin.conf <<'EOF'
<VirtualHost *:8080>
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

RUN ln -sf /usr/bin/mariadb /usr/local/bin/mysql

# Entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN dos2unix /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

# Volumes utiles

# Healthcheck
HEALTHCHECK --interval=30s --timeout=5s --retries=5 \
 CMD bash -c "mysqladmin --protocol=socket --socket=/run/mysqld/mysqld.sock ping 2>/dev/null && curl -fsS http://127.0.0.1:8080/ >/dev/null" || exit 1

EXPOSE 22 8080

# tini en PID 1
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
