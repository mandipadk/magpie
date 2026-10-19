#!/usr/bin/env bash
# One-time root setup for the Magpie hub on this server. Idempotent.
# Expects a built release (magpie/deploy.sh --build-only puts it in ./build).
set -euo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SRC/../.." && pwd)
ADDR=${MAGPIE_ADDR:?set MAGPIE_ADDR to the public host:port devices dial}

id magpie >/dev/null 2>&1 || useradd --system --home-dir /var/lib/magpie --shell /usr/sbin/nologin magpie
usermod -aG magpie ubuntu

install -d -o ubuntu -g magpie -m 0755 /opt/magpie /opt/magpie/releases
install -d -o magpie -g magpie -m 0700 /var/lib/magpie

if [[ ! -e /opt/magpie/current ]]; then
  SHA=$(git -C "$REPO" rev-parse --short=12 HEAD)
  install -d -o ubuntu -g magpie -m 0755 "/opt/magpie/releases/$SHA"
  for b in syncthing magpie-hubd; do
    install -o ubuntu -g magpie -m 0755 "$REPO/build/$b" "/opt/magpie/releases/$SHA/$b"
  done
  ln -sfn "releases/$SHA" /opt/magpie/current
  ln -sfn "releases/$SHA" /opt/magpie/last-good
  chown -h ubuntu:magpie /opt/magpie/current /opt/magpie/last-good
fi

if [[ ! -f /var/lib/magpie/config.xml ]]; then
  runuser -u magpie -- env PATH=/opt/magpie/current:/usr/bin:/bin \
    /opt/magpie/current/magpie-hubd init --home /var/lib/magpie --addr "$ADDR" --syncthing /opt/magpie/current/syncthing
fi

install -o root -g root -m 0755 "$SRC/magpie-firewall" /usr/local/sbin/magpie-firewall
install -o root -g root -m 0440 "$SRC/sudoers" /etc/sudoers.d/magpie
visudo -cf /etc/sudoers.d/magpie

for u in magpie-hub.service magpie-hubd.service; do
  install -o root -g root -m 0644 "$SRC/$u" "/etc/systemd/system/$u"
done
systemctl daemon-reload
systemctl enable --now magpie-hub.service magpie-hubd.service
sleep 5
systemctl --no-pager --lines=5 status magpie-hub.service magpie-hubd.service || true
/usr/local/sbin/magpie-firewall check
