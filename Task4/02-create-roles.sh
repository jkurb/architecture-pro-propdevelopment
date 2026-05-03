#!/usr/bin/env bash
# 02-create-roles.sh — создание namespaces по доменам и custom RBAC-ролей.
#
# Создаются:
#   - 4 namespace'а (domain-sales, domain-zhku, domain-finance, domain-data)
#   - ClusterRole: security-auditor, cluster-viewer, cluster-configurator
#   - Role: domain-developer (по одной в каждом domain-* namespace)
#
# Built-in роль cluster-admin не создаётся — она поставляется Kubernetes.
#
# Использование (после `minikube start`):
#   ./02-create-roles.sh

set -euo pipefail

# === Namespaces по доменам ===
for ns in domain-sales domain-zhku domain-finance domain-data; do
  echo "==> namespace: ${ns}"
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
done

# === ClusterRole: security-auditor (привилегированный read-only с доступом к secrets) ===
echo "==> ClusterRole: security-auditor"
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: security-auditor
  labels:
    rbac.propdevelopment.io/scope: cluster
    rbac.propdevelopment.io/sensitivity: privileged
rules:
  # Чтение всех ключевых ресурсов (включая secrets — это особенность роли)
  - apiGroups: [""]
    resources:
      - secrets
      - configmaps
      - namespaces
      - pods
      - pods/log
      - services
      - serviceaccounts
      - persistentvolumes
      - persistentvolumeclaims
      - nodes
      - events
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
  # RBAC-объекты — для аудита прав доступа
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs: ["get", "list", "watch"]
  # Сетевые политики и ingress
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies", "ingresses", "ingressclasses"]
    verbs: ["get", "list", "watch"]
  # Политики безопасности подов / лимиты / квоты
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["resourcequotas", "limitranges"]
    verbs: ["get", "list", "watch"]
  # Storage
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses", "volumeattachments"]
    verbs: ["get", "list", "watch"]
EOF

# === ClusterRole: cluster-viewer (read-only БЕЗ secrets и БЕЗ RBAC) ===
echo "==> ClusterRole: cluster-viewer"
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-viewer
  labels:
    rbac.propdevelopment.io/scope: cluster
    rbac.propdevelopment.io/sensitivity: read-only
rules:
  - apiGroups: [""]
    resources:
      - pods
      - pods/log
      - services
      - configmaps
      - namespaces
      - persistentvolumes
      - persistentvolumeclaims
      - nodes
      - events
      - serviceaccounts
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses", "networkpolicies"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  # ВНИМАНИЕ: secrets и RBAC-объекты сюда НЕ включены — это привилегия security-auditor.
EOF

# === ClusterRole: cluster-configurator (cluster-level настройки БЕЗ secrets и БЕЗ RBAC) ===
echo "==> ClusterRole: cluster-configurator"
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-configurator
  labels:
    rbac.propdevelopment.io/scope: cluster
    rbac.propdevelopment.io/sensitivity: configure
rules:
  # Cluster-level конфигурация
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses", "ingressclasses", "networkpolicies"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["resourcequotas", "limitranges", "namespaces"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["scheduling.k8s.io"]
    resources: ["priorityclasses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Read-only по workloads чтобы видеть, на что влияют политики и квоты
  - apiGroups: ["", "apps", "batch"]
    resources:
      - pods
      - services
      - configmaps
      - deployments
      - statefulsets
      - daemonsets
      - jobs
      - cronjobs
    verbs: ["get", "list", "watch"]
  # ВНИМАНИЕ: secrets и RBAC-объекты осознанно исключены, чтобы исключить
  # возможность само-эскалации до cluster-admin.
EOF

# === Role: domain-developer в каждом domain-* namespace ===
for ns in domain-sales domain-zhku domain-finance domain-data; do
  echo "==> Role: domain-developer (ns: ${ns})"
  kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: domain-developer
  namespace: ${ns}
  labels:
    rbac.propdevelopment.io/scope: namespace
    rbac.propdevelopment.io/sensitivity: develop
rules:
  # CRUD по рабочим нагрузкам и связанным ресурсам внутри своего namespace
  - apiGroups: [""]
    resources:
      - pods
      - pods/log
      - pods/exec
      - pods/portforward
      - services
      - configmaps
      - persistentvolumeclaims
      - serviceaccounts
      - events
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses", "networkpolicies"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Просмотр RBAC своего namespace (полезно для отладки прав, без права изменять)
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["roles", "rolebindings"]
    verbs: ["get", "list", "watch"]
  # ВНИМАНИЕ: secrets отсутствуют — секреты можно использовать в манифестах
  # (envFrom/volumeMount), но значения недоступны через 'kubectl get secret'.
EOF
done

echo
echo "Готово. Список созданных RBAC-объектов:"
kubectl get clusterrole security-auditor cluster-viewer cluster-configurator
echo
for ns in domain-sales domain-zhku domain-finance domain-data; do
  kubectl -n "$ns" get role domain-developer
done
