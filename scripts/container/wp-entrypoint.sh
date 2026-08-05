#!/usr/bin/env bash
# Обёртка вокруг штатной точки входа образа wordpress.
#
# Единственная задача: подставить пределы из окружения в настройки PHP.
# Файлы в conf.d статичны, а предел размера загрузки должен приходить из одной
# переменной — иначе он живёт в трёх местах и рано или поздно разойдётся.
#
# Своего образа не собираем, поэтому скрипт монтируется в контейнер и
# передаёт управление docker-entrypoint.sh образа.

set -euo pipefail

: "${ZT_REQUEST_LIMIT:?не задан ZT_REQUEST_LIMIT}"
: "${ZT_PHP_MEMORY_LIMIT:?не задан ZT_PHP_MEMORY_LIMIT}"

template=/zt/zt-php.ini.template
target=/usr/local/etc/php/conf.d/zt-php.ini

if [ ! -r "$template" ]; then
	echo "wp-entrypoint: не найден шаблон $template" >&2
	exit 1
fi

# Значения вида 80M или 384M: разделителей регулярного выражения в них нет.
sed \
	-e "s/__ZT_REQUEST_LIMIT__/${ZT_REQUEST_LIMIT}/g" \
	-e "s/__ZT_PHP_MEMORY_LIMIT__/${ZT_PHP_MEMORY_LIMIT}/g" \
	"$template" >"$target"

if grep -q '__ZT_' "$target"; then
	echo "wp-entrypoint: в $target остались неподставленные значения" >&2
	exit 1
fi

exec docker-entrypoint.sh "$@"
