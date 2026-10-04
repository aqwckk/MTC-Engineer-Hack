#!/usr/bin/env bash
# Smoke-тесты решения: кластер, Gateway API, мониторинг, логирование.
# Код возврата 0 — все проверки пройдены.
set -uo pipefail

HTTP_PORT=30080
HTTPS_PORT=30443
NODE_IP="${NODE_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}"

PASS=0
FAIL=0
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
ok()    { PASS=$((PASS + 1)); green "  [PASS] $*"; }
fail()  { FAIL=$((FAIL + 1)); red "  [FAIL] $*"; }
# Использование: check "описание" команда...
check() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name"; fi
}
section() { printf '\n== %s ==\n' "$*"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Запрос к Prometheus через Gateway (HTTPS, сертификат проверяется по CA решения)
prom_query() {
  curl -fsS --max-time 10 --cacert "$TMP/ca.crt" \
    --resolve "prometheus.demo.local:${HTTPS_PORT}:${NODE_IP}" \
    "https://prometheus.demo.local:${HTTPS_PORT}/api/v1/query" \
    --data-urlencode "query=$1"
}
# true, если запрос вернул хотя бы один ряд со значением > 0
prom_positive() {
  prom_query "$1" | jq -e '[.data.result[].value[1] | tonumber] | map(select(. > 0)) | length > 0'
}
# Запрос к Elasticsearch изнутри пода (пароль берётся из окружения контейнера)
es_count() {
  kubectl -n logging exec elasticsearch-0 -c elasticsearch -- sh -c \
    "curl -fsS -u \"elastic:\${ELASTIC_PASSWORD}\" 'http://127.0.0.1:9200/$1/_count?q=$2'" | jq -r '.count'
}
# Использование: wait_for <секунд> команда...
wait_for() {
  local deadline=$((SECONDS + $1)); shift
  until "$@" >/dev/null 2>&1; do
    [ $SECONDS -ge $deadline ] && return 1
    sleep 5
  done
}

section "1. Кластер Kubernetes"
echo "  узел: ${NODE_IP}, версия: $(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion')"
check "все узлы в состоянии Ready" \
  kubectl wait node --all --for=condition=Ready --timeout=60s
check "приложение web-v1 развёрнуто" \
  kubectl -n demo rollout status deploy/web-v1 --timeout=120s
check "приложение web-v2 развёрнуто" \
  kubectl -n demo rollout status deploy/web-v2 --timeout=120s

section "2. Gateway API"
check "GatewayClass envoy принят контроллером" \
  kubectl wait gatewayclass/envoy --for=condition=Accepted --timeout=60s
check "Gateway demo-gateway запрограммирован" \
  kubectl -n edge wait gateway/demo-gateway --for=condition=Programmed --timeout=120s

body=$(curl -fsS --max-time 10 "http://${NODE_IP}:${HTTP_PORT}/" 2>/dev/null)
if [ "$body" = "Hello World!" ]; then ok "HTTP через Gateway: curl http://${NODE_IP}:${HTTP_PORT}/ -> '${body}'"
else fail "HTTP через Gateway: ожидалось 'Hello World!', получено '${body}'"; fi

body=$(curl -fsS --max-time 10 -H 'Host: app.demo.local' "http://${NODE_IP}:${HTTP_PORT}/v2" 2>/dev/null)
if [[ "$body" == *"v2 canary"* ]]; then ok "маршрутизация по hostname + path (/v2 -> web-v2)"
else fail "маршрутизация по path /v2: получено '${body}'"; fi

body=$(curl -fsS --max-time 10 -H 'Host: app.demo.local' "http://${NODE_IP}:${HTTP_PORT}/v1" 2>/dev/null)
if [ "$body" = "Hello World!" ]; then ok "маршрутизация по hostname + path (/v1 -> web-v1)"
else fail "маршрутизация по path /v1: получено '${body}'"; fi

body=$(curl -fsS --max-time 10 -H 'Host: app.demo.local' -H 'X-Canary: true' "http://${NODE_IP}:${HTTP_PORT}/" 2>/dev/null)
if [[ "$body" == *"v2 canary"* ]]; then ok "маршрутизация по заголовку (X-Canary: true -> web-v2)"
else fail "маршрутизация по заголовку: получено '${body}'"; fi

kubectl -n edge get secret demo-local-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$TMP/ca.crt"
body=$(curl -fsS --max-time 10 --cacert "$TMP/ca.crt" \
  --resolve "app.demo.local:${HTTPS_PORT}:${NODE_IP}" "https://app.demo.local:${HTTPS_PORT}/v1" 2>/dev/null)
if [ "$body" = "Hello World!" ]; then ok "TLS: HTTPS-listener с сертификатом cert-manager (проверка по CA)"
else fail "TLS: получено '${body}'"; fi

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Host: grafana.demo.local' "http://${NODE_IP}:${HTTP_PORT}/")
if [ "$code" = "301" ]; then ok "редирект HTTP -> HTTPS для служебных хостов (301)"
else fail "редирект HTTP -> HTTPS: код ${code}"; fi

v1=0; v2=0
for _ in $(seq 1 100); do
  r=$(curl -s --max-time 5 -H 'Host: app.demo.local' "http://${NODE_IP}:${HTTP_PORT}/")
  if [[ "$r" == *"v2 canary"* ]]; then v2=$((v2 + 1)); elif [ "$r" = "Hello World!" ]; then v1=$((v1 + 1)); fi
done
if [ "$v1" -gt "$v2" ] && [ "$v2" -gt 0 ] && [ $((v1 + v2)) -eq 100 ]; then
  ok "traffic splitting 90/10: из 100 запросов v1=${v1}, v2=${v2}"
else
  fail "traffic splitting: v1=${v1}, v2=${v2}"
fi

section "3. Мониторинг (Prometheus)"
check "Prometheus отвечает через Gateway (HTTPS)" prom_query 'up'
# после (пере)запуска подов целям нужно до пары интервалов опроса, чтобы стать UP
all_targets_up() { [ "$(prom_query 'count(up == 0) or vector(0)' | jq -r '.data.result[0].value[1]')" = "0" ]; }
if wait_for 180 all_targets_up; then
  ok "все targets Prometheus в состоянии UP ($(prom_query 'count(up)' | jq -r '.data.result[0].value[1]') шт.)"
else
  fail "есть targets в состоянии DOWN: $(prom_query 'up == 0' | jq -c '[.data.result[].metric.job]')"
fi
check "метрики приложения: nginx_up{namespace=\"demo\"}" \
  wait_for 90 prom_positive 'nginx_up{namespace="demo"}'
check "метрики приложения: nginx_http_requests_total растёт" \
  wait_for 90 prom_positive 'sum(nginx_http_requests_total{namespace="demo"})'
check "HTTP-метрики Gateway: envoy_http_downstream_rq_xx (коды ответов)" \
  wait_for 90 prom_positive 'sum(envoy_http_downstream_rq_xx{envoy_response_code_class="2"})'
check "метрики инфраструктуры: node-exporter, kube-state-metrics, kubelet" \
  prom_positive 'count(node_cpu_seconds_total) * count(kube_pod_info) * count(container_memory_working_set_bytes)'
check "метрики control-plane: apiserver, etcd, scheduler, controller-manager" \
  prom_positive 'min(up{job=~"apiserver|kube-etcd|kube-scheduler|kube-controller-manager"})'

section "4. Логирование (Fluentd -> Elasticsearch)"
check "Fluentd DaemonSet готов" kubectl -n logging rollout status ds/fluentd --timeout=120s
check "Elasticsearch готов" kubectl -n logging rollout status sts/elasticsearch --timeout=120s

# метка — одно слово из букв и цифр, чтобы анализатор Elasticsearch не разбил её на части
marker="smoke$(date +%s)x$RANDOM"
curl -s -o /dev/null --max-time 10 "http://${NODE_IP}:${HTTP_PORT}/?check=${marker}"
curl -s -o /dev/null --max-time 10 "http://${NODE_IP}:${HTTP_PORT}/missing-${marker}"
echo "  отправлены запросы с меткой ${marker}, ожидаю появления в Elasticsearch..."

access_found() { [ "$(es_count 'app-logs-*' "log_type:access%20AND%20uri:${marker}")" -ge 2 ]; }
error_found()  { [ "$(es_count 'app-logs-*' "log_type:error%20AND%20message:${marker}")" -ge 1 ]; }
gw_found()     { [ "$(es_count 'gateway-logs-*' "log_type:gateway%20AND%20path:${marker}")" -ge 1 ]; }

check "access-лог: запросы найдены в индексе app-logs-*" wait_for 120 access_found
check "error-лог: запись о 404 найдена в индексе app-logs-*" wait_for 60 error_found
check "access-лог Gateway найден в индексе gateway-logs-*" wait_for 60 gw_found

printf '\nИтог: %s пройдено, %s не пройдено\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
