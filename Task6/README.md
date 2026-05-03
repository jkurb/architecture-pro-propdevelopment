# Task 6 — Аудит активности и обнаружение инцидентов

## Состав

```
Task6/
├── audit-policy.yaml       # Audit policy для kube-apiserver
├── 00-setup-minikube.sh    # пересоздать minikube с включённым audit-логом
├── simulate-incident.sh    # сценарий из задания (симулирует 5 атак)
├── audit-filter.sh         # bash + jq, фильтрация audit.log
├── audit-extract.json      # выжимка подозрительных событий (создаётся фильтром)
└── analysis.md             # отчёт по результатам
```

## Полный прогон

```bash
cd Task6

# 1. Пересоздать minikube с audit-логированием (~2-3 мин)
./00-setup-minikube.sh

# 2. Запустить симуляцию атаки
./simulate-incident.sh

# 3. Прогнать фильтр audit-лога — получится audit-extract.json + сводка в stdout
./audit-filter.sh

# 4. Открыть analysis.md и заполнить по результатам
```

## Что делает audit-policy.yaml

Две ступени уровней:

- **RequestResponse** (полный лог запроса и ответа, включая тело) — для `pods`, `secrets`, `configmaps`, `serviceaccounts`, `roles`, `rolebindings`, `clusterroles`, `clusterrolebindings`. Это даёт полную картину при работе с чувствительными ресурсами.
- **Metadata** (только метаданные — кто, когда, что) — для всего остального. Этого достаточно, чтобы видеть факт обращения, не раздувая лог.

## Что симулирует simulate-incident.sh

| № | Действие | Цель симуляции |
|---|---|---|
| 1 | `kubectl auth can-i get secrets --as=system:serviceaccount:secure-ops:monitoring` + чтение токена в `kube-system` | Попытка ServiceAccount без прав получить чувствительные секреты |
| 2 | `kubectl apply` пода с `securityContext.privileged: true` | Создание привилегированного пода (потенциальный break-out) |
| 3 | `kubectl exec` в pod `coredns` в `kube-system` | Чужой namespace, системный сервис — типичная разведка/lateral movement |
| 4 | `kubectl delete -f /etc/kubernetes/audit-policy.yaml --as=admin` | Попытка отключить аудит — классический tamper attempt |
| 5 | Создание `RoleBinding` на ClusterRole `cluster-admin` для `monitoring` SA | Privilege escalation: SA-сервис получает админские права без согласования |

## Как работает audit-filter.sh

Читает audit.log построчно (формат — JSON Lines, каждая строка — отдельное событие), прогоняет 5 jq-фильтров и собирает все совпадения в `audit-extract.json` (массив с пометкой `_category`):

| `_category` | Что ищет |
|---|---|
| `secrets-access` | `objectRef.resource = secrets` + `verb in {get, list}` |
| `privileged-pod` | `pods.create/update/patch` где у любого контейнера `securityContext.privileged = true` |
| `pod-exec` | `objectRef.subresource = exec` |
| `cluster-admin-binding` | `rolebindings/clusterrolebindings.create` где `roleRef.name = cluster-admin` |
| `audit-policy-tamper` | `verb = delete` + `requestURI` содержит `audit-policy` |

В stdout печатается человеко-читаемая сводка по каждой категории с временем, пользователем, namespace, именем ресурса и кодом ответа.

## Чтение лога без установленной симуляции

Если вы хотите анализировать чужой `audit.log` (не из minikube), передайте путь:

```bash
./audit-filter.sh /path/to/audit.log
```

## Уборка

```bash
kubectl delete ns secure-ops
kubectl delete pod privileged-pod -n secure-ops 2>/dev/null || true
# Если хочется отключить аудит и вернуть minikube «как было»:
minikube delete
minikube start
```
