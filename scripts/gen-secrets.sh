#!/usr/bin/env bash
# Печатает готовые значения секретов для `.env`: пароли базы и восемь солей
# WordPress. Ничего не записывает — вывод копируется в `.env` руками.
#
# Значения в base64: в них нет символа `$`, который Docker Compose трактует
# в файле окружения как подстановку.
#
# Использование:
#   scripts/gen-secrets.sh          все секреты
#   scripts/gen-secrets.sh salts    только соли и ключи WordPress
#   scripts/gen-secrets.sh db       только пароли базы данных
#   scripts/gen-secrets.sh proxy    только секрет прокси

set -euo pipefail

secret() {
	# 36 байт случайных данных — 48 символов base64.
	openssl rand -base64 36 | tr -d '\n'
	echo
}

print_db() {
	echo "ZT_DB_PASSWORD=$(secret)"
	echo "ZT_DB_ROOT_PASSWORD=$(secret)"
}

# Секрет, которым Caddy подтверждает WordPress, что запрос пришёл через прокси.
print_proxy() {
	echo "ZT_PROXY_TOKEN=$(secret)"
}

print_salts() {
	for name in \
		WORDPRESS_AUTH_KEY \
		WORDPRESS_SECURE_AUTH_KEY \
		WORDPRESS_LOGGED_IN_KEY \
		WORDPRESS_NONCE_KEY \
		WORDPRESS_AUTH_SALT \
		WORDPRESS_SECURE_AUTH_SALT \
		WORDPRESS_LOGGED_IN_SALT \
		WORDPRESS_NONCE_SALT; do
		echo "${name}=$(secret)"
	done
}

command -v openssl >/dev/null || {
	echo "gen-secrets: нужен openssl" >&2
	exit 1
}

case "${1:-all}" in
	all)
		print_db
		print_proxy
		print_salts
		;;
	db)
		print_db
		;;
	proxy)
		print_proxy
		;;
	salts)
		print_salts
		;;
	*)
		echo "gen-secrets: неизвестный аргумент '$1'; ожидается all, db, proxy или salts" >&2
		exit 2
		;;
esac
