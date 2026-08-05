#!/usr/bin/env bash
# Возврат к предыдущему рабочему коммиту.
#
#   ./scripts/rollback.sh              к предыдущему коммиту из .deploy-history
#   ./scripts/rollback.sh <коммит>     к указанному коммиту
#
# Откат не пересоздаёт тома: база, загрузки и `.env` остаются как есть, поэтому
# статьи и изображения, добавленные после неудачного деплоя, сохраняются.
#
# Обратной стороной этого свойства является ограничение: откат возвращает код,
# но не состояние базы. Если неудачный деплой изменил схему базы (обновление
# ядра или плагина), к прежнему поведению возвращает восстановление дампа,
# снятого деплоем перед применением — scripts/restore-db.sh.

set -euo pipefail

. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

cd "$ZT_ROOT"
zt_load_env
zt_require ZT_SITE_URL

target_ref="${1:-}"

if [ -z "$target_ref" ]; then
	[ -r "$ZT_ROOT/.deploy-history" ] ||
		zt_die "нет .deploy-history: укажите коммит явно (git log покажет историю)"
	target_ref="$(tail -1 "$ZT_ROOT/.deploy-history" | cut -f2)"
	[ -n "$target_ref" ] || zt_die "в .deploy-history нет предыдущего коммита"
	zt_log "предыдущий коммит из .deploy-history: $target_ref"
fi

dirty="$(git status --porcelain --untracked-files=normal)"
if [ -n "$dirty" ]; then
	printf '%s\n' "$dirty" | sed 's/^/    /'
	zt_die "рабочая копия расходится с репозиторием — откат не начат"
fi

git rev-parse --verify --quiet "$target_ref" >/dev/null || zt_die "не найден коммит «$target_ref»"

zt_log "откат: $(git log -1 --format='%h %s' HEAD) → $(git log -1 --format='%h %s' "$target_ref")"
git checkout --quiet "$(git rev-parse "$target_ref")" || zt_die "не удалось перейти на $target_ref"

zt_compose up -d --remove-orphans

zt_wait_healthy db 240
zt_wait_healthy wordpress 240
if zt_compose ps --status running --services 2>/dev/null | grep -qx caddy; then
	zt_wait_healthy caddy 120
fi

# Набор плагинов приводится к списку того коммита, на который откатились.
"$ZT_ROOT/scripts/plugins-sync.sh" apply || zt_log "плагины привести не удалось — проверить вручную"

zt_check_url "$ZT_SITE_URL" "публичная страница"
zt_check_url "${ZT_SITE_URL%/}/wp-login.php" "страница входа в админку"

printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "откат" "$(git rev-parse HEAD)" \
	>>"$ZT_ROOT/.deploy-history"

zt_log "откат выполнен: $(git log -1 --format='%h %s' HEAD)"
zt_log "рабочая копия в отсоединённом состоянии; вернуться к ветке: git checkout master"
