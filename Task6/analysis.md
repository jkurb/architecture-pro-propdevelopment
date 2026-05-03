# Отчёт по результатам анализа Kubernetes Audit Log

> Отчёт построен по `audit-extract.json`, полученному из `audit-filter.sh`
> после прогона `simulate-incident.sh` на minikube с включённым audit-логом
> (политика — `audit-policy.yaml`).

## Подозрительные события

### 1. Доступ к секретам

- **Кто:** `kubectl-user` (текущий админ кластера) — но запрос выполнен под impersonation `--as=system:serviceaccount:secure-ops:monitoring`. В audit-логе фиксируется и реальный инициатор (`user.username`), и impersonated-пользователь (`impersonatedUser.username`).
- **Где:** `kube-system/<default-token-...>` — чтение `default-token` из системного namespace.
- **Почему подозрительно:**
  - ServiceAccount `monitoring` создан секунду назад и не имеет никаких RBAC-привязок — попытка прочитать чужой токен через impersonation прямо указывает на разведку или попытку угнать креды для дальнейшего lateral movement.
  - Запрос завершился `code=403` (запрещён RBAC), но **сам факт попытки** — индикатор компрометации работающего пользователя или скомпрометированной workstation администратора.
  - `kube-system` — namespace с критичными системными секретами (kubelet token, controller-manager и т.д.). Любое чтение оттуда — красный флаг.

### 2. Привилегированные поды

- **Кто:** `kubectl-user` (или другой пользователь с правами на pods.create в `secure-ops`).
- **Комментарий:**
  - Создан pod `privileged-pod` с `securityContext.privileged: true` и образом `alpine` — это классический паттерн container-breakout: привилегированный контейнер получает почти полный доступ к ноде, может монтировать `/`, использовать host network/PID и подняться до root на хосте.
  - Создание прошло (`code=201`), потому что в кластере не настроен **PodSecurity Admission** или **Pod Security Policy**. Это не атака сама по себе — это эксплуатация отсутствия preventive control.
  - Митигация: включить PodSecurity admission на уровне `restricted` для всех namespace, кроме явно whitelisted (kube-system).

### 3. Использование `kubectl exec` в чужом поде

- **Кто:** `kubectl-user`.
- **Что делал:** `exec` в `kube-system/coredns-...` с командой `cat /etc/resolv.conf`.
- **Почему подозрительно:**
  - Exec в системные поды `kube-system` со стороны не-платформенного пользователя — типичная разведка (DNS-конфигурация, обход правил).
  - В audit-логе появляется запись с `objectRef.subresource = exec` — это сразу триггер для SIEM-правила.
  - В реальной системе exec в чужой pod по умолчанию должен быть запрещён RBAC; здесь он прошёл (`code=101 — switching protocols → стрим установлен`).

### 4. Создание RoleBinding с правами `cluster-admin`

- **Кто:** `kubectl-user`.
- **К чему привело:**
  - Создан `RoleBinding/escalate-binding` в `secure-ops`, привязывающий ServiceAccount `monitoring` к **ClusterRole `cluster-admin`** через roleRef. *Особенность:* RoleBinding ссылается на ClusterRole — это валидный паттерн, но даёт права только в namespace RoleBinding'а, **не во всём кластере**. Тем не менее, в `secure-ops` SA `monitoring` теперь обладает полным контролем (включая создание новых RoleBinding в этом ns).
  - Если бы вместо `RoleBinding` был `ClusterRoleBinding` — это была бы полная компрометация кластера. На границе: атакующий мог пытаться, и нужно проверять оба типа.
  - Митигация: запретить создание RoleBinding/ClusterRoleBinding с `roleRef.name in {cluster-admin, admin}` через ValidatingAdmissionPolicy/Kyverno/OPA, либо требовать утверждения через GitOps.

### 5. Удаление `audit-policy.yaml`

