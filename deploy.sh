#!/usr/bin/env bash
# Развёртывание решения одной командой на чистой Ubuntu 24.04.
#
# Полный цикл (узел, kubeadm, платформа):
#   ./deploy.sh
# Только содержимое кластера:
#   ./deploy.sh --tags platform
# Если sudo требует пароль:
#   ./deploy.sh -K
#
# Все аргументы передаются в ansible-playbook. Повторный запуск безопасен.
set -euo pipefail

cd "$(dirname "$0")"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Скрипт рассчитан на запуск на узле с Ubuntu 24.04" >&2
  exit 1
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo ">>> Устанавливаю Ansible"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ansible
fi

cd ansible
exec ansible-playbook site.yml "$@"
