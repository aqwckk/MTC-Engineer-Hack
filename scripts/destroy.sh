#!/usr/bin/env bash
# Полное удаление кластера с узла (kubeadm reset). Данные кластера будут потеряны.
set -euo pipefail

if [ "${1:-}" != "--yes" ]; then
  read -r -p "Удалить кластер Kubernetes с этого узла? [y/N] " answer
  [ "$answer" = "y" ] || exit 0
fi

sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /etc/kubernetes /var/lib/etcd /var/lib/cni /opt/local-path-provisioner \
  /var/log/fluentd-buffers /var/log/fluentd-demo-*.pos
sudo ip link delete cilium_host 2>/dev/null || true
sudo ip link delete cilium_vxlan 2>/dev/null || true
sudo systemctl restart containerd
rm -f "$HOME/.kube/config"
echo "Кластер удалён. Повторное развёртывание: ./deploy.sh"
