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
probe_cat_id=""
assign_cat_id=""
tag_id=""
gs_id=""
gs_backup=""
gs_dirty=0

# Цвет, которым проверяется правка глобальных стилей. Значение заведомо
# неудобное для человека: по нему тестовая правка отличается от того, что на
# сайте было, а совпадение с выбором редактора сделало бы проверку ложной —
# поэтому перед правкой ещё и проверяется, что его на странице нет.
GS_PROBE_COLOR='#101017'

# Пробное изображение — настоящий JPEG 8×8, вшитый в скрипт: проверяется право
# загружать файлы, а не обработка больших изображений (это задачи группы 4).
# WordPress проверяет содержимое загружаемого файла, поэтому заглушка из
# случайных байт не подошла бы.
PHOTO_B64='/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8l
JCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/wAALCAAIAAgBAREA/8QAFAAB
AAAAAAAAAAAAAAAAAAAAAv/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AL//Z'

cleanup() {
	# Стили возвращаются первыми и до удаления файла с печеньками: правка
	# глобальных стилей — единственное, что проверка меняет на самом сайте, а не
	# в своей песочнице, и оставить её после прерывания нельзя. Функция
	# определена ниже, вместе с остальными обёртками над curl.
	zt_restore_styles ||
		zt_log "ВНИМАНИЕ: не удалось вернуть прежние глобальные стили — отменить правку в админке («Ревизии» в редакторе сайта)"
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
	[ -n "$probe_cat_id" ] && zt_wp term delete category "$probe_cat_id" >/dev/null 2>&1
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
# Список идентификаторов (`"categories":[7]`) — запятыми, с запятой на конце,
# чтобы искать вхождение целого числа, а не подстроки: иначе 7 нашлось бы в 17.
json_ids() { grep -o "\"$1\":\[[0-9,]*\]" | head -1 | grep -o '[0-9]\{1,\}' | tr '\n' ','; }
has_id() { case ",$2" in *",$1,"*) return 0 ;; esac; return 1; }

# Есть ли образец в тексте. Сопоставлением оболочки, а не `printf … | grep -q`:
# конвейер с досрочно выходящим потребителем при включённом pipefail даёт
# случайный ложный ответ — ловушка разобрана в lib/common.sh у zt_gz_has.
body_has() {
	case "$1" in
		*"$2"*) return 0 ;;
		*) return 1 ;;
	esac
}

# Возврат прежних глобальных стилей. Вызывается и в обычном ходе проверки, и из
# cleanup: если проверка прервана на середине, тестовый цвет иначе остался бы на
# сайте. Возврат идёт тем же способом, что и правка, — через REST от лица
# редактора: проверяется обратимость средствами админки, без сервера.
zt_restore_styles() {
	[ "$gs_dirty" -eq 1 ] || return 0

	local answer
	answer="$(curl_probe -H "X-WP-Nonce: ${NONCE:-}" -H 'Content-Type: application/json' -X POST \
		--data "{\"styles\":$gs_backup}" "$SITE/?rest_route=/wp/v2/global-styles/$gs_id")"

	if body_has "$answer" '"id":'; then
		gs_dirty=0
		return 0
	fi

	return 1
}

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
	"edit-tags.php?taxonomy=post_tag" site-editor.php; do
	c="$(admin_code "$page")"
	[ "$c" = 200 ] && ok "/wp-admin/$page — 200" || bad "/wp-admin/$page — $c"
done

stamp="$(date -u '+%Y%m%d%H%M%S')"
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

# Рубрику проверка не создаёт: право на рубрики у редактора отобрано (это
# проверяется ниже), а назначить существующую он обязан уметь — назначение
# рубрики входит в цикл заполнения обзора по спеке role-separation. Берётся
# рубрика из дерева, заданного кодом в zt-structure.php: она есть на любом
# поднятом сайте, поэтому удалять её после проверки не нужно и нельзя.
assign_cat_id="$(zt_wp term get category sintetika --by=slug --field=term_id 2>/dev/null | tr -d '\r\n')"

post_args=(
	-d "title=проверка прав $stamp"
	-d "content=Черновик, создан проверкой прав."
	-d "status=draft"
)
# Пустые значения не отправляются вовсе: `categories=` ядро приняло бы за
# отсутствие рубрик, и проверка молча перестала бы проверять назначение.
if [ -n "$assign_cat_id" ]; then
	post_args+=(-d "categories=$assign_cat_id")
