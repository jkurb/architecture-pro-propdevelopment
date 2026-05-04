# Отчёт по результатам анализа Kubernetes Audit Log

> **Сводка:** в логе **1398 событий**, фильтр выделил **18 подозрительных** событий
> в 4 из 5 ожидаемых категорий. Категория «удаление audit-policy» пуста —
> объяснение в п. 5.

## Подозрительные события

### 1. Доступ к секретам

- **Кто:** `minikube-user` (текущий админ-пользователь kubectl), при этом одна попытка с impersonation (выполнить запрос от имени другого пользователя) → `system:serviceaccount:secure-ops:monitoring`.
- **Где:** `secrets` в namespace `kube-system` (системные токены).
- **Почему подозрительно:**
  - SA `monitoring` создан только что и не имеет ни одной RBAC-привязки. Попытка чтения системных секретов через `--as=system:serviceaccount:...` — классическая разведка/попытка угона креденшелов для дальнейшего   

### 2. Привилегированные поды

- **Кто:** `minikube-user`.
- **Что:** создан pod `privileged-pod` в namespace `secure-ops`, образ `alpine`, **`securityContext.privileged: true`**, запрос завершился с **code=201** (создан).
- **Комментарий:**
  - Создание прошло без admission-controller, т.к. в minikube не настроен **PodSecurity Admission**. Это не атака сама по себе — это использование отсутствия preventive control.
  - Привилегированный контейнер позволяет: монтировать `/`, использовать host network/PID, подняться до root на хосте — фактически container breakout без эксплойтов.
  

### 3. Использование `kubectl exec` в чужом поде

- **Кто:** `minikube-user`.
- **Что делал:** попытка `exec` в `kube-system/coredns-6f6b679f8f-r8dpb` с командой `cat /etc/resolv.conf`. Шесть записей в логе — kubectl делает 3 запроса (GET для проверки + CREATE для самой stream-сессии), и каждый из них фиксируется на двух стадиях (`ResponseStarted` и `ResponseComplete`).
- **Почему подозрительно:**
  - Exec в системные поды `kube-system` — типичная разведка (изучение DNS-конфигурации, подмена `/etc/resolv.conf` для DNS-spoofing внутри кластера).


### 4. Создание RoleBinding с правами `cluster-admin`

- **Кто:** `minikube-user`.
- **Что:** создан `RoleBinding/escalate-binding` в `secure-ops`, subject — ServiceAccount `monitoring` (тот самый, что пытался читать секреты), `roleRef.name = cluster-admin`. Запрос **code=201** — УСПЕХ.
- **К чему привело:**
  - SA `monitoring` теперь имеет ВСЕ права `cluster-admin` **в namespace `secure-ops`** (важно: RoleBinding ограничен своим namespace, даже если ссылается на ClusterRole). Этого достаточно, чтобы из `secure-ops` создать новый pod, смонтировать host-fs и выйти на ноду.
  - Если бы в скрипте был **`ClusterRoleBinding`** вместо `RoleBinding` — это была бы полная компрометация кластера. 

### 5. Удаление `audit-policy.yaml`

- **Кто:** `minikube-user`, попытка с impersonation `--as=admin`.
- **Что произошло:** `kubectl delete -f /etc/kubernetes/audit-policy.yaml` — kubectl попытался прочитать YAML с локального диска, но файл не существует на хосте (он внутри ноды minikube). Команда упала с `error: the path "/etc/kubernetes/audit-policy.yaml" does not exist` ещё **до отправки запроса в API**. Поэтому в audit-логе **0 событий** в этой категории.


# Выводы

| Событие | Уровень |
|---|---|
| RoleBinding/ClusterRoleBinding на `cluster-admin` для произвольного SA | **Критическая компрометация** — privilege escalation, все последующие действия от привязанного SA выглядят легитимно |
| Привилегированный pod создан | **Критическая компрометация** — атакующий может выйти на ноду |
| Удаление/изменение audit-policy на ноде | **Компрометация наблюдаемости** — последующие действия не зафиксируются в локальном файле |
| Доступ к secrets из `kube-system` от не-системного субъекта | **Высокий риск** — есть креденшелы для горизонтального движения |
| `exec` в системные поды (`kube-apiserver`, `coredns`, `etcd`) | **Высокий риск** — разведка / подмена компонентов |
