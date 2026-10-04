#!/usr/bin/env bash
# Адреса и учётные данные развёрнутого решения.
set -euo pipefail

NODE_IP="${NODE_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}"
grafana_password=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)

cat <<INFO
Узел: ${NODE_IP}

Приложение (HTTP):   curl http://${NODE_IP}:30080/
Приложение (HTTPS):  curl -k --resolve app.demo.local:30443:${NODE_IP} https://app.demo.local:30443/
Grafana:             https://grafana.demo.local:30443     (admin / ${grafana_password})
Prometheus:          https://prometheus.demo.local:30443

Для доступа из браузера добавьте в /etc/hosts:
  ${NODE_IP} app.demo.local grafana.demo.local prometheus.demo.local

Корневой сертификат решения (для доверия HTTPS):
  kubectl -n edge get secret demo-local-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > demo-ca.crt
INFO
