#!/usr/bin/env bash
# Деплой: приведение рабочей копии на сервере к состоянию выбранного коммита
# и применение этого состояния к запущенным сервисам.
#
#   ./scripts/deploy.sh                    до origin/<текущая ветка>
#   ./scripts/deploy.sh v1.2               до тега или коммита
#   ./scripts/deploy.sh --skip-backup      без предварительного дампа
#
# Порядок шагов:
#   1. проверка чистоты рабочей копии — ручная правка на сервере обнаруживается
#      и не затирается молча;
#   2. свежий дамп базы — деплой не начинается, если дамп не удался;
#   3. переход на целевой коммит;
#   4. применение к сервисам;
#   5. ожидание готовности;
#   6. приведение набора плагинов к plugins.txt;
#   7. проверка, что сайт и админка отвечают. Без неё «команды выполнились
#      без ошибок» — не признак успешного деплоя.
#
# Тома состояния не пересоздаются ни на одном шаге: база, загрузки и `.env`
# деплой не трогает.

set -euo pipefail

. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

target_ref=""
skip_backup=0

while [ "$#" -gt 0 ]; do
	case "$1" in
		--skip-backup) skip_backup=1 ;;
		-h | --help)
			sed -n '2,25p' "$0"
			exit 0
			;;
		-*) zt_die "неизвестный аргумент «$1»" ;;
		*) target_ref="$1" ;;
	esac
	shift
done

cd "$ZT_ROOT"
zt_load_env
zt_require ZT_SITE_URL

command -v git >/dev/null || zt_die "нужен git"
git rev-parse --git-dir >/dev/null 2>&1 || zt_die "$ZT_ROOT не рабочая копия git"

# --- 1. Чистота рабочей копии ------------------------------------------------
dirty="$(git status --porcelain --untracked-files=normal)"
if [ -n "$dirty" ]; then
	zt_log "рабочая копия на сервере расходится с репозиторием:"
	printf '%s\n' "$dirty" | sed 's/^/    /'
	zt_die "деплой не начат. Изменения, которых нет в репозитории, в деплое не участвуют: перенести их в репозиторий или отменить (git restore / git clean)"
fi

previous_commit="$(git rev-parse HEAD)"
zt_log "текущий коммит: $(git log -1 --format='%h %s' HEAD)"

zt_log "получаю изменения из репозитория"
git fetch --prune --quiet

if [ -z "$target_ref" ]; then
	current_branch="$(git symbolic-ref --short -q HEAD || true)"
	[ -n "$current_branch" ] ||
		zt_die "рабочая копия не на ветке (отсоединённый HEAD): укажите коммит или тег явно"
	target_ref="origin/$current_branch"
fi

git rev-parse --verify --quiet "$target_ref" >/dev/null ||
	zt_die "не найден коммит, тег или ветка «$target_ref»"

target_commit="$(git rev-parse "$target_ref")"

if [ "$target_commit" = "$previous_commit" ]; then
	zt_log "рабочая копия уже на $target_ref — код менять не нужно, применяю состояние к сервисам"
else
	zt_log "изменения, которые будут применены:"
	git log --oneline "$previous_commit..$target_commit" 2>/dev/null | sed 's/^/    /' ||
		zt_log "    (история разошлась — переход на $target_ref)"
fi

# --- 2. Свежий дамп до применения --------------------------------------------
# Обновление ядра или плагинов способно изменить схему базы, поэтому дамп
# делается по умолчанию, а не только по флагу.
if [ "$skip_backup" -eq 1 ]; then
	zt_log "дамп пропущен по --skip-backup: применимо только к деплою, не затрагивающему базу"
else
	if zt_service_running db; then
		zt_log "создаю свежий дамп базы перед деплоем"
		"$ZT_ROOT/scripts/backup-db.sh" --local ||
			zt_die "дамп не создан — деплой не начат. Спека deploy запрещает начинать без годной свежей копии"
	else
		zt_log "база не запущена (первый деплой?) — дамп пропущен"
	fi
fi

# --- 3. Переход на целевой коммит --------------------------------------------
if [ "$target_commit" != "$previous_commit" ]; then
	if git symbolic-ref --short -q HEAD >/dev/null && [ "$target_ref" = "origin/$(git symbolic-ref --short HEAD)" ]; then
		git merge --ff-only --quiet "$target_ref" ||
			zt_die "не удалось перейти на $target_ref без слияния: история сервера разошлась с репозиторием"
	else
		git checkout --quiet "$target_commit" ||
			zt_die "не удалось перейти на $target_ref"
	fi
	zt_log "рабочая копия на коммите $(git log -1 --format='%h %s' HEAD)"
fi

# Для откката: предыдущий коммит запоминается, чтобы к нему можно было
# вернуться, не восстанавливая его по памяти.
printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$previous_commit" "$(git rev-parse HEAD)" \
	>>"$ZT_ROOT/.deploy-history"

# --- 4. Применение к сервисам ------------------------------------------------
zt_log "применяю состояние к сервисам"
zt_compose up -d --remove-orphans

# --- 5. Готовность -----------------------------------------------------------
zt_wait_healthy db 240
zt_wait_healthy wordpress 240
if zt_service_running caddy; then
	zt_wait_healthy caddy 120
fi

# --- 6. Плагины --------------------------------------------------------------
if "$ZT_ROOT/scripts/plugins-sync.sh" apply; then
	zt_log "набор плагинов соответствует plugins.txt"
else
	zt_die "не удалось привести набор плагинов к plugins.txt"
fi

# --- 7. Проверка результата --------------------------------------------------
zt_check_url "$ZT_SITE_URL" "публичная страница"
zt_check_url "${ZT_SITE_URL%/}/wp-login.php" "страница входа в админку"

zt_log "деплой успешен: $(git log -1 --format='%h %s' HEAD)"
zt_log "откат при необходимости: ./scripts/rollback.sh ${previous_commit:0:12}"