- **Кто:** `kubectl-user`, impersonating `admin` (`--as=admin`).
- **Возможные последствия:**
  - Команда `kubectl delete -f /etc/kubernetes/audit-policy.yaml` пытается удалить из кластера ресурсы, описанные в файле — но `audit-policy.yaml` не является Kubernetes-ресурсом (он лежит на ноде и читается kube-apiserver при старте). Команда вернёт ошибку парсинга или `Unknown kind: Policy`.
  - **Однако** само событие — попытка через `--as=admin` — указывает на признак: атакующий знает про audit-policy и пытается его обезвредить. В реальной атаке tamper происходит на уровне ноды (ssh + rm файла + перезапуск apiserver), а не через kubectl. Поэтому защита аудита должна включать **immutable storage** (форвардинг лога в SIEM/S3 WORM до того, как файл может быть удалён) и алерты на любые операции с `audit-policy.yaml` на ноде.

## Какие ошибки допускает политика RBAC (наблюдения)

1. **Нет PodSecurity Admission** — позволяет создавать привилегированные поды без согласования. Критично для multi-tenant кластера.
2. **Нет ограничений на ClusterRole-биндинги** — любой пользователь с `rolebindings.create` в namespace может привязать SA к `cluster-admin`. Должна быть policy-проверка (Kyverno/OPA) или ValidatingAdmissionPolicy, отклоняющая binding'и на привилегированные роли без approve workflow.
3. **`kubectl exec` не ограничен RBAC** — права `pods/exec` обычно дают всем, кто может работать с pods. Нужно отделять: разработчики получают `pods/exec` только в своём ns; в `kube-system` exec разрешён только администраторам.
4. **ServiceAccount по умолчанию имеет токен в pod** — старый паттерн. В современном Kubernetes стоит использовать `automountServiceAccountToken: false` по умолчанию + projected tokens с коротким TTL.
5. **Impersonation (`--as=...`) не аудируется отдельно** — RBAC для verb `impersonate` обычно даётся только cluster-admin. Если impersonation используется в обход — это сильный индикатор компрометации админской учётки.

## Что считать компрометацией кластера

| Событие | Уровень |
|---|---|
| Создание `ClusterRoleBinding` на `cluster-admin` для SA или внешнего пользователя | **Критическая компрометация** — атакующий получил полные права кластера |
| Привилегированный pod создан и доступ к ноде получен | **Критическая компрометация** — атакующий имеет root на хосте |
| Удаление/изменение `audit-policy` или остановка audit-форвардера | **Компрометация наблюдаемости** — последующие действия не зафиксируются |
| Чтение токенов SA из `kube-system` | **Высокий риск компрометации** — есть креды для горизонтального движения |
| `exec` в системные поды (`kube-system/coredns`, `kube-apiserver`, `etcd`) | **Высокий риск компрометации** — разведка или подмена компонентов |

## Вывод

Симуляция показала пять последовательных шагов типичной атаки изнутри кластера: **разведка (доступ к secrets, exec в system pods) → эскалация (privileged pod, RoleBinding на cluster-admin) → попытка скрыть следы (удаление audit-policy)**. В текущей конфигурации minikube **все пять действий выполнились без preventive controls**: их остановил только RBAC на read-секретов. Для production-кластера PropDevelopment этого недостаточно.

Минимальный набор контролей, который нужно внедрить:

1. **PodSecurity Admission** на уровне `restricted` для всех product-namespace.
2. **ValidatingAdmissionPolicy / Kyverno / OPA** на запрет:
   - RoleBinding/ClusterRoleBinding на `cluster-admin` без согласования
   - `securityContext.privileged: true` без явного allow-list
   - `hostNetwork`, `hostPID`, `hostIPC` в product-namespace
3. **Immutable audit-log storage**: форвардинг audit.log в SIEM в реальном времени (Fluent Bit → ELK/Grafana Loki/Splunk). Локальный файл может быть удалён.
4. **Алерты SIEM** на:
   - любое событие с `verb = delete` для RBAC-объектов
   - создание privileged-подов
   - `exec` в `kube-system`
   - доступ к secrets из несистемных SA
   - использование impersonation (`--as=`) от не-админских пользователей
5. **RBAC-ужесточение** (см. Task 4): отдельная роль `security-auditor` с read-only на secrets и RBAC, без права на изменения; запрет `pods/exec` в `kube-system` для всех кроме `cluster-admin`.

Аудит работает — события зафиксированы. Но без preventive контролей audit-лог становится «справкой о смерти, а не диагнозом до неё».
