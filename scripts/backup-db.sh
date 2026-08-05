#!/usr/bin/env bash
# Дамп базы данных: создание, проверка пригодности, локальная копия,
# выгрузка в Backblaze B2, удаление копий старше срока хранения.
#
#   ./scripts/backup-db.sh            обычный запуск (в том числе из cron)
#   ./scripts/backup-db.sh --local    без выгрузки в B2 (перед деплоем)
#
# Порядок шагов не произвольный:
#   1. проверка свободного места — до дампа, иначе обрыв на половине;
#   2. дамп;
#   3. проверка непустоты и целостности — до любого удаления;
#   4. выгрузка в B2 — хотя бы одна копия вне диска сервера;
#   5. удаление старых копий — только после успеха шагов 3 и 4, иначе
#      неудачный дамп вытеснил бы годные, что спека db-backup запрещает.
#
# Сайт во время дампа продолжает работать: --single-transaction снимает
# согласованный снимок InnoDB без блокировки таблиц.

set -euo pipefail

. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

UPLOAD=1
case "${1:-}" in
	--local) UPLOAD=0 ;;
	'') ;;
	*)
		zt_die "неизвестный аргумент «$1»; ожидается --local или ничего"
		;;
esac

zt_load_env
zt_require ZT_DB_NAME ZT_DB_ROOT_PASSWORD ZT_BACKUP_DIR ZT_BACKUP_RETENTION_DAYS ZT_BACKUP_MIN_FREE_MB
if [ "$UPLOAD" -eq 1 ]; then
	zt_require ZT_B2_BUCKET ZT_B2_PREFIX ZT_B2_KEY_ID ZT_B2_APP_KEY
fi

RCLONE_IMAGE=rclone/rclone:1.71.1

# Каталог дампов. Сообщение важнее обычного: скрипт запускается из cron, и его
# вывод — единственное, что увидит разработчик. Штатная ошибка `install` про
# «cannot change permissions» не подсказывает ни переменную, ни что делать.
if ! install -d -m 700 "$ZT_BACKUP_DIR" 2>/dev/null || [ ! -w "$ZT_BACKUP_DIR" ]; then
	zt_die "каталог дампов $ZT_BACKUP_DIR недоступен для записи (переменная ZT_BACKUP_DIR).
    На сервере создать его от root:  sudo ./scripts/host-prepare.sh backup-dir <логин> $ZT_BACKUP_DIR
    Локально задать другой путь:     ZT_BACKUP_DIR=/tmp/zt-backups $0 --local"
fi

# --- 1. Свободное место ------------------------------------------------------
# Диск делится с Amnezia, подкачкой и загрузками: его заполнение уронит не
# только сайт. При недостатке места ничего не удаляем — годные копии дороже
# нового дампа.
free_mb="$(df --output=avail -m "$ZT_BACKUP_DIR" | tail -1 | tr -d ' ')"
if [ "$free_mb" -lt "$ZT_BACKUP_MIN_FREE_MB" ]; then
	zt_die "свободно ${free_mb} МБ, требуется не меньше ${ZT_BACKUP_MIN_FREE_MB} МБ. Дамп не создан, имеющиеся копии сохранены"
fi

# --- 2. Дамп -----------------------------------------------------------------
stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
name="zt-web-db-${stamp}.sql.gz"
target="$ZT_BACKUP_DIR/$name"
tmp="$target.part"
dump_err="$(mktemp)"

cleanup_tmp() { rm -f "$tmp" "$dump_err"; }
trap cleanup_tmp EXIT

zt_log "снимаю дамп базы $ZT_DB_NAME"
# Пароль передаётся переменной окружения, а не аргументом: аргументы видны
# в списке процессов контейнера.
if ! zt_compose exec -T -e MYSQL_PWD="$ZT_DB_ROOT_PASSWORD" db \
	mariadb-dump \
	--user=root \
	--single-transaction \
	--quick \
	--routines \
	--events \
	--triggers \
	--default-character-set=utf8mb4 \
	"$ZT_DB_NAME" 2>"$dump_err" | gzip -6 >"$tmp"; then
	zt_log "вывод mariadb-dump:"
	sed 's/^/    /' "$dump_err" >&2 || true
	zt_die "дамп не создан. Предыдущие копии сохранены, ничего не удалено"
