# Task 5 — Управление трафиком внутри кластера Kubernetes

## Что внутри

```
Task5/
├── 01-deploy-pods.sh              # развернуть 4 nginx-пода с метками role=
├── default-deny-ingress.yaml      # default-deny ingress в namespace
├── non-admin-api-allow.yaml       # разрешает front-end ↔ back-end-api
├── admin-api-allow.yaml           # разрешает admin-front-end ↔ admin-back-end-api
└── 02-verify.sh                   # автоматические проверки матрицы трафика
```

## Требование к CNI

NetworkPolicy в Kubernetes **тихо игнорируется**, если CNI его не поддерживает. У `minikube` по умолчанию идёт kindnet/bridge — без поддержки NetworkPolicy. Для рабочей проверки нужен CNI с поддержкой политик (например, calico):

```bash
minikube delete
minikube start --cni=calico
```

Проверить, что calico установлен:

```bash
kubectl get pods -n kube-system | grep -i calico
```

## Развёртывание и применение

```bash
cd Task5
./01-deploy-pods.sh                          # 4 пода + сервиса
kubectl apply -f default-deny-ingress.yaml   # сначала запретить всё
kubectl apply -f non-admin-api-allow.yaml    # разрешить пару front-end ↔ back-end-api
kubectl apply -f admin-api-allow.yaml        # разрешить пару admin-front-end ↔ admin-back-end-api

kubectl get networkpolicy
```

## Целевая матрица трафика

| Источник (role=) | Цель (service) | Ожидание |
|---|---|---|
| `front-end` | `back-end-api-app` | ✅ OK |
| `back-end-api` | `front-end-app` | ✅ OK |
| `admin-front-end` | `admin-back-end-api-app` | ✅ OK |
| `admin-back-end-api` | `admin-front-end-app` | ✅ OK |
| `front-end` | `admin-back-end-api-app` | ❌ DENIED |
| `admin-front-end` | `back-end-api-app` | ❌ DENIED |
| без меток | любой сервис | ❌ DENIED |

## Проверка вручную

```bash
# Тестовый под без меток — ни один сервис не должен отвечать
kubectl run test-$RANDOM --rm -i -t --image=alpine -- sh
# / # wget -qO- --timeout=2 http://back-end-api-app           → таймаут (DENIED)
# / # wget -qO- --timeout=2 http://admin-back-end-api-app     → таймаут (DENIED)

# Тестовый под с меткой role=front-end — должен достучаться до back-end-api, но не до admin-back-end-api
kubectl run test-$RANDOM --labels role=front-end --rm -i -t --image=alpine -- sh
# / # wget -qO- --timeout=2 http://back-end-api-app           → HTML nginx (OK)
# / # wget -qO- --timeout=2 http://admin-back-end-api-app     → таймаут (DENIED)
```

## Проверка автоматически

```bash
./02-verify.sh
```

Скрипт прогонит 11 кейсов из таблицы выше и напечатает OK/DENIED для каждого с пометкой ✓/✗.

