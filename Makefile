.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help deploy cluster platform verify info load status lint destroy

help: ## Показать список команд
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

deploy: ## Полное развёртывание: узел -> kubeadm -> платформа -> приложение
	./deploy.sh

cluster: ## Только подготовка узла и создание кластера kubeadm
	./deploy.sh --tags cluster

platform: ## Только содержимое кластера (Gateway, мониторинг, логи, приложение)
	./deploy.sh --tags platform

verify: ## Smoke-тесты: Gateway API, мониторинг, логирование
	./scripts/verify.sh

info: ## Адреса сервисов и учётные данные
	./scripts/info.sh

load: ## Сгенерировать тестовый трафик
	./scripts/load.sh 300

status: ## Состояние узлов, подов и ресурсов Gateway API
	kubectl get nodes -o wide
	kubectl get pods -A
	kubectl get gatewayclass,gateway,httproute -A

lint: ## Статические проверки (yamllint, shellcheck, kustomize build, ansible syntax)
	yamllint .
	shellcheck deploy.sh scripts/*.sh
	kubectl kustomize k8s >/dev/null
	cd ansible && ansible-playbook site.yml --syntax-check

destroy: ## Удалить кластер с узла (kubeadm reset)
	./scripts/destroy.sh
