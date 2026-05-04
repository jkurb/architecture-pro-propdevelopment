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


