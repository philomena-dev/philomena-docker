#!/usr/bin/env bash
# Installs the WireGuard tunnel that `./philomena.sh wireguard` configured.
# Run it as root, on the app server and on the proxy server. It can be run
# again after the configuration has changed.
#
# Usage: scripts/install-wireguard.sh

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

config=wireguard/philomena.conf
unit=wg-quick@philomena.service

function die {
  echo "$1" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "This script has to be run as root."
[[ -f $config ]] || die "$PWD/$config does not exist. Run './philomena.sh wireguard' first."
command -v wg-quick > /dev/null || die "WireGuard is not installed. On Debian, run: apt install wireguard-tools"
command -v systemctl > /dev/null || die "This script needs systemd. On other systems, bring the tunnel up at boot, before Docker, with: wg-quick up $PWD/$config"

install -d -m 700 /etc/wireguard
install -m 600 -o root -g root "$config" /etc/wireguard/philomena.conf

systemctl enable "$unit"
systemctl restart "$unit"

# Docker publishes the port of the link on the address inside the tunnel. That
# address has to exist when Docker starts the containers after a reboot.
install -d /etc/systemd/system/docker.service.d

{
  echo "[Unit]"
  echo "After=$unit"
  echo "Wants=$unit"
} > /etc/systemd/system/docker.service.d/philomena-wireguard.conf

systemctl daemon-reload

echo "The tunnel is up:"
wg show philomena
