FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server sudo curl git wget ca-certificates gnupg2 lsb-release \
      vim less unzip bash procps passwd dos2unix coreutils \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/sshd

RUN sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
 && sed -i 's@^#\?AuthorizedKeysFile .*@AuthorizedKeysFile .ssh/authorized_keys@' /etc/ssh/sshd_config

COPY <<'EOT' /usr/local/bin/entrypoint.sh
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'code=$?; echo "[ERROR] Entrypoint failed with exit code ${code}"; exit ${code}' ERR

echo "[INFO] Entrypoint starting..."

USER=debian
PWFILE="/home/${USER}/.initial_password"

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

echo "[INFO] Preparing ~/.ssh directory"
su - "${USER}" -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh" || true

echo "[INFO] Preparing /var/run/sshd"
mkdir -p /var/run/sshd && chmod 755 /var/run/sshd

echo "[INFO] Generating SSH host keys if missing"
ssh-keygen -A || true
for k in /etc/ssh/ssh_host_*_key; do
  [ -f "$k" ] && chmod 600 "$k"
done

echo "[INFO] Container ready. Credentials -> user=${USER} password=${PASS}"
echo "[INFO] Starting sshd in foreground..."
exec /usr/sbin/sshd -D -e
EOT

RUN dos2unix /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22 5432
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
