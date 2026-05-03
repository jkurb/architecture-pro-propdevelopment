#!/usr/bin/env bash
# 01-deploy-pods.sh — развёртывание 4 nginx-подов с метками role=
# и сервисами поверх (через `kubectl run --expose`).
#
# Каждая команда из задания:
#   kubectl run front-end-app --image=nginx --labels role=front-end --expose --port 80
#
# Использование:
#   ./01-deploy-pods.sh                # в namespace default
#   NS=task5 ./01-deploy-pods.sh       # в произвольном namespace

set -euo pipefail

NS="${NS:-default}"

if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  echo "==> создание namespace: $NS"
  kubectl create namespace "$NS"
fi

run_pod() {
  local name="$1" role="$2"
  echo "==> ${name} (role=${role})"
  kubectl -n "$NS" run "$name" \
    --image=nginx \
    --labels="role=${role}" \
    --expose \
    --port=80
}

run_pod front-end-app          front-end
run_pod back-end-api-app       back-end-api
run_pod admin-front-end-app    admin-front-end
run_pod admin-back-end-api-app admin-back-end-api

echo
echo "Ожидаем готовности подов..."
kubectl -n "$NS" wait --for=condition=Ready pod \
  -l 'role in (front-end,back-end-api,admin-front-end,admin-back-end-api)' \
  --timeout=120s

echo
echo "Поды и сервисы:"
kubectl -n "$NS" get pods -l 'role in (front-end,back-end-api,admin-front-end,admin-back-end-api)' --show-labels
echo
kubectl -n "$NS" get svc front-end-app back-end-api-app admin-front-end-app admin-back-end-api-app
