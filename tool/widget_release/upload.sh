#!/usr/bin/env bash
# Загрузка выпуска веб-помощника в Yandex Object Storage (необязательно:
# то же можно сделать в консоли Yandex Cloud руками, см. README.md).
#
#   SVYAZNOY_BUCKET=svyaznoy-web \
#   AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… \
#   tool/widget_release/upload.sh build/widget_release/1.0.0
#
# Ключи доступа — только из окружения, в репозиторий и в вывод не
# попадают. Сначала архив (неизменный, кэш на год), последним latest.json
# (без кэша): склад не увидит новую версию раньше, чем её архив.
set -euo pipefail

dir="${1:-}"
if [[ -z "$dir" || ! -f "$dir/latest.json" ]]; then
  echo "Нужна папка выпуска с latest.json: build/widget_release/<версия>" >&2
  exit 64
fi
: "${SVYAZNOY_BUCKET:?Задайте SVYAZNOY_BUCKET — имя бакета}"
: "${AWS_ACCESS_KEY_ID:?Задайте AWS_ACCESS_KEY_ID — ключ сервисного аккаунта}"
: "${AWS_SECRET_ACCESS_KEY:?Задайте AWS_SECRET_ACCESS_KEY — секрет ключа}"
prefix="${SVYAZNOY_PREFIX:-svyaznoy-web}"
endpoint="${SVYAZNOY_ENDPOINT:-https://storage.yandexcloud.net}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ru-central1}"

command -v aws >/dev/null || { echo "Нужен aws-cli (pip install awscli)" >&2; exit 69; }

shopt -s nullglob
zips=("$dir"/svyaznoy-web-*.zip)
if (( ${#zips[@]} != 1 )); then
  echo "В $dir должен быть ровно один svyaznoy-web-*.zip" >&2
  exit 65
fi
zip="${zips[0]}"

aws s3 cp "$zip" "s3://$SVYAZNOY_BUCKET/$prefix/$(basename "$zip")" \
  --endpoint-url "$endpoint" \
  --content-type application/zip \
  --cache-control "public, max-age=31536000, immutable"

aws s3 cp "$dir/latest.json" "s3://$SVYAZNOY_BUCKET/$prefix/latest.json" \
  --endpoint-url "$endpoint" \
  --content-type "application/json; charset=utf-8" \
  --cache-control "no-cache, max-age=0"

echo "Загружено. Адрес для «Источник обновлений» на складе (если бакет не svyaznoy-web):"
echo "  $endpoint/$SVYAZNOY_BUCKET/$prefix/latest.json"
