#!/usr/bin/env bash
# install.sh — install fleet-sync on this host.
#
# Modes:
#   server  — install the config-serving daemon (runs on nas; the hub).
#   client  — install the pull-client (runs on every host, including nas).
#   both    — server + client, typical for the hub host.
#
# Requires: root, systemd, python3, curl.

set -euo pipefail

MODE=${1:-}
REPO_ROOT=$(cd "$(dirname "$0")" && pwd)

if [[ $EUID -ne 0 ]]; then
  echo "install.sh: must run as root" >&2
  exit 1
fi

install_server() {
  echo "[fleet-sync] installing server..."
  install -d /opt/fleet-sync /etc/fleet-sync
  install -m 0755 "$REPO_ROOT/server/fleet_config_server.py" /opt/fleet-sync/
  install -m 0644 "$REPO_ROOT/systemd/fleet-config-server.service" /etc/systemd/system/

  if [[ ! -f /etc/fleet-sync/tokens.json ]]; then
    install -m 0600 "$REPO_ROOT/examples/tokens.json.example" /etc/fleet-sync/tokens.json
    echo "  wrote example /etc/fleet-sync/tokens.json — edit to add real tokens"
  fi
  chmod 0600 /etc/fleet-sync/tokens.json

  systemctl daemon-reload
  echo "  systemctl daemon-reloaded. Enable with:"
  echo "    systemctl enable --now fleet-config-server.service"
}

install_client() {
  echo "[fleet-sync] installing client..."
  install -d /opt/fleet-sync /etc/fleet-sync/manifest.d /var/lib/fleet-sync
  install -m 0755 "$REPO_ROOT/client/fleet-sync.sh" /opt/fleet-sync/
  install -m 0644 "$REPO_ROOT/systemd/fleet-sync.service" /etc/systemd/system/
  install -m 0644 "$REPO_ROOT/systemd/fleet-sync.timer" /etc/systemd/system/

  if [[ ! -f /etc/fleet-sync/client.conf ]]; then
    install -m 0644 "$REPO_ROOT/examples/client.conf.example" /etc/fleet-sync/client.conf
    echo "  wrote example /etc/fleet-sync/client.conf — edit for this host"
  fi

  if [[ ! -f /etc/fleet-sync/token ]]; then
    echo "  ACTION REQUIRED: create /etc/fleet-sync/token (mode 0400) with this host's bearer token"
  fi
  [[ -f /etc/fleet-sync/token ]] && chmod 0400 /etc/fleet-sync/token

  systemctl daemon-reload
  echo "  systemctl daemon-reloaded. Enable with:"
  echo "    systemctl enable --now fleet-sync.timer"
  echo "  Run once by hand with:"
  echo "    systemctl start fleet-sync.service"
}

case "$MODE" in
  server) install_server ;;
  client) install_client ;;
  both)   install_server; install_client ;;
  *)
    echo "Usage: $0 {server|client|both}" >&2
    exit 2
    ;;
esac

echo "[fleet-sync] done."
