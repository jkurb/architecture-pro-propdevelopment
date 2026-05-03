#!/usr/bin/env bash
# 00-setup-minikube.sh — пересоздание minikube с включённым audit-логом.
#
# Шаги:
#   1. Удалить текущий minikube (audit нельзя добавить в работающий API server)
#   2. Запустить minikube с CNI calico (нужен для Task 5) и нужными extra-config'ами
#   3. Скопировать audit-policy.yaml в /etc/kubernetes/audit-policy.yaml внутрь ноды
#   4. Перезапустить (stop+start), чтобы kube-apiserver подхватил policy
#
# ВНИМАНИЕ: пересоздание minikube удалит всё из предыдущих заданий (Task 4, Task 5).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_FILE="${SCRIPT_DIR}/audit-policy.yaml"

if [[ ! -f "$POLICY_FILE" ]]; then
  echo "ERROR: Не найден ${POLICY_FILE}" >&2
  exit 1
fi

echo "==> 1. Удаляем текущий minikube"
minikube delete || true

echo "==> 2. Запускаем minikube без audit (чтобы создать ноду)"
minikube start --cni=calico

echo "==> 3. Копируем audit-policy.yaml в ноду"
minikube cp "$POLICY_FILE" /etc/kubernetes/audit-policy.yaml
minikube ssh -- "sudo chmod 0644 /etc/kubernetes/audit-policy.yaml && ls -la /etc/kubernetes/audit-policy.yaml"

echo "==> 4. Останавливаем minikube"
minikube stop

echo "==> 5. Запускаем minikube с включённым audit-логом"
minikube start \
  --cni=calico \
  --extra-config=apiserver.audit-policy-file=/etc/kubernetes/audit-policy.yaml \
  --extra-config=apiserver.audit-log-path=/var/log/audit.log \
  --extra-config=apiserver.audit-log-maxage=30 \
  --extra-config=apiserver.audit-log-maxsize=100 \
  --extra-config=apiserver.audit-log-maxbackup=5

echo "==> 6. Проверяем, что audit-лог пишется"
sleep 5
minikube ssh -- "sudo ls -la /var/log/audit.log && echo '--- последние 3 события ---' && sudo tail -3 /var/log/audit.log | jq -c '{ts: .requestReceivedTimestamp, user: .user.username, verb, resource: .objectRef.resource}' || sudo tail -3 /var/log/audit.log"

echo
echo "Готово. Audit-лог пишется в /var/log/audit.log внутри ноды minikube."
echo "Прочитать: minikube ssh -- sudo cat /var/log/audit.log"
echo "Скопировать на хост: minikube cp minikube:/var/log/audit.log ./audit.log"