else
	bad "рубрики sintetika нет в дереве — назначение рубрики не проверено"
fi
[ -n "$tag_id" ] && post_args+=(-d "tags=$tag_id")
[ -n "$media_id" ] && post_args+=(-d "featured_media=$media_id")

post_json="$(rest POST posts "${post_args[@]}")"
post_id="$(printf '%s' "$post_json" | json_number id)"
[ -n "$post_id" ] && ok "черновик создан" || bad "черновик создать не удалось"

# Назначенное проверяется по ответу, а не объявляется вместе с созданием: одна
# строка на три утверждения означала, что об отказе любого из них узнать нельзя.
if [ -n "$post_id" ]; then
	if [ -n "$assign_cat_id" ]; then
		has_id "$assign_cat_id" "$(printf '%s' "$post_json" | json_ids categories)" &&
			ok "существующая рубрика назначена статье" ||
			bad "рубрику назначить не удалось"
	fi
	if [ -n "$tag_id" ]; then
		has_id "$tag_id" "$(printf '%s' "$post_json" | json_ids tags)" &&
			ok "метка назначена статье" || bad "метку назначить не удалось"
	fi
	if [ -n "$media_id" ]; then
		[ "$(printf '%s' "$post_json" | json_number featured_media)" = "$media_id" ] &&
			ok "изображение записи задано" || bad "изображение записи задать не удалось"
	fi
fi

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

# --- Слой оформления: стили и меню редактору открыты --------------------------
#
# Право одно на всё оформление: `edit_theme_options`. Отдельного права на
# глобальные стили в WordPress нет, поэтому проверяется не наличие права, а то,
# что стиль действительно меняется и возвращается обратно без разработчика.
zt_log "редактор меняет оформление в пределах своего слоя:"

# Запись глобальных стилей у темы одна, и её идентификатор спрашивается у самой
# админки — ссылкой `user-global-styles` в ответе о текущей теме, так же, как его
# берёт редактор блоков.
#
# Не через wp-cli, и это не стилистика. Ядро создаёт эту запись с привязкой к
# теме через `tax_input`, а `wp_insert_post` применяет его только если у текущего
# пользователя есть право назначать метки таксономии. Под wp-cli пользователя
# нет, поэтому запись создаётся без привязки — а ищется ядром именно по ней. То
# есть прежний вариант при каждом запуске заводил ещё одну запись глобальных
# стилей, которую сайт не читает, и проверял правку на этой пустышке. Найдено
# сверкой записей wp_global_styles после двух запусков 6 августа 2026.
gs_id="$(curl_probe -H "X-WP-Nonce: $NONCE" "$SITE/?rest_route=/wp/v2/themes&status=active" |
	grep -o 'user-global-styles":\[{"href":"[^"]*' | grep -o '[0-9]\{1,\}$')"

if [ -z "$gs_id" ] || [ "$gs_id" = 0 ]; then
	bad "не удалось узнать запись глобальных стилей у /wp/v2/themes — проверка слоя оформления не выполнена"
