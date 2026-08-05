#!/usr/bin/env bash
# Проверка разделения прав редактора и разработчика — поведением, а не списком
# прав. Список прав уже сверяет scripts/wp-provision.sh; здесь проверяется то,
# что увидит человек в браузере: редактору доступен полный цикл заполнения
# обзора и недоступно всё остальное.
#
#   ./scripts/check-roles.sh            проверить
#   ./scripts/check-roles.sh --keep     не удалять временную учётную запись
#                                       (для разбора неудачной проверки)
#
# Проверка не требует ничьих паролей: заводится временная учётная запись с
# ролью editor и случайным паролем, и она же удаляется в конце вместе со всем,
# что в ходе проверки создала. Пароли настоящих редактора и разработчика
# скрипту не нужны и им не запрашиваются.
#
# Сторона разработчика проверяется через wp-cli с подстановкой пользователя:
# временная административная учётная запись не создаётся сознательно — даже
# короткоживущая, она была бы худшим следствием проверки, чем её отсутствие.

set -uo pipefail

. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

KEEP=0
case "${1:-}" in
	--keep) KEEP=1 ;;
	'') ;;
	*) zt_die "неизвестный аргумент «$1»; ожидается --keep или ничего" ;;
esac

zt_load_env
zt_require ZT_SITE_URL ZT_ADMIN_LOGIN
zt_require_stack_running

SITE="${ZT_SITE_URL%/}"
PROBE_LOGIN=zt-rolecheck
JAR="$(mktemp)"
PHOTO="$(mktemp --suffix=.jpg)"
fail=0
cat_id=""
tag_id=""

# Пробное изображение — настоящий JPEG 8×8, вшитый в скрипт: проверяется право
# загружать файлы, а не обработка больших изображений (это задачи группы 4).
# WordPress проверяет содержимое загружаемого файла, поэтому заглушка из
# случайных байт не подошла бы.
PHOTO_B64='/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8l
JCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/wAALCAAIAAgBAREA/8QAFAAB
AAAAAAAAAAAAAAAAAAAAAv/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AL//Z'

cleanup() {
	rm -f "$JAR" "$PHOTO"
	if [ "$KEEP" -eq 1 ]; then
		zt_log "временная учётная запись $PROBE_LOGIN оставлена по --keep: удалить вручную"
		return
	fi
	# Удаление пользователя вместе с его записями и вложениями: иначе на сайте
	# останутся черновики и файлы проверки. Категория и метка пользователю не
	# принадлежат, поэтому убираются отдельно.
	if zt_wp user get "$PROBE_LOGIN" --field=ID >/dev/null 2>&1; then
		if zt_wp user delete "$PROBE_LOGIN" --yes >/dev/null 2>&1; then
			zt_log "временная учётная запись $PROBE_LOGIN и созданное ею удалены"
		else
			zt_log "ВНИМАНИЕ: не удалось удалить учётную запись $PROBE_LOGIN — удалить вручную"
		fi
	fi
	[ -n "$cat_id" ] && zt_wp term delete category "$cat_id" >/dev/null 2>&1
	[ -n "$tag_id" ] && zt_wp term delete post_tag "$tag_id" >/dev/null 2>&1
	return 0
}
trap cleanup EXIT

ok() { printf '    ✓ %s\n' "$*"; }
bad() {
	printf '    ✗ %s\n' "$*"
	fail=1
}

curl_probe() { curl -sS -k -b "$JAR" "$@"; }
admin_code() { curl_probe -o /dev/null -w '%{http_code}' "$SITE/wp-admin/$1"; }
rest() {
	local method="$1" path="$2"
	shift 2
	# Обращение через ?rest_route=, а не /wp-json/: человекопонятные ссылки
	# могут быть не включены, и тогда /wp-json/ до приложения не доходит.
	curl_probe -H "X-WP-Nonce: $NONCE" -X "$method" "$SITE/?rest_route=/wp/v2/$path" "$@"
}
# Ответы REST здесь короткие и предсказуемые, поэтому обходимся grep вместо
# разбора JSON: лишняя зависимость на сервере — лишняя причина не запуститься.
json_number() { grep -o "\"$1\":[0-9]\{1,\}" | head -1 | cut -d: -f2; }
json_string() { grep -o "\"$1\":\"[^\"]*\"" | head -1 | cut -d'"' -f4; }

