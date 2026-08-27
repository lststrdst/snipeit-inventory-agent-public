#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo ./install_server_relay.sh" >&2
    exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INSTALL_DIR=/opt/snipeit-mail-relay
CONFIG_DIR=/etc/snipeit-mail-relay
STATE_DIR=/var/lib/snipeit-mail-relay
LOG_DIR=/var/log/snipeit-mail-relay

install -d -m 0755 "$INSTALL_DIR"
install -d -o root -g snipeit -m 0750 "$CONFIG_DIR"
install -d -o snipeit -g snipeit -m 0700 "$STATE_DIR" "$LOG_DIR"
install -o root -g root -m 0755 "$SCRIPT_DIR/snipeit_mail_relay.py" "$INSTALL_DIR/snipeit_mail_relay.py"
install -o root -g root -m 0755 "$SCRIPT_DIR/configure_snipeit_timezone.sh" "$INSTALL_DIR/configure_snipeit_timezone.sh"
install -o root -g root -m 0644 "$SCRIPT_DIR/snipeit-mail-relay.service" /etc/systemd/system/snipeit-mail-relay.service
install -o root -g root -m 0644 "$SCRIPT_DIR/snipeit-mail-relay.timer" /etc/systemd/system/snipeit-mail-relay.timer
install -o root -g root -m 0644 "$SCRIPT_DIR/snipeit-mail-relay.logrotate" /etc/logrotate.d/snipeit-mail-relay

if [ ! -f "$CONFIG_DIR/config.json" ]; then
    install -o root -g snipeit -m 0640 "$SCRIPT_DIR/config.example.json" "$CONFIG_DIR/config.json"
    echo "Created $CONFIG_DIR/config.json. Fill secrets before enabling the timer."
else
    echo "Kept existing $CONFIG_DIR/config.json."
fi

systemctl daemon-reload
echo "Validate: runuser -u snipeit -- /usr/bin/python3 $INSTALL_DIR/snipeit_mail_relay.py --config $CONFIG_DIR/config.json --check-config"
echo "IMAP:     runuser -u snipeit -- /usr/bin/python3 $INSTALL_DIR/snipeit_mail_relay.py --config $CONFIG_DIR/config.json --check-imap"
echo "Snipe:    runuser -u snipeit -- /usr/bin/python3 $INSTALL_DIR/snipeit_mail_relay.py --config $CONFIG_DIR/config.json --check-snipe"
echo "Enable:   systemctl enable --now snipeit-mail-relay.timer"