else
	before="$(curl_probe -H "X-WP-Nonce: $NONCE" "$SITE/?rest_route=/wp/v2/global-styles/$gs_id")"
	if body_has "$before" '"id":'; then
		ok "глобальные стили читаются"
	else
		bad "глобальные стили не читаются: $(printf '%s' "$before" | head -c 120)"
	fi

	# Прежние стили снимаются ДО правки и ими же возвращаются. Прежде в возврате
	# уходило `{"styles":{}}` — это не возврат, а сброс: ядро заменяет дерево
	# стилей целиком, поэтому на работающем сайте такая «отмена» снесла бы всё
	# оформление, которое набрал редактор, а не только тестовый цвет.
	#
	# Разбор JSON отдан PHP из контейнера: `styles` — вложенное дерево, и grep
	# его не вырежет. Значение при этом взято из ответа REST, полученного от лица
	# редактора, — обратимость по-прежнему проверяется средствами админки, а
	# контейнер здесь только разборщик.
	gs_backup="$(printf '%s' "$before" | zt_wp eval \
		'echo wp_json_encode( json_decode( file_get_contents( "php://stdin" ) )->styles ?? new stdClass() );' \
		2>/dev/null | tr -d '\r\n')"

	if [ "${gs_backup:0:1}" != '{' ]; then
		bad "не удалось снять прежние глобальные стили — правка не делалась, чтобы её было чем отменить"
	elif body_has "$(curl_probe "$SITE/")" "$GS_PROBE_COLOR"; then
		bad "цвет $GS_PROBE_COLOR уже есть на сайте — тестовую правку по нему не отличить, стили не менялись"
	else
		# Признак ставится до запроса, а не после успешного ответа: неизвестно,
		# успел ли отказавший запрос записать что-то, и возврат заведомого
		# состояния безвреден, а невозврат — нет.
		gs_dirty=1
		changed="$(curl_probe -H "X-WP-Nonce: $NONCE" -H 'Content-Type: application/json' -X POST \
			--data "{\"styles\":{\"color\":{\"background\":\"$GS_PROBE_COLOR\"}}}" \
			"$SITE/?rest_route=/wp/v2/global-styles/$gs_id")"
		if body_has "$changed" "$GS_PROBE_COLOR"; then
			ok "цвет изменён редактором"
		else
			bad "изменить цвет не удалось: $(printf '%s' "$changed" | head -c 160)"
		fi

		if body_has "$(curl_probe "$SITE/")" "$GS_PROBE_COLOR"; then
			ok "изменение видно на сайте"
		else
			bad "изменение на сайте не видно"
		fi

		if zt_restore_styles && ! body_has "$(curl_probe "$SITE/")" "$GS_PROBE_COLOR"; then
			ok "прежнее состояние возвращено средствами админки"
		else
			bad "вернуть прежнее состояние не удалось"
		fi
	fi
fi

# --- Что редактору недоступно ------------------------------------------------
zt_log "редактору должно быть недоступно:"

probe_cat_id="$(rest POST categories -d "name=проверка прав $stamp" | json_number id)"
if [ -z "$probe_cat_id" ]; then
	ok "рубрику создать не удалось — структура сайта редактору закрыта"
else
	bad "рубрика создана: право на рубрики не отобрано"
fi

c="$(admin_code "edit-tags.php?taxonomy=category")"
case "$c" in
	403|302) ok "/wp-admin/edit-tags.php?taxonomy=category — доступ не дан ($c)" ;;
	*) bad "/wp-admin/edit-tags.php?taxonomy=category — ответ $c, доступ не закрыт" ;;
esac

for page in plugins.php plugin-install.php plugin-editor.php update-core.php \
	users.php user-new.php options-general.php options-permalink.php \
	theme-editor.php export.php import.php; do
	c="$(admin_code "$page")"
	case "$c" in
		403) ok "/wp-admin/$page — отказ 403" ;;
		302) ok "/wp-admin/$page — доступ не дан (перенаправление)" ;;
		*) bad "/wp-admin/$page — ответ $c, доступ не закрыт" ;;
	esac
done

# Установка тем закрыта, но не кодом 403: ядро вызывает здесь wp_die() без
# указания кода, а он по умолчанию 500. Отказ настоящий, вид у него неудачный.
# Поэтому проверяется тело ответа, а не код: иначе строка выглядела бы дефектом
# наших настроек, каковым не является.
if printf '%s' "$(curl_probe "$SITE/wp-admin/theme-install.php")" |
	grep -q 'not allowed to install themes'; then
	ok "/wp-admin/theme-install.php — отказ (кодом 500, так устроено ядро)"
else
	bad "/wp-admin/theme-install.php — отказа нет, установка тем не закрыта"
fi

# themes.php отдельной строкой и не по коду ответа.
#
# Право `edit_theme_options`, которым редактор меняет цвета и меню, открывает
# ему и список тем: ядро пускает на themes.php по любому из двух прав. Отдельно
# закрыть список нельзя, не отобрав вместе с ним стили. Значение имеет не
# видимость списка, а невозможность сменить тему — её и проверяем.
for cap in switch_themes install_themes delete_themes update_themes; do
	v="$(zt_wp --user="$PROBE_LOGIN" eval "echo current_user_can('$cap') ? 'yes' : 'no';" 2>/dev/null | tr -d '\r')"
	[ "$v" = no ] && ok "$cap отсутствует" || bad "$cap есть — тему можно сменить или поставить"
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
