#!/bin/bash
# simulate-incident.sh — скрипт из задания, симулирующий пять подозрительных
# действий, которые должны быть зафиксированы в audit-логе:
#
#   1. Доступ к secrets от system:serviceaccount:secure-ops:monitoring
#   2. Создание привилегированного пода
#   3. kubectl exec в чужой под (kube-system/coredns)
#   4. Удаление audit-policy.yaml
#   5. Создание RoleBinding с привязкой к cluster-admin без согласования
#
# Запускать после 00-setup-minikube.sh, чтобы события попали в audit-лог.

set +e   # не падаем при отдельных ошибках — нам нужно зафиксировать попытки

kubectl create ns secure-ops
kubectl config set-context --current --namespace=secure-ops

kubectl create sa monitoring
kubectl run attacker-pod --image=alpine --command -- sleep 3600
kubectl auth can-i get secrets --as=system:serviceaccount:secure-ops:monitoring

kubectl get secret -n kube-system $(kubectl get secrets -n kube-system | grep default-token | head -n1 | awk '{print $1}') --as=system:serviceaccount:secure-ops:monitoring

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod
spec:
  containers:
  - name: pwn
    image: alpine
    command: ["sleep", "3600"]
    securityContext:
      privileged: true
  restartPolicy: Never
EOF

kubectl exec -n kube-system $(kubectl get pods -n kube-system | grep coredns | awk '{print $1}' | head -n1) -- cat /etc/resolv.conf

kubectl delete -f /etc/kubernetes/audit-policy.yaml --as=admin

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: escalate-binding
subjects:
- kind: ServiceAccount
  name: monitoring
  namespace: secure-ops
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF
