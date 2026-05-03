#!/usr/bin/env bash
# 02-verify.sh — проверка матрицы трафика после применения политик.
#
# Запускает временные alpine-поды с разными метками и пытается дотянуться
# до каждого из 4 целевых сервисов. Печатает таблицу OK/DENIED.
#
# Использование:
#   ./02-verify.sh
#   NS=task5 ./02-verify.sh

set -uo pipefail

NS="${NS:-default}"

# Таблица: запускаем под с такой меткой → пробуем подключиться к этому сервису → ожидаем
declare -a CASES=(
  # source_role            target_service             expected
  "front-end              back-end-api-app           OK"
  "back-end-api           front-end-app              OK"
  "admin-front-end        admin-back-end-api-app     OK"
  "admin-back-end-api     admin-front-end-app        OK"
  "front-end              admin-back-end-api-app     DENIED"
  "front-end              admin-front-end-app        DENIED"
  "admin-front-end        back-end-api-app           DENIED"
  "admin-front-end        front-end-app              DENIED"
  "no-label               front-end-app              DENIED"
  "no-label               back-end-api-app           DENIED"
  "no-label               admin-back-end-api-app     DENIED"
)

probe() {
  local src_role="$1" target="$2"
  local pod="probe-$RANDOM"
  local labels=()
  if [[ "$src_role" != "no-label" ]]; then
    labels=(--labels="role=${src_role}")
  fi

  # wget с таймаутом 3с: 0 → достучались, иначе — нет (ждём пока сработает таймаут)
  kubectl -n "$NS" run "$pod" \
    --image=alpine \
    --restart=Never \
    --rm \
    -i \
    --quiet \
    "${labels[@]}" \
    --command -- sh -c "wget -qO- --timeout=3 --tries=1 http://${target} >/dev/null 2>&1 && echo OK || echo DENIED" \
    2>/dev/null
}

printf "%-22s %-26s %-10s %-10s %s\n" "FROM (role=)" "TO" "EXPECTED" "ACTUAL" "RESULT"
printf '%.0s-' {1..80}; echo

pass=0; fail=0
for c in "${CASES[@]}"; do
  read -r src tgt expected <<<"$c"
  actual="$(probe "$src" "$tgt" || true)"
  actual="$(echo "$actual" | tail -1 | tr -d '\r')"
  if [[ "$actual" == "$expected" ]]; then
    result="✓"
    pass=$((pass + 1))
  else
    result="✗"
    fail=$((fail + 1))
  fi
  printf "%-22s %-26s %-10s %-10s %s\n" "$src" "$tgt" "$expected" "$actual" "$result"
done
echo
echo "Прошло: $pass / $((pass + fail))"
[[ $fail -eq 0 ]] || exit 1
