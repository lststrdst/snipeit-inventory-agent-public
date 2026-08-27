#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG_SOURCE="$SCRIPT_DIR/config.json"
CONFIG_TARGET=/etc/snipeit-mail-relay/config.json
PYTHON=/usr/bin/python3
RELAY=/opt/snipeit-mail-relay/snipeit_mail_relay.py

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: su - then $0" >&2
    exit 1
fi

if [ ! -f "$CONFIG_SOURCE" ]; then
    echo "Secure config is missing: $CONFIG_SOURCE" >&2
    exit 1
fi

systemctl stop snipeit-mail-relay.timer 2>/dev/null || true
systemctl stop snipeit-mail-relay.service 2>/dev/null || true

if [ -f "$CONFIG_TARGET" ]; then
    cp -a "$CONFIG_TARGET" "$CONFIG_TARGET.backup-$(date +%Y%m%d-%H%M%S)"
fi

(
    cd "$SCRIPT_DIR"
    "$PYTHON" -m py_compile snipeit_mail_relay.py test_snipeit_mail_relay.py
    "$PYTHON" -m unittest -v
)

chmod +x "$SCRIPT_DIR/configure_snipeit_timezone.sh" "$SCRIPT_DIR/install_server_relay.sh"
"$SCRIPT_DIR/configure_snipeit_timezone.sh"
"$SCRIPT_DIR/install_server_relay.sh"
install -o root -g snipeit -m 0640 "$CONFIG_SOURCE" "$CONFIG_TARGET"

/usr/sbin/runuser -u snipeit -- "$PYTHON" "$RELAY" --config "$CONFIG_TARGET" --check-config
/usr/sbin/runuser -u snipeit -- "$PYTHON" "$RELAY" --config "$CONFIG_TARGET" --check-imap
/usr/sbin/runuser -u snipeit -- "$PYTHON" "$RELAY" --config "$CONFIG_TARGET" --check-snipe

systemctl enable --now snipeit-mail-relay.timer
if ! systemctl start snipeit-mail-relay.service; then
    journalctl -u snipeit-mail-relay.service -n 100 --no-pager
    exit 1
fi

systemctl status snipeit-mail-relay.timer --no-pager
journalctl -u snipeit-mail-relay.service -n 50 --no-pager
echo "SnipeIT Inventory Relay 1.3.3 is installed and active."
