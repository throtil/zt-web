#!/usr/bin/env bash
# Первичная настройка сайта и распределение прав. Идемпотентен: повторный
# запуск после пересоздания сервера даёт то же распределение прав, ручной
# донастройки через админку не требуется.
#
#   ./scripts/wp-provision.sh
#
# Что делает:
#   - устанавливает WordPress, если он ещё не установлен (без мастера в браузере);
#   - создаёт учётную запись разработчика (роль administrator);
#   - создаёт учётную запись редактора (штатная роль editor);
#   - проверяет, что права редактора соответствуют заданным в mu-plugin;
#   - проверяет, что редактор файлов темы отключён.
#
# Пароли генерируются здесь и печатаются один раз. Передать редактору по
# отдельному каналу; сменить пароль он может сам.
#
# Роль редактору даётся штатная, а не администраторская с урезанием плагином:
# набор прав встроенной роли — часть ядра и ведёт себя предсказуемо.

set -euo pipefail

. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

zt_load_env
zt_require ZT_SITE_URL ZT_SITE_TITLE ZT_ADMIN_LOGIN ZT_ADMIN_EMAIL ZT_EDITOR_LOGIN ZT_EDITOR_EMAIL
zt_require_stack_running

# Создаёт пользователя, если его нет. Аргументы: логин, email, роль.
ensure_user() {
	local login="$1" email="$2" role="$3" password

	if zt_wp user get "$login" --field=ID >/dev/null 2>&1; then
		local current_role
		current_role="$(zt_wp user get "$login" --field=roles 2>/dev/null | tr -d '\r')"
		if [ "$current_role" != "$role" ]; then
			zt_log "у $login роль «$current_role», привожу к «$role»"
			zt_wp user set-role "$login" "$role"
		else
			zt_log "учётная запись $login уже есть, роль «$role»"
		fi
		return 0
	fi

	password="$(openssl rand -base64 24 | tr -d '\n')"
	zt_wp user create "$login" "$email" --role="$role" --user_pass="$password" --display_name="$login" >/dev/null
	zt_log "создана учётная запись $login с ролью «$role»"
	printf '\n    пароль для %s: %s\n    (показан один раз, передать по отдельному каналу)\n\n' "$login" "$password"
}

if zt_wp core is-installed >/dev/null 2>&1; then
	zt_log "WordPress уже установлен"
else
	admin_password="$(openssl rand -base64 24 | tr -d '\n')"
	zt_log "устанавливаю WordPress на $ZT_SITE_URL"
	zt_wp core install \
		--url="$ZT_SITE_URL" \
		--title="$ZT_SITE_TITLE" \
		--admin_user="$ZT_ADMIN_LOGIN" \
		--admin_email="$ZT_ADMIN_EMAIL" \
		--admin_password="$admin_password" \
		--skip-email >/dev/null
	printf '\n    пароль администратора %s: %s\n    (показан один раз)\n\n' "$ZT_ADMIN_LOGIN" "$admin_password"
fi

# Разработчик и редактор — разные люди, поэтому разные учётные записи.
# Общая не используется: иначе автором статьи значился бы не тот, кто её написал.
ensure_user "$ZT_ADMIN_LOGIN" "$ZT_ADMIN_EMAIL" administrator
ensure_user "$ZT_EDITOR_LOGIN" "$ZT_EDITOR_EMAIL" editor

# Права ролей задаёт mu-plugin (wp-content/mu-plugins/zt-guardrails.php).
# Здесь только проверка, что они применились: mu-plugin выполняет назначение
# на первом же запросе после изменения версии набора.
zt_log "проверяю права редактора"
editor_caps="$(zt_wp cap list editor 2>/dev/null | tr -d '\r')"
[ -n "$editor_caps" ] || zt_die "не удалось получить список прав роли editor"

has_cap() {
	printf '%s\n' "$editor_caps" | grep -qx "$1"
}

# Полный цикл заполнения обзора: создание и публикация статьи, загрузка
# файлов в медиабиблиотеку, категории и метки.
for cap in upload_files publish_posts manage_categories edit_others_posts edit_published_posts; do
	has_cap "$cap" || zt_die "у редактора нет права $cap — это дефект конфигурации, см. спеку role-separation"
done

# Состав кода и плагинов редактору недоступен.
for cap in install_plugins activate_plugins update_core update_plugins edit_users switch_themes edit_themes edit_theme_options manage_options; do
	! has_cap "$cap" || zt_die "у редактора есть право $cap, которого быть не должно"
done
zt_log "права редактора соответствуют спеке: нужное есть, запрещённого нет"

# Правка файлов через админку закрыта константой в config/wordpress/wp-config-zt.php.
if [ "$(zt_wp eval 'echo defined("DISALLOW_FILE_EDIT") && DISALLOW_FILE_EDIT ? "yes" : "no";' 2>/dev/null | tr -d '\r')" != "yes" ]; then
	zt_die "DISALLOW_FILE_EDIT не действует — редактор файлов темы доступен, это дефект"
fi
zt_log "редактор файлов темы и плагинов отключён, включая администратора"

if [ "${ZT_DISCOURAGE_INDEXING:-0}" = "1" ]; then
	zt_log "индексация поисковыми системами закрыта (сайт живёт на IP, статьи не публикуются)"
fi

zt_log "готово"
