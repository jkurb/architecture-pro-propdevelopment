#!/usr/bin/env bash
# 03-bind-users.sh — связывает группы пользователей с RBAC-ролями.
#
# Все binding'и используют тип subject = Group. Конкретные пользователи
# (alice, bob, ...) автоматически попадают в нужную группу через поле O=
# в их клиентских сертификатах (см. 01-create-users.sh).
#
# Использование:
#   ./03-bind-users.sh

set -euo pipefail

# === 1. cluster-admins → cluster-admin (built-in) ===
echo "==> ClusterRoleBinding: cluster-admins → cluster-admin"
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: propdev-cluster-admins
subjects:
  - kind: Group
    name: cluster-admins
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

# === 2. security → security-auditor ===
echo "==> ClusterRoleBinding: security → security-auditor"
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: propdev-security
subjects:
  - kind: Group
    name: security
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: security-auditor
  apiGroup: rbac.authorization.k8s.io
EOF

# === 3. cluster-viewers → cluster-viewer ===
echo "==> ClusterRoleBinding: cluster-viewers → cluster-viewer"
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: propdev-cluster-viewers
subjects:
  - kind: Group
    name: cluster-viewers
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-viewer
  apiGroup: rbac.authorization.k8s.io
EOF

# === 4. cluster-configurators → cluster-configurator ===
echo "==> ClusterRoleBinding: cluster-configurators → cluster-configurator"
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: propdev-cluster-configurators
subjects:
  - kind: Group
    name: cluster-configurators
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-configurator
  apiGroup: rbac.authorization.k8s.io
EOF

# === 5. Доменные группы → Role domain-developer в своём namespace ===
declare -a DOMAIN_PAIRS=(
  "sales-developers:domain-sales"
  "zhku-developers:domain-zhku"
  "finance-developers:domain-finance"
  "data-developers:domain-data"
)

for pair in "${DOMAIN_PAIRS[@]}"; do
  group="${pair%%:*}"
  ns="${pair##*:}"

  echo "==> RoleBinding: ${group} → domain-developer (ns: ${ns})"
  kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: propdev-${group}
  namespace: ${ns}
subjects:
  - kind: Group
    name: ${group}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: domain-developer
  apiGroup: rbac.authorization.k8s.io
EOF
done

echo
echo "Готово. Проверки:"
echo
echo "  alice (cluster-admins):"
echo "    kubectl auth can-i '*' '*' --as=alice --as-group=cluster-admins"
echo
echo "  bob (security) — должен видеть secrets:"
echo "    kubectl auth can-i get secrets --as=bob --as-group=security -A"
echo
echo "  charlie (cluster-viewers) — НЕ должен видеть secrets:"
echo "    kubectl auth can-i get secrets --as=charlie --as-group=cluster-viewers -A"
echo "    kubectl auth can-i list pods --as=charlie --as-group=cluster-viewers -A"
echo
echo "  dave (cluster-configurators) — может настраивать ingress, но НЕ secrets:"
echo "    kubectl auth can-i create ingresses.networking.k8s.io --as=dave --as-group=cluster-configurators -A"
echo "    kubectl auth can-i get secrets --as=dave --as-group=cluster-configurators -A"
echo
echo "  eve (sales-developers) — может только в domain-sales:"
echo "    kubectl auth can-i create deployments --as=eve --as-group=sales-developers -n domain-sales"
echo "    kubectl auth can-i create deployments --as=eve --as-group=sales-developers -n domain-finance"
