#!/bin/sh
set -eu

APP_ROOT=${1:-/var/www/snipe-it}
TIMEZONE=${2:-Europe/Moscow}
ENV_FILE="$APP_ROOT/.env"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: su - then $0" >&2
    exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "Snipe-IT .env was not found: $ENV_FILE" >&2
    exit 1
fi

timedatectl set-timezone "$TIMEZONE"

if ! grep -q "^APP_TIMEZONE='$TIMEZONE'$" "$ENV_FILE"; then
    cp -a "$ENV_FILE" "$ENV_FILE.timezone-backup"
    if grep -q '^APP_TIMEZONE=' "$ENV_FILE"; then
        sed -i "s|^APP_TIMEZONE=.*|APP_TIMEZONE='$TIMEZONE'|" "$ENV_FILE"
    else
        printf "\nAPP_TIMEZONE='%s'\n" "$TIMEZONE" >> "$ENV_FILE"
    fi
    chown --reference="$ENV_FILE.timezone-backup" "$ENV_FILE"
    chmod --reference="$ENV_FILE.timezone-backup" "$ENV_FILE"
fi

cd "$APP_ROOT"
/usr/sbin/runuser -u snipeit -- /usr/bin/php artisan config:clear

echo "OS timezone: $(timedatectl show --property=Timezone --value)"
echo "Snipe-IT: $(grep '^APP_TIMEZONE=' "$ENV_FILE")"
date --iso-8601=seconds
