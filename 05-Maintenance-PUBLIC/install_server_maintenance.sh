#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: su - then ./install_server_maintenance.sh" >&2
    exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INSTALL_DIR=/opt/snipeit-maintenance
CONFIG_DIR=/etc/snipeit-maintenance
STATE_DIR=/var/lib/snipeit-maintenance
LOG_DIR=/var/log/snipeit-maintenance
CONFIG_TARGET="$CONFIG_DIR/config.json"

/usr/bin/python3 -m py_compile \
    "$SCRIPT_DIR/snipeit_maintenance.py" \
    "$SCRIPT_DIR/test_snipeit_maintenance.py"
/usr/bin/php -l "$SCRIPT_DIR/list_terminated_users.php"

install -d -m 0755 "$INSTALL_DIR"
install -d -o root -g snipeit -m 0750 "$CONFIG_DIR"
install -d -o snipeit -g snipeit -m 0700 "$STATE_DIR" "$LOG_DIR"
install -o root -g root -m 0755 "$SCRIPT_DIR/snipeit_maintenance.py" "$INSTALL_DIR/snipeit_maintenance.py"
install -o root -g root -m 0755 "$SCRIPT_DIR/list_terminated_users.php" "$INSTALL_DIR/list_terminated_users.php"
install -o root -g root -m 0644 "$SCRIPT_DIR/snipeit-maintenance.service" /etc/systemd/system/snipeit-maintenance.service
install -o root -g root -m 0644 "$SCRIPT_DIR/snipeit-maintenance.timer" /etc/systemd/system/snipeit-maintenance.timer
install -o root -g root -m 0644 "$SCRIPT_DIR/snipeit-maintenance.logrotate" /etc/logrotate.d/snipeit-maintenance

if [ -f "$CONFIG_TARGET" ]; then
    cp -a "$CONFIG_TARGET" "$CONFIG_TARGET.backup-$(date +%Y%m%d-%H%M%S)"
fi
install -o root -g snipeit -m 0640 "$SCRIPT_DIR/config.example.json" "$CONFIG_TARGET"

(
    cd "$SCRIPT_DIR"
    /usr/bin/python3 -m unittest -v test_snipeit_maintenance.py
)

systemctl daemon-reload
/usr/sbin/runuser -u snipeit -- /usr/bin/python3 "$INSTALL_DIR/snipeit_maintenance.py" --config "$CONFIG_TARGET" --check-config
/usr/sbin/runuser -u snipeit -- /usr/bin/python3 "$INSTALL_DIR/snipeit_maintenance.py" --config "$CONFIG_TARGET" --check-ldap
/usr/sbin/runuser -u snipeit -- /usr/bin/python3 "$INSTALL_DIR/snipeit_maintenance.py" --config "$CONFIG_TARGET" --check-snipe
/usr/sbin/runuser -u snipeit -- /usr/bin/python3 "$INSTALL_DIR/snipeit_maintenance.py" --config "$CONFIG_TARGET" --dry-run

systemctl enable --now snipeit-maintenance.timer
systemctl status snipeit-maintenance.timer --no-pager

echo "SnipeIT Inventory Maintenance 1.3.3 is installed."
echo "The first live run only stages newly disabled users; deletion requires a second daily confirmation."