# --- Временная учётная запись с ролью editor ---------------------------------
zt_wp user get "$PROBE_LOGIN" --field=ID >/dev/null 2>&1 &&
	zt_wp user delete "$PROBE_LOGIN" --yes >/dev/null 2>&1

probe_pw="$(openssl rand -base64 24 | tr -d '\n')"
zt_wp user create "$PROBE_LOGIN" "$PROBE_LOGIN@example.invalid" \
	--role=editor --user_pass="$probe_pw" >/dev/null 2>&1 ||
	zt_die "не удалось создать временную учётную запись $PROBE_LOGIN"
zt_log "создана временная учётная запись $PROBE_LOGIN с ролью editor"

# --- Вход по HTTP ------------------------------------------------------------
curl -sS -k -c "$JAR" -o /dev/null "$SITE/wp-login.php"
login_code="$(curl -sS -k -c "$JAR" -b "$JAR" -o /dev/null -w '%{http_code}' \
	--data-urlencode "log=$PROBE_LOGIN" \
	--data-urlencode "pwd=$probe_pw" \
	--data-urlencode "wp-submit=Log In" \
	--data-urlencode "redirect_to=$SITE/wp-admin/" \
	--data-urlencode "testcookie=1" \
	"$SITE/wp-login.php")"
grep -q 'wordpress_logged_in' "$JAR" ||
	zt_die "вход в админку от лица редактора не удался (ответ $login_code) — проверка недостоверна"

# nonce для REST берётся из wpApiSettings: других на странице несколько, и
# первый попавшийся не подходит — REST отвечает rest_cookie_invalid_nonce.
NONCE="$(curl_probe "$SITE/wp-admin/post-new.php" |
	grep -o 'wpApiSettings = {[^}]*}' | grep -o '"nonce":"[a-f0-9]\{8,\}"' | cut -d'"' -f4)"
[ -n "$NONCE" ] || zt_die "не удалось получить nonce для REST — проверка недостоверна"

# --- Что редактору доступно --------------------------------------------------
zt_log "редактору должно быть доступно:"
for page in "" post-new.php edit.php upload.php media-new.php \
	"edit-tags.php?taxonomy=category" "edit-tags.php?taxonomy=post_tag"; do
	c="$(admin_code "$page")"
	[ "$c" = 200 ] && ok "/wp-admin/$page — 200" || bad "/wp-admin/$page — $c"
done

stamp="$(date -u '+%Y%m%d%H%M%S')"
cat_id="$(rest POST categories -d "name=проверка прав $stamp" | json_number id)"
[ -n "$cat_id" ] && ok "категория создана" || bad "категорию создать не удалось"
tag_id="$(rest POST tags -d "name=проверка прав $stamp" | json_number id)"
[ -n "$tag_id" ] && ok "метка создана" || bad "метку создать не удалось"

printf '%s' "$PHOTO_B64" | base64 -d >"$PHOTO" 2>/dev/null
media_json="$(curl_probe -H "X-WP-Nonce: $NONCE" \
	-H "Content-Disposition: attachment; filename=zt-rolecheck-$stamp.jpg" \
	-H "Content-Type: image/jpeg" --data-binary "@$PHOTO" \
	"$SITE/?rest_route=/wp/v2/media")"
media_id="$(printf '%s' "$media_json" | json_number id)"
[ -n "$media_id" ] && ok "файл загружен в медиабиблиотеку" ||
	bad "загрузить файл не удалось: $(printf '%s' "$media_json" | head -c 160)"

post_id="$(rest POST posts \
	-d "title=проверка прав $stamp" \
	-d "content=Черновик, создан проверкой прав." \
	-d "status=draft" \
	-d "categories=${cat_id:-}" \
	-d "tags=${tag_id:-}" \
	-d "featured_media=${media_id:-0}" | json_number id)"
[ -n "$post_id" ] && ok "черновик создан, категория, метка и изображение записи заданы" ||
	bad "черновик создать не удалось"

