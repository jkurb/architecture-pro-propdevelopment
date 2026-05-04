# Task 7 — Аудит безопасности контейнеров (PodSecurity Admission + OPA Gatekeeper)

## Структура

```
Task7/
├── 01-create-namespace.yaml        — namespace audit-zone с PSA enforce=restricted
├── insecure-manifests/             — 3 пода с нарушениями (должны быть отклонены)
│   ├── 01-privileged-pod.yaml      — privileged: true
│   ├── 02-hostpath-pod.yaml        — монтирует hostPath /
│   └── 03-root-user-pod.yaml       — runAsUser: 0
├── secure-manifests/               — те же поды, но соответствующие политике
│   ├── 01-secure.yaml
│   ├── 02-secure.yaml
│   └── 03-secure.yaml
├── gatekeeper/
│   ├── constraint-templates/       — Rego-шаблоны (создают CRD)
│   │   ├── privileged.yaml         — K8sPSPrivileged
│   │   ├── hostpath.yaml           — K8sPSHostPath
│   │   └── runasnonroot.yaml       — K8sPSRunAsNonRoot (runAsNonRoot + readOnlyRootFilesystem)
│   └── constraints/                — применяют шаблоны к namespace audit-zone
│       ├── privileged.yaml
│       ├── hostpath.yaml
│       └── runasnonroot.yaml
├── verify/
│   ├── verify-admission.sh         — проверка только PSA (без Gatekeeper)
│   └── validate-security.sh        — установка Gatekeeper + полная проверка
├── audit-policy.yaml               — Kubernetes audit policy для трекинга нарушений
└── README_FOR_REVIEWER.md          — этот файл
```

## Как воспроизвести

### Подготовка

Нужен minikube с включённым audit-логом (см. `Task6/00-setup-minikube.sh`). Если его нет — Task7 всё равно отработает, просто события не попадут в audit.log.

```bash
cd Task7
```

### Шаг 1. PSA: namespace + проверка

```bash
kubectl apply -f 01-create-namespace.yaml
./verify/verify-admission.sh
```

Ожидаемый вывод: 3 INSECURE → DENIED, 3 SECURE → ALLOWED.

### Шаг 2. Gatekeeper

```bash
./verify/validate-security.sh
```

Скрипт:
1. Устанавливает Gatekeeper (`release-3.16`) если его ещё нет
2. Применяет ConstraintTemplate'ы (3 CRD)
3. Применяет Constraint'ы (3 объекта в namespace audit-zone)
4. Прогоняет ту же матрицу insecure/secure

Ожидаемый вывод тот же: insecure → DENIED, secure → ALLOWED. Разница в том, что теперь поды отклоняются на уровне Gatekeeper-вебхука (отдельный admission controller), даже если PSA по какой-то причине пропустил бы их.


## Самостоятельная проверка

### Что PSA включён

```bash
kubectl get ns audit-zone -o yaml | grep pod-security.kubernetes.io
```

Ожидаемо: 6 labels (enforce/audit/warn × policy/version).

### Что Gatekeeper активен

```bash
kubectl get pods -n gatekeeper-system
# 3 pod'а должны быть Running:
#   gatekeeper-audit-*
#   gatekeeper-controller-manager-* (3 replicas)
#   gatekeeper-controller-manager-*

kubectl get k8spsprivileged.constraints.gatekeeper.sh
kubectl get k8spshostpath.constraints.gatekeeper.sh
kubectl get k8spsrunasnonroot.constraints.gatekeeper.sh
# Должны существовать по одному объекту в каждом
```

### Ручная проверка отклонения

```bash
kubectl apply -f insecure-manifests/01-privileged-pod.yaml
# Error from server: admission webhook denied the request:
#   Privileged container is not allowed: nginx
#   ИЛИ
#   forbidden: violates PodSecurity "restricted:latest"
```
