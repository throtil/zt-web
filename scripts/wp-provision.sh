#!/usr/bin/env bash
# Первичная настройка сайта и распределение прав. Идемпотентен: повторный
# запуск после пересоздания сервера даёт то же распределение прав, ручной
# донастройки через админку не требуется.
#
#   ./scripts/wp-provision.sh
#
# Что делает:
#   - устанавливает WordPress, если он ещё не установлен (без мастера в браузере);
#   - убирает примерное содержимое ядра — только на свежей установке;
#   - включает тему сайта из репозитория;
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

# Имя каталога темы в wp-content/themes. Не из окружения: тема — часть кода, а
# не настройка развёртывания, и её подмена переменной была бы способом получить
# сайт, не совпадающий с репозиторием.
ZT_THEME=zt-web

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
	ZT_JUST_INSTALLED=1
fi

# Примерное содержимое ядра: статья «Hello world!», страница «Sample Page» и
# черновик политики конфиденциальности. WordPress заводит их при установке, и
# без уборки сайт, поднятый из репозитория, встречает читателя ими: статья
# попадает в ленту на главной, страница открывается по своему адресу. Вдобавок
# «Hello world!» лежит в рубрике по умолчанию, которой нет в дереве, то есть
# нарушает правило «одна статья — одна рубрика» с первого дня.
#
# Удаляется только на свежей установке. На работающем сайте те же слоги могли
# быть заняты настоящим содержимым, и удалять по совпадению имени значило бы
# завести механизм, молча уносящий чужие страницы; там — только сообщение.
#
# Список слогов задан в самом запросе, а не аргументом: `wp eval` принимает
# только исходный текст, позиционные аргументы — это `wp eval-file`.
#
# Статусы перечислены поимённо, а не словом «any». Причина неочевидна:
# черновики — защищённый статус, и запрос со словом «any» отдаёт их только тому,
# кто вправе их читать, а под wp-cli пользователя нет вовсе. Политика
# конфиденциальности заводится ядром именно черновиком, то есть с «any» она в
# список не попадала бы — при том, что в админке она на виду.
samples="$(zt_wp eval '
	$slugs    = array( "hello-world", "sample-page", "privacy-policy" );
	$statuses = array( "publish", "future", "draft", "pending", "private" );
	$found    = array();

	foreach ( $slugs as $slug ) {
		$posts = get_posts(
			array(
				"name"             => $slug,
				"post_type"        => array( "post", "page" ),
				"post_status"      => $statuses,
				"numberposts"      => 1,
				"suppress_filters" => false,
			)
		);

		if ( $posts ) {
			$found[] = $posts[0]->ID . ":" . $slug;
		}
	}

	echo implode( " ", $found );
' | tr -d '\r')"

if [ -n "$samples" ]; then
	sample_ids="$(printf '%s\n' "$samples" | tr ' ' '\n' | cut -d: -f1 | tr '\n' ' ' | sed 's/ *$//')"
	sample_slugs="$(printf '%s\n' "$samples" | tr ' ' '\n' | cut -d: -f2 | tr '\n' ' ' | sed 's/ *$//')"

	if [ "${ZT_JUST_INSTALLED:-0}" = "1" ]; then
		# shellcheck disable=SC2086 # список идентификаторов, разделённый пробелами
		zt_wp post delete $sample_ids --force >/dev/null
		zt_log "убрано примерное содержимое ядра: $sample_slugs"
	else
		zt_log "на сайте есть примерное содержимое ядра: $sample_slugs (id: $sample_ids)"
		zt_log "оно не удаляется само на работающем сайте — убрать из админки"
	fi
fi

# Тема сайта — проверка, а не активация.
#
# Тему навязывает mu-plugin (`zt-structure.php`, фильтры на значения
# `stylesheet` и `template`), потому что активная тема живёт в базе, а деплой
# базу не трогает: на уже настроенном сервере `git pull` привёз бы шаблоны и
# сетку, а сайт остался бы стандартной темой. Активация отсюда была бы вторым
# хозяином того же значения и, хуже того, ничего бы не делала — фильтр всё равно
# сильнее.
#
# Поэтому здесь проверяется результат: если активна не наша тема, значит либо
# каталог темы не смонтирован, либо mu-plugin не загрузился. Дальше идти нельзя —
# сайт в этом состоянии выглядит не тем, что в репозитории.
active_theme="$(zt_wp theme list --status=active --field=name 2>/dev/null | tr -d '\r')"
if [ "$active_theme" = "$ZT_THEME" ]; then
	zt_log "активна тема $ZT_THEME (навязана mu-plugin, не значением в базе)"
else
	zt_die "активна тема «${active_theme:-неизвестно}», а не $ZT_THEME: проверьте, что каталог wp-content/themes/$ZT_THEME и mu-plugins смонтированы в контейнер"
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
# файлов в медиабиблиотеку, метки.
#
# `manage_post_tags` вместо прежнего `manage_categories`: метки редактор
# создаёт свободно, рубрики — нет. Рубрика попадает в меню и задана в
# репозитории, созданная из админки она исчезнет при пересоздании сервера.
#
# `edit_theme_options` — глобальные стили и меню. Тем же правом ядро открывает
# правку шаблонов; разделить их нельзя, и запрет на правку шаблонов через
# админку остаётся правилом, см. docs/theme-layers.md.
for cap in upload_files publish_posts manage_post_tags edit_theme_options \
	edit_others_posts edit_published_posts; do
	has_cap "$cap" || zt_die "у редактора нет права $cap — это дефект конфигурации, см. спеку role-separation"
done

# Состав кода и плагинов редактору недоступен. Структура сайта — тоже.
for cap in install_plugins activate_plugins update_core update_plugins edit_users \
	switch_themes edit_themes manage_categories manage_options; do
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