if [ -n "$post_id" ]; then
	status="$(rest POST "posts/$post_id" -d "status=publish" | json_string status)"
	[ "$status" = publish ] && ok "статья опубликована" || bad "публикация не удалась"
	edited="$(rest POST "posts/$post_id" -d "content=Дополнено после публикации." | json_number id)"
	[ -n "$edited" ] && ok "опубликованная статья правится" || bad "правка после публикации не прошла"
fi

# Правка статей другого автора: обзоры переходят из рук в руки, и запрет здесь
# ломал бы работу. Проверяется правом, а не запросом: изменять чужую статью на
# работающем сайте проверка не должна — след от неё останется в ревизиях.
for cap in edit_others_posts edit_published_posts delete_posts; do
	v="$(zt_wp --user="$PROBE_LOGIN" eval "echo current_user_can('$cap') ? 'yes' : 'no';" 2>/dev/null | tr -d '\r')"
	[ "$v" = yes ] && ok "$cap есть" || bad "$cap отсутствует"
done

# --- Что редактору недоступно ------------------------------------------------
zt_log "редактору должно быть недоступно:"
for page in plugins.php plugin-install.php plugin-editor.php update-core.php \
	users.php user-new.php options-general.php options-permalink.php \
	themes.php theme-editor.php export.php import.php; do
	c="$(admin_code "$page")"
	case "$c" in
		403) ok "/wp-admin/$page — отказ 403" ;;
		302) ok "/wp-admin/$page — доступ не дан (перенаправление)" ;;
		*) bad "/wp-admin/$page — ответ $c, доступ не закрыт" ;;
	esac
done

c="$(curl_probe -H "X-WP-Nonce: $NONCE" -o /dev/null -w '%{http_code}' "$SITE/?rest_route=/wp/v2/plugins")"
[ "$c" = 403 ] && ok "REST: список плагинов — 403" || bad "REST: список плагинов — $c"
c="$(curl_probe -H "X-WP-Nonce: $NONCE" -X POST -o /dev/null -w '%{http_code}' \
	-d "username=zt-rolecheck-intruder" -d "email=intruder@example.invalid" \
	-d "password=$(openssl rand -hex 12)" "$SITE/?rest_route=/wp/v2/users")"
[ "$c" = 403 ] && ok "REST: создание пользователя — 403" || bad "REST: создание пользователя — $c"

# tools.php ядро регистрирует на право edit_posts, поэтому редактор его видит.
# Это штатное поведение WordPress, а не следствие наших настроек; проверяется
# не код ответа, а то, что инструментов на странице нет.
if curl_probe "$SITE/wp-admin/tools.php" |
	grep -qoE 'href="[^"]*(import|export|plugin|user|option|theme)[^"]*\.php'; then
	bad "на tools.php есть ссылки на привилегированные страницы"
else
	ok "tools.php открыт штатно, но инструментов на нём нет"
fi

# --- Сторона разработчика: правка файлов закрыта и ему ------------------------
zt_log "разработчику (роль administrator):"
can() {
	zt_wp --user="$ZT_ADMIN_LOGIN" eval "echo current_user_can('$1') ? 'yes' : 'no';" 2>/dev/null | tr -d '\r'
}
for cap in install_plugins update_core edit_users manage_options; do
	[ "$(can "$cap")" = yes ] && ok "$cap есть" || bad "$cap отсутствует — это не роль администратора"
done
for cap in edit_themes edit_plugins edit_files; do
	[ "$(can "$cap")" = no ] && ok "$cap отсутствует (правка файлов закрыта)" ||
		bad "$cap есть — редактор файлов темы доступен администратору, это дефект"
done
v="$(zt_wp eval 'echo defined("DISALLOW_FILE_EDIT") && DISALLOW_FILE_EDIT ? "yes" : "no";' 2>/dev/null | tr -d '\r')"
[ "$v" = yes ] && ok "DISALLOW_FILE_EDIT действует и в wp-cli" || bad "DISALLOW_FILE_EDIT в wp-cli не действует"

echo
if [ "$fail" -eq 0 ]; then
	zt_log "разделение прав соответствует спеке role-separation"
else
	zt_log "ОШИБКА: разделение прав не соответствует спеке, см. отметки ✗ выше"
fi
exit "$fail"
