#!/usr/bin/env bash
# 00-setup-minikube.sh — настройка audit-логирования kube-apiserver через
# прямое редактирование static-pod манифеста.
#
# Подход:
#   1. Запустить minikube без аудита (control-plane гарантированно поднимется)
#   2. Скопировать audit-policy.yaml в /etc/kubernetes/ внутри ноды
#   3. Скачать /etc/kubernetes/manifests/kube-apiserver.yaml на хост
#   4. Пропатчить локально через Python (видно diff)
#   5. Загрузить обратно — kubelet сам перезапустит kube-apiserver
#
# ВНИМАНИЕ: пересоздание minikube удалит всё из предыдущих заданий (Task 4, Task 5).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_FILE="${SCRIPT_DIR}/audit-policy.yaml"

if [[ ! -f "$POLICY_FILE" ]]; then
  echo "ERROR: Не найден ${POLICY_FILE}" >&2
  exit 1
fi

echo "==> 1/7 Удаляем текущий minikube"
minikube delete || true

echo "==> 2/7 Стартуем minikube БЕЗ audit"
minikube start --cni=calico

echo "==> 3/7 Копируем audit-policy.yaml в ноду"
minikube cp "$POLICY_FILE" /etc/kubernetes/audit-policy.yaml
minikube ssh -- "sudo chmod 0644 /etc/kubernetes/audit-policy.yaml && sudo ls -la /etc/kubernetes/audit-policy.yaml"

echo "==> 4/7 Создаём пустой /var/log/audit.log"
minikube ssh -- "sudo touch /var/log/audit.log && sudo chmod 0644 /var/log/audit.log"

echo "==> 5/7 Скачиваем kube-apiserver.yaml на хост и патчим локально"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ORIG_MANIFEST="$TMP_DIR/kube-apiserver-orig.yaml"
PATCHED_MANIFEST="$TMP_DIR/kube-apiserver-patched.yaml"

# minikube cp в направлении node→host имеет известный баг (пишет 0 байт),
# поэтому скачиваем через ssh + sudo cat
minikube ssh -- "sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml" > "$ORIG_MANIFEST"
if [[ ! -s "$ORIG_MANIFEST" ]]; then
  echo "ERROR: не удалось скачать kube-apiserver.yaml (пустой файл)" >&2
  exit 1
fi
echo "    скачано: $(wc -l < "$ORIG_MANIFEST") строк"
cp "$ORIG_MANIFEST" "$PATCHED_MANIFEST"

python3 - "$PATCHED_MANIFEST" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

# 1. Флаги CLI после --advertise-address
flags_block = (
    "    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml\n"
    "    - --audit-log-path=/var/log/audit.log\n"
    "    - --audit-log-maxage=30\n"
    "    - --audit-log-maxsize=100\n"
    "    - --audit-log-maxbackup=5\n"
)
if "--audit-policy-file" not in content:
    content, n = re.subn(
        r"(    - --advertise-address=[^\n]+\n)",
        r"\1" + flags_block,
        content,
        count=1,
    )
    if n != 1:
        sys.exit("FAIL: не найдена строка --advertise-address для вставки флагов")

# 2. volumeMounts внутри контейнера kube-apiserver
mounts_block = (
    "    - mountPath: /etc/kubernetes/audit-policy.yaml\n"
    "      name: audit-policy\n"
    "      readOnly: true\n"
    "    - mountPath: /var/log/audit.log\n"
    "      name: audit-log\n"
    "      readOnly: false\n"
)
if "name: audit-policy" not in content:
    content, n = re.subn(
        r"(    volumeMounts:\n)",
        r"\1" + mounts_block,
        content,
        count=1,
    )
    if n != 1:
        sys.exit("FAIL: не найден volumeMounts:")

# 3. volumes на уровне pod.spec
volumes_block = (
    "  - hostPath:\n"
    "      path: /etc/kubernetes/audit-policy.yaml\n"
    "      type: File\n"
    "    name: audit-policy\n"
    "  - hostPath:\n"
    "      path: /var/log/audit.log\n"
    "      type: FileOrCreate\n"
    "    name: audit-log\n"
)
if "path: /etc/kubernetes/audit-policy.yaml\n      type: File\n" not in content:
    content, n = re.subn(
        r"(^  volumes:\n)",
        r"\1" + volumes_block,
        content,
        count=1,
        flags=re.MULTILINE,
    )
    if n != 1:
        sys.exit("FAIL: не найден volumes: на уровне pod.spec")

with open(path, "w") as f:
    f.write(content)
print("OK: манифест пропатчен")
PYEOF

echo "    --- diff ---"
diff -u "$ORIG_MANIFEST" "$PATCHED_MANIFEST" | head -60 || true
echo "    -----------"

echo "==> 6/7 Загружаем пропатченный манифест обратно"
minikube cp "$PATCHED_MANIFEST" /etc/kubernetes/manifests/kube-apiserver.yaml
minikube ssh -- "sudo ls -la /etc/kubernetes/manifests/kube-apiserver.yaml"

echo "==> 7/7 Ждём перезапуск kube-apiserver"
# Kubelet увидит mtime изменение и перезапустит static pod.
# kubectl временно недоступен (10-30 сек) — ждём готовности /healthz
sleep 10
for i in $(seq 1 30); do
  if kubectl --request-timeout=5s get --raw /healthz >/dev/null 2>&1; then
    echo "    kube-apiserver готов (после $((i * 5)) сек)"
    break
  fi
  echo "    ожидание ($i/30)..."
  sleep 5
done

echo
echo "==> Проверка audit-лога"
sleep 3
minikube ssh -- "sudo ls -la /var/log/audit.log"
echo "    --- последние 3 события ---"
minikube ssh -- "sudo tail -3 /var/log/audit.log" || true

echo
echo "Готово. Audit-лог пишется в /var/log/audit.log внутри ноды minikube."
echo "Скопировать на хост:  minikube cp minikube:/var/log/audit.log ./audit.log"
echo "Запустить симуляцию:  ./simulate-incident.sh"
echo "Прогнать фильтр:       ./audit-filter.sh"