fi

# --- 3. Пригодность дампа ----------------------------------------------------
size_bytes="$(stat -c %s "$tmp")"
if [ "$size_bytes" -lt 10240 ]; then
	zt_die "дамп подозрительно мал (${size_bytes} байт) — не считаю его годной копией, старые копии сохранены"
fi

if ! gzip -t "$tmp" 2>/dev/null; then
	zt_die "дамп не проходит проверку целостности архива — старые копии сохранены"
fi

# mariadb-dump завершает файл строкой «Dump completed». Её отсутствие означает
# обрыв на середине: архив при этом может быть формально целым.
if ! zt_gz_tail_has "$tmp" 'Dump completed'; then
	zt_die "дамп обрезан: нет завершающей отметки. Старые копии сохранены"
fi

# Без таблиц статей дамп бесполезен, даже если он целый.
if ! zt_gz_has "$tmp" 'CREATE TABLE .*wp_posts'; then
	zt_die "в дампе нет таблицы wp_posts — база пуста или дамп неполон. Старые копии сохранены"
fi

mv "$tmp" "$target"
chmod 600 "$target"
zt_log "дамп годен: $target ($(numfmt --to=iec "$size_bytes" 2>/dev/null || echo "${size_bytes} байт"))"

# --- 4. Выгрузка вне сервера -------------------------------------------------
uploaded=0
if [ "$UPLOAD" -eq 1 ]; then
	# rclone запускается контейнером: на хосте ничего устанавливать не нужно,
	# а ключи передаются окружением и не попадают ни в образ, ни в файл настроек.
	if docker run --rm \
		-e RCLONE_CONFIG_B2_TYPE=b2 \
		-e RCLONE_CONFIG_B2_ACCOUNT="$ZT_B2_KEY_ID" \
		-e RCLONE_CONFIG_B2_KEY="$ZT_B2_APP_KEY" \
		-e RCLONE_CONFIG_B2_HARD_DELETE=true \
		-v "$ZT_BACKUP_DIR:/data:ro" \
		"$RCLONE_IMAGE" copyto --stats-one-line \
		"/data/$name" "b2:$ZT_B2_BUCKET/$ZT_B2_PREFIX/$name"; then
		zt_log "копия выгружена в b2:$ZT_B2_BUCKET/$ZT_B2_PREFIX/$name"
		uploaded=1
	else
		zt_log "выгрузка в B2 не удалась: локальная копия есть, но вне сервера её нет"
		zt_log "старые копии не удаляю — сначала разобраться с доступом к B2"
		exit 1
	fi
fi

# --- 5. Удаление старых копий ------------------------------------------------
# Только после того, как новая копия признана годной и (при обычном запуске)
# оказалась вне сервера.
zt_log "удаляю локальные копии старше $ZT_BACKUP_RETENTION_DAYS дней"
find "$ZT_BACKUP_DIR" -maxdepth 1 -name 'zt-web-db-*.sql.gz' -type f \
	-mtime +"$ZT_BACKUP_RETENTION_DAYS" -print -delete | sed 's/^/    удалена /'

if [ "$uploaded" -eq 1 ]; then
	zt_log "удаляю копии в B2 старше $ZT_BACKUP_RETENTION_DAYS дней"
	docker run --rm \
		-e RCLONE_CONFIG_B2_TYPE=b2 \
		-e RCLONE_CONFIG_B2_ACCOUNT="$ZT_B2_KEY_ID" \
		-e RCLONE_CONFIG_B2_KEY="$ZT_B2_APP_KEY" \
		-e RCLONE_CONFIG_B2_HARD_DELETE=true \
		"$RCLONE_IMAGE" delete --min-age "${ZT_BACKUP_RETENTION_DAYS}d" \
		"b2:$ZT_B2_BUCKET/$ZT_B2_PREFIX" ||
		zt_log "удаление старых копий в B2 не удалось — не критично, новая копия на месте"
fi

zt_log "бэкап завершён успешно"
