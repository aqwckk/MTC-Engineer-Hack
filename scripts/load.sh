#!/usr/bin/env bash
# Генерация тестового трафика (наполняет метрики, дашборд и логи).
#   ./scripts/load.sh [количество_запросов]
set -euo pipefail

COUNT="${1:-300}"
NODE_IP="${NODE_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}"
URL="http://${NODE_IP}:30080"

for i in $(seq 1 "$COUNT"); do
  # каждый десятый запрос — несуществующий путь (404), ещё каждый десятый — /v2
  case $((i % 10)) in
    0) path="/not-found-$i" ;;
    1) path="/v2" ;;
    *) path="/" ;;
  esac
  curl -s -o /dev/null -H 'Host: app.demo.local' "${URL}${path}"
done
echo "Отправлено запросов: ${COUNT}"
