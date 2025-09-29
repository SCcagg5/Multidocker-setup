FROM debian:12

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server sudo curl git wget ca-certificates gnupg2 lsb-release \
      vim less unzip bash procps \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/sshd

RUN sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
 && sed -i 's@^#\?AuthorizedKeysFile .*@AuthorizedKeysFile .ssh/authorized_keys@' /etc/ssh/sshd_config

COPY <<'EOT' /usr/local/bin/entrypoint.sh
#!/usr/bin/env bash
set -euo pipefail

USER=debian
PWFILE="/home/${USER}/.initial_password"

mkdir -p "/home/${USER}"
if ! id -u "${USER}" >/dev/null 2>&1; then
  useradd -m -d "/home/${USER}" -s /bin/bash "${USER}" || true
fi
chown -R "${USER}:${USER}" "/home/${USER}"
usermod -aG sudo "${USER}" || true
echo "${USER} ALL=(ALL:ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${USER}"
chmod 440 "/etc/sudoers.d/${USER}"

if [ -f "${PWFILE}" ]; then
  PASS="$(cat "${PWFILE}")"
else
  PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
  echo "${PASS}" > "${PWFILE}"
  chown "${USER}:${USER}" "${PWFILE}"
  chmod 600 "${PWFILE}"
fi
echo "${USER}:${PASS}" | chpasswd || true

su - "${USER}" -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh" || true

mkdir -p /var/run/sshd && chmod 755 /var/run/sshd
ssh-keygen -A || true
for k in /etc/ssh/ssh_host_*_key; do [ -f "$k" ] && chmod 600 "$k"; done

if ! /usr/sbin/sshd -t -E /var/log/sshd_check.log; then
  echo "[ERROR] sshd -t failed. Dumping /var/log/sshd_check.log:" >&2
  cat /var/log/sshd_check.log >&2 || true
  echo "[HOLD] Sleeping to avoid restart loop. Inspect the log above." >&2
  tail -f /dev/null
fi

echo "[INFO] CONTAINER START - user=${USER} password=${PASS}" >&2
exec /usr/sbin/sshd -D -e
EOT

RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22 5432
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
