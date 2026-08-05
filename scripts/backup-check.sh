#!/usr/bin/env bash
# Проверка свежести последней годной копии базы.
#
#   ./scripts/backup-check.sh
#
# Даёт явный отрицательный результат (код возврата 1 и сообщение), если
# последняя годная копия старше ZT_BACKUP_MAX_AGE_HOURS. Без такой проверки
# прекращение бэкапов обнаруживается только в аварии.
#
# Мониторинга как системы в этой итерации нет сознательно: скрипт ставится в
# cron рядом с бэкапом, и хостовый cron сам сообщает о неуспешном запуске.

set -euo pipefail

. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

zt_load_env
zt_require ZT_BACKUP_DIR ZT_BACKUP_MAX_AGE_HOURS

problems=0

# --- Локальная копия ---------------------------------------------------------
if [ ! -d "$ZT_BACKUP_DIR" ]; then
	zt_log "каталог копий $ZT_BACKUP_DIR не существует — бэкап ни разу не выполнялся"
	exit 1
fi

# Без `| head -1`: head выходит после первой строки и оставляет sort с SIGPIPE,
# что при pipefail читается как «копий нет». Проверка свежести обязана давать
# отрицательный результат только по существу, а не по случайности конвейера.
latest_sorted="$(find "$ZT_BACKUP_DIR" -maxdepth 1 -name 'zt-web-db-*.sql.gz' -type f -printf '%T@ %p\n' 2>/dev/null |
	sort -rn)"
latest="${latest_sorted%%$'\n'*}"
latest="${latest#* }"

if [ -z "$latest" ]; then
	zt_log "в $ZT_BACKUP_DIR нет ни одной копии"
	exit 1
fi

age_seconds=$(($(date +%s) - $(stat -c %Y "$latest")))
age_hours=$((age_seconds / 3600))
max_seconds=$((ZT_BACKUP_MAX_AGE_HOURS * 3600))

if ! gzip -t "$latest" 2>/dev/null; then
	zt_log "последняя копия $latest не проходит проверку целостности"
	problems=1
elif [ "$age_seconds" -gt "$max_seconds" ]; then
	zt_log "последняя копия создана ${age_hours} ч назад, ожидалось не старше ${ZT_BACKUP_MAX_AGE_HOURS} ч: $latest"
	problems=1
else
	zt_log "локальная копия свежая: ${age_hours} ч, $(basename "$latest")"
fi

# --- Копия вне сервера -------------------------------------------------------
# Потеря сервера не должна означать потерю всех копий, поэтому наличие копии
# в B2 проверяется отдельно от локальной.
if [ -n "${ZT_B2_BUCKET:-}" ] && [ -n "${ZT_B2_KEY_ID:-}" ] && [ -n "${ZT_B2_APP_KEY:-}" ]; then
	remote_newest="$(docker run --rm \
		-e RCLONE_CONFIG_B2_TYPE=b2 \
		-e RCLONE_CONFIG_B2_ACCOUNT="$ZT_B2_KEY_ID" \
		-e RCLONE_CONFIG_B2_KEY="$ZT_B2_APP_KEY" \
		rclone/rclone:1.71.1 lsf --files-only --format tp \
		"b2:$ZT_B2_BUCKET/${ZT_B2_PREFIX:-db}" 2>/dev/null | sort -r || true)"
	remote_newest="${remote_newest%%$'\n'*}"

	if [ -z "$remote_newest" ]; then
		zt_log "в B2 копий нет или бакет недоступен — единственная копия на диске сервера"
		problems=1
	else
		remote_time="${remote_newest%%;*}"
		remote_name="${remote_newest#*;}"
		remote_age=$(($(date +%s) - $(date -d "$remote_time" +%s 2>/dev/null || echo 0)))
		if [ "$remote_age" -gt "$max_seconds" ]; then
			zt_log "последняя копия в B2 создана $((remote_age / 3600)) ч назад: $remote_name"
			problems=1
		else
			zt_log "копия в B2 свежая: $((remote_age / 3600)) ч, $remote_name"
		fi
	fi
else
	zt_log "переменные B2 не заданы — проверяю только локальную копию"
	problems=1
fi

if [ "$problems" -ne 0 ]; then
	zt_log "проверка свежести бэкапа НЕ пройдена"
	exit 1
fi

zt_log "проверка свежести бэкапа пройдена"
