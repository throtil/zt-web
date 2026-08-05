#!/usr/bin/env bash
# Восстановление базы данных из дампа.
#
#   ./scripts/restore-db.sh --latest --yes
#   ./scripts/restore-db.sh /var/backups/zt-web/zt-web-db-20260805T030000Z.sql.gz --yes
#   ./scripts/restore-db.sh --from-b2 zt-web-db-20260805T030000Z.sql.gz --yes
#
# Ожидаемая длительность на базе первых десятков статей — до 5 минут, из них
# сам импорт секунды. Порядок и длительность описаны в docs/runbook.md;
# учебное восстановление выполняется на отдельной копии стека, а не на рабочем
# сайте — процедура там же.
#
# Без --yes скрипт ничего не делает: восстановление затирает текущую базу.

set -euo pipefail

. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

source_arg=""
mode=path
confirmed=0

while [ "$#" -gt 0 ]; do
	case "$1" in
		--latest) mode=latest ;;
		--from-b2)
			mode=b2
			shift
			source_arg="${1:-}"
			[ -n "$source_arg" ] || zt_die "--from-b2 требует имя файла"
			;;
		--yes) confirmed=1 ;;
		-*) zt_die "неизвестный аргумент «$1»" ;;
		*) source_arg="$1" ;;
	esac
	shift
done

zt_load_env
zt_require ZT_DB_NAME ZT_DB_ROOT_PASSWORD ZT_BACKUP_DIR

started_at="$(date +%s)"

# --- Выбор дампа -------------------------------------------------------------
case "$mode" in
	latest)
		# Без `| head -1`: head выходит после первой строки, sort получает
		# SIGPIPE, и pipefail превращает это в отказ — тем вероятнее, чем
		# больше накоплено копий. Первая строка берётся подстановкой.
		sorted="$(find "$ZT_BACKUP_DIR" -maxdepth 1 -name 'zt-web-db-*.sql.gz' -type f -printf '%T@ %p\n' |
			sort -rn)"
		source_arg="${sorted%%$'\n'*}"
		source_arg="${source_arg#* }"
		[ -n "$source_arg" ] || zt_die "в $ZT_BACKUP_DIR нет копий"
		;;
	b2)
		zt_require ZT_B2_BUCKET ZT_B2_KEY_ID ZT_B2_APP_KEY
		local_copy="$ZT_BACKUP_DIR/$source_arg"
		zt_log "скачиваю $source_arg из B2"
		docker run --rm \
			-e RCLONE_CONFIG_B2_TYPE=b2 \
			-e RCLONE_CONFIG_B2_ACCOUNT="$ZT_B2_KEY_ID" \
			-e RCLONE_CONFIG_B2_KEY="$ZT_B2_APP_KEY" \
			-v "$ZT_BACKUP_DIR:/data" \
			rclone/rclone:1.71.1 copyto \
			"b2:$ZT_B2_BUCKET/${ZT_B2_PREFIX:-db}/$source_arg" "/data/$source_arg" ||
			zt_die "не удалось скачать копию из B2"
		source_arg="$local_copy"
		;;
	path)
		[ -n "$source_arg" ] || zt_die "укажите путь к дампу, --latest или --from-b2 <имя>"
		;;
esac

[ -r "$source_arg" ] || zt_die "не читается файл дампа: $source_arg"

# --- Проверка дампа до того, как что-то тронуто ------------------------------
zt_log "проверяю дамп $source_arg"
gzip -t "$source_arg" 2>/dev/null || zt_die "дамп не проходит проверку целостности архива"
zt_gz_tail_has "$source_arg" 'Dump completed' ||
	zt_die "дамп обрезан: нет завершающей отметки"
zt_log "дамп пригоден"

if [ "$confirmed" -ne 1 ]; then
	cat <<EOF

Восстановление затрёт текущее содержимое базы $ZT_DB_NAME.
Дамп: $source_arg

Повторить с --yes, если это то, что нужно.
EOF
	exit 2
fi

zt_require_stack_running

# --- Восстановление ----------------------------------------------------------
# WordPress останавливается на время импорта: иначе он читает и пишет базу,
# в которую в этот момент льются таблицы.
zt_log "останавливаю WordPress"
zt_compose stop wordpress

restore_wordpress() {
	zt_log "запускаю WordPress"
	zt_compose start wordpress >/dev/null 2>&1 || true
}
trap restore_wordpress EXIT

zt_log "импортирую дамп в базу $ZT_DB_NAME"
# Дамп содержит DROP TABLE / CREATE TABLE для своих таблиц. Саму базу не
# пересоздаём: тома состояния при восстановлении не трогаются.
if ! gzip -dc "$source_arg" | zt_compose exec -T -e MYSQL_PWD="$ZT_DB_ROOT_PASSWORD" db \
	mariadb --user=root --default-character-set=utf8mb4 "$ZT_DB_NAME"; then
	zt_die "импорт не удался: база может быть в неполном состоянии, повторить восстановление"
fi

zt_log "импорт завершён"
zt_compose start wordpress >/dev/null
trap - EXIT
zt_wait_healthy wordpress 240

zt_load_env
zt_check_url "$ZT_SITE_URL" "публичная страница"
zt_check_url "${ZT_SITE_URL%/}/wp-login.php" "страница входа в админку"

elapsed=$(( $(date +%s) - started_at ))
zt_log "восстановление завершено за $((elapsed / 60)) мин $((elapsed % 60)) с"
zt_log "сверить фактическую длительность с указанной в docs/runbook.md"
