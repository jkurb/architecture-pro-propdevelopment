#!/usr/bin/env bash
# audit-filter.sh — фильтрация Kubernetes audit-лога, выделение подозрительных
# событий и формирование audit-extract.json.
#
# Использование:
#   ./audit-filter.sh                        # тянет лог из minikube ноды
#   ./audit-filter.sh ./local-audit.log      # читает уже скачанный лог
#
# Результаты:
#   - audit-extract.json — все подозрительные события (массив JSON)
#   - stdout — человекочитаемая сводка по 5 категориям инцидентов

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_JSON="${SCRIPT_DIR}/audit-extract.json"

# === Получение лога ===
LOG_SRC="${1:-}"
TMP_LOG="$(mktemp)"
trap 'rm -f "$TMP_LOG"' EXIT

if [[ -z "$LOG_SRC" ]]; then
  echo "==> Тянем audit-лог из minikube"
  minikube ssh -- "sudo cat /var/log/audit.log" > "$TMP_LOG"
  LOG="$TMP_LOG"
else
  if [[ ! -f "$LOG_SRC" ]]; then
    echo "ERROR: файл не найден: $LOG_SRC" >&2
    exit 1
  fi
  LOG="$LOG_SRC"
fi

TOTAL=$(wc -l < "$LOG" | tr -d ' ')
echo "==> Всего событий в логе: $TOTAL"
echo

# === Фильтры ===

# Каждый фильтр — это jq-выражение, выбирающее подозрительные события.
# Использует select(...). Для каждой категории добавляем поле _category,
# чтобы потом можно было группировать в analysis.md.

FILTER_SECRETS='select(.objectRef.resource == "secrets" and (.verb == "get" or .verb == "list")) | . + {_category: "secrets-access"}'

FILTER_PRIV_POD='select(
  .objectRef.resource == "pods"
  and (.verb == "create" or .verb == "update" or .verb == "patch")
  and (.requestObject.spec.containers // []) as $c
  | $c | any(.securityContext.privileged == true)
) | . + {_category: "privileged-pod"}'

FILTER_EXEC='select(.objectRef.subresource == "exec") | . + {_category: "pod-exec"}'

FILTER_CLUSTER_ADMIN_BINDING='select(
  (.objectRef.resource == "rolebindings" or .objectRef.resource == "clusterrolebindings")
  and .verb == "create"
  and ((.requestObject.roleRef.name // "") == "cluster-admin")
) | . + {_category: "cluster-admin-binding"}'

# Удаление audit-policy: смотрим попытки удаления + любые упоминания audit-policy в URL
FILTER_AUDIT_POLICY='select(
  .verb == "delete"
  and ((.requestURI // "") | test("audit-policy"; "i"))
) | . + {_category: "audit-policy-tamper"}'

# === Извлечение и сохранение ===

# Каждый event в audit-логе — отдельная JSON-строка (jsonl).
# Читаем построчно, применяем все фильтры, объединяем в один массив.
{
  echo "["
  first=true
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    for filter in "$FILTER_SECRETS" "$FILTER_PRIV_POD" "$FILTER_EXEC" "$FILTER_CLUSTER_ADMIN_BINDING" "$FILTER_AUDIT_POLICY"; do
      result=$(echo "$line" | jq -c "$filter" 2>/dev/null || true)
      if [[ -n "$result" && "$result" != "null" ]]; then
        if [[ "$first" == true ]]; then
          first=false
        else
          echo ","
        fi
        echo "$result"
      fi
    done
  done < "$LOG"
  echo "]"
} > "$OUT_JSON"

EXTRACTED=$(jq 'length' "$OUT_JSON")
echo "==> Подозрительных событий найдено: $EXTRACTED"
echo "==> Записано в: $OUT_JSON"
echo

# === Человеко-читаемая сводка ===

print_category() {
  local cat="$1" title="$2"
  local count
  count=$(jq "[.[] | select(._category == \"$cat\")] | length" "$OUT_JSON")
  echo "── ${title} (${count})"
  jq -r --arg cat "$cat" '
    .[]
    | select(._category == $cat)
    | "  [\(.requestReceivedTimestamp[0:19])] user=\(.user.username // "?") verb=\(.verb) ns=\(.objectRef.namespace // "-") name=\(.objectRef.name // "-") resource=\(.objectRef.resource // "-")\(if .objectRef.subresource then "/" + .objectRef.subresource else "" end) → code=\(.responseStatus.code // "?")"
  ' "$OUT_JSON"
  echo
}

print_category "secrets-access"          "1. Доступ к secrets"
print_category "privileged-pod"          "2. Создание privileged pod"
print_category "pod-exec"                "3. kubectl exec в pod"
print_category "cluster-admin-binding"   "4. RoleBinding на cluster-admin"
print_category "audit-policy-tamper"     "5. Попытка удаления audit-policy"
