#!/bin/sh
set -eu

SNIPE_ROOT="${SNIPE_ROOT:-/var/www/snipe-it}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/snipeit-autoinventory}"
STAMP="$(date +%Y%m%d-%H%M%S)"
MODEL_FILE="$SNIPE_ROOT/app/Models/Asset.php"
REQUEST_FILE="$SNIPE_ROOT/app/Http/Requests/UpdateAssetRequest.php"
BACKUP_DIR="$BACKUP_ROOT/nullable-asset-tags-$STAMP"

test "$(id -u)" -eq 0 || {
    echo "Run as root." >&2
    exit 1
}
test -f "$MODEL_FILE"
test -f "$REQUEST_FILE"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR"
cp -a "$MODEL_FILE" "$REQUEST_FILE" "$BACKUP_DIR/"

python3 - "$MODEL_FILE" "$REQUEST_FILE" <<'PY'
from pathlib import Path
import sys

model_path = Path(sys.argv[1])
request_path = Path(sys.argv[2])

model = model_path.read_text(encoding="utf-8")
old_model = "'asset_tag' => ['required', 'min:1', 'max:255', 'unique_undeleted:assets,asset_tag', 'not_array'],"
new_model = "'asset_tag' => ['nullable', 'min:1', 'max:255', 'unique_undeleted:assets,asset_tag', 'not_array'],"
if new_model not in model:
    if old_model not in model:
        raise SystemExit("Asset.php asset_tag rule was not recognized")
    model_path.write_text(model.replace(old_model, new_model, 1), encoding="utf-8")

request = request_path.read_text(encoding="utf-8")
old_request = "'asset_tag' => [\n                    'min:1', 'max:255', 'not_array',"
new_request = "'asset_tag' => [\n                    'nullable', 'min:1', 'max:255', 'not_array',"
if new_request not in request:
    if old_request not in request:
        raise SystemExit("UpdateAssetRequest.php asset_tag rule was not recognized")
    request_path.write_text(request.replace(old_request, new_request, 1), encoding="utf-8")
PY

php -l "$MODEL_FILE"
php -l "$REQUEST_FILE"

cd "$SNIPE_ROOT"
if id www-data >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
    runuser -u www-data -- php artisan optimize:clear
elif id www-data >/dev/null 2>&1; then
    su -s /bin/sh www-data -c 'php artisan optimize:clear'
else
    php artisan optimize:clear
fi

echo "Nullable asset tags configured. Backup: $BACKUP_DIR"
