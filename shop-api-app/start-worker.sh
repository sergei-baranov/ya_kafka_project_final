#!/bin/sh
set -eu
sleep 2
cd /app
exec python -m shop_api worker -l INFO -p "${SHOP_API_WEB_PORT:-6077}"
