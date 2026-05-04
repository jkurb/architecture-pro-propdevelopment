#!/usr/bin/env bash
# verify-admission.sh — проверка PodSecurity Admission (PSA, restricted level).
#
# Не требует Gatekeeper. Просто:
#   1. Создаёт namespace audit-zone (если ещё нет)
#   2. Прогоняет insecure-манифесты через `kubectl apply --dry-run=server`
#      — должны быть отклонены PSA-вебхуком ядра Kubernetes
#   3. То же для secure-манифестов — должны пройти

set -uo pipefail

cd "$(dirname "$0")/.."

NS="audit-zone"

echo "==> Создаём namespace ${NS} (если ещё нет)"
kubectl apply -f 01-create-namespace.yaml

run_test() {
  local label="$1" file="$2" expected="$3"
  printf "  %-45s " "$label"
  out=$(kubectl apply -f "$file" --dry-run=server 2>&1)
  rc=$?
  if [[ $rc -ne 0 ]] || echo "$out" | grep -qiE 'forbidden|denied|violates|policy'; then
    actual="DENIED"
  else
    actual="ALLOWED"
  fi
  if [[ "$actual" == "$expected" ]]; then
    echo "✓ ${actual}"
  else
    echo "✗ Expected ${expected}, got ${actual}"
    echo "      $(echo "$out" | head -1)"
  fi
}

echo
echo "=== INSECURE — должны быть отклонены PSA ==="
run_test "01 privileged: true"        insecure-manifests/01-privileged-pod.yaml DENIED
run_test "02 hostPath /"              insecure-manifests/02-hostpath-pod.yaml   DENIED
run_test "03 runAsUser: 0"            insecure-manifests/03-root-user-pod.yaml  DENIED

echo
echo "=== SECURE — должны пройти PSA ==="
run_test "01-secure (restricted)"     secure-manifests/01-secure.yaml ALLOWED
run_test "02-secure (emptyDir)"       secure-manifests/02-secure.yaml ALLOWED
run_test "03-secure (non-root)"       secure-manifests/03-secure.yaml ALLOWED
