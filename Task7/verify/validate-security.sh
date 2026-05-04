#!/usr/bin/env bash
# validate-security.sh — установка Gatekeeper и проверка constraint'ов.
#
# Шаги:
#   1. Установить Gatekeeper (если ещё нет)
#   2. Применить ConstraintTemplate'ы (создают CRD)
#   3. Применить Constraint'ы (привязка к namespace audit-zone)
#   4. Прогнать insecure/secure манифесты через --dry-run=server и проверить
#      что Gatekeeper webhook отклоняет/пропускает их по правилам.

set -uo pipefail

cd "$(dirname "$0")/.."

GATEKEEPER_VERSION="release-3.16"
GATEKEEPER_URL="https://raw.githubusercontent.com/open-policy-agent/gatekeeper/${GATEKEEPER_VERSION}/deploy/gatekeeper.yaml"

echo "==> 1/4 Проверка / установка Gatekeeper"
if ! kubectl get ns gatekeeper-system >/dev/null 2>&1; then
  echo "    устанавливаем Gatekeeper ${GATEKEEPER_VERSION}"
  kubectl apply -f "${GATEKEEPER_URL}"
else
  echo "    уже установлен"
fi

echo "    ждём готовности controller-manager..."
kubectl rollout status deployment/gatekeeper-controller-manager -n gatekeeper-system --timeout=180s
kubectl rollout status deployment/gatekeeper-audit -n gatekeeper-system --timeout=180s 2>/dev/null || true

echo
echo "==> 2/4 Создаём namespace audit-zone (если ещё нет)"
kubectl apply -f 01-create-namespace.yaml

echo
echo "==> 3/4 Применяем ConstraintTemplate'ы"
kubectl apply -f gatekeeper/constraint-templates/
echo "    ждём пока CRD'ы появятся..."
for crd in k8spsprivileged k8spshostpath k8spsrunasnonroot; do
  for i in $(seq 1 30); do
    if kubectl get crd "${crd}.constraints.gatekeeper.sh" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
done
sleep 5  # дать Gatekeeper'у инициализировать Rego

echo
echo "==> 4/4 Применяем Constraint'ы"
kubectl apply -f gatekeeper/constraints/
sleep 5

run_test() {
  local label="$1" file="$2" expected="$3"
  printf "  %-45s " "$label"
  out=$(kubectl apply -f "$file" --dry-run=server 2>&1)
  rc=$?
  if [[ $rc -ne 0 ]] || echo "$out" | grep -qiE 'denied|forbidden|violates|policy'; then
    actual="DENIED"
  else
    actual="ALLOWED"
  fi
  if [[ "$actual" == "$expected" ]]; then
    echo "✓ ${actual}"
  else
    echo "✗ Expected ${expected}, got ${actual}"
    echo "      $(echo "$out" | head -2 | tr '\n' ' ')"
  fi
}

echo
echo "=== INSECURE — должны быть отклонены (PSA + Gatekeeper) ==="
run_test "01 privileged: true"        insecure-manifests/01-privileged-pod.yaml DENIED
run_test "02 hostPath /"              insecure-manifests/02-hostpath-pod.yaml   DENIED
run_test "03 runAsUser: 0"            insecure-manifests/03-root-user-pod.yaml  DENIED

echo
echo "=== SECURE — должны пройти ==="
run_test "01-secure (restricted)"     secure-manifests/01-secure.yaml ALLOWED
run_test "02-secure (emptyDir)"       secure-manifests/02-secure.yaml ALLOWED
run_test "03-secure (non-root)"       secure-manifests/03-secure.yaml ALLOWED

echo
echo "=== Активные Gatekeeper Constraint'ы ==="
kubectl get k8spsprivileged.constraints.gatekeeper.sh,k8spshostpath.constraints.gatekeeper.sh,k8spsrunasnonroot.constraints.gatekeeper.sh -o custom-columns=NAME:.metadata.name,KIND:.kind 2>/dev/null || true
