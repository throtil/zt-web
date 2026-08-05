#!/usr/bin/env bash
# Общая часть скриптов: поиск корня репозитория, загрузка окружения,
# обёртка над docker compose, сообщения.
#
# Подключается через `. "$(dirname "$0")/lib/common.sh"`.

# shellcheck shell=bash

ZT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ZT_ROOT="$(dirname -- "$ZT_ROOT")"
export ZT_ROOT

zt_log() {
	printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

zt_die() {
	printf '%s  ОШИБКА: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
	exit 1
}

# Загружает `.env` в окружение. Файл разбирается построчно, значения не
# интерпретируются оболочкой: пароли и соли содержат символы, которые
# `source` истолковал бы по-своему.
#
# Переменная, уже заданная в окружении, не перезаписывается — так же, как это
# делает сам docker compose при подстановке. Это позволяет разово подменить
# значение: ZT_BACKUP_DIR=/tmp/copy ./scripts/backup-db.sh --local
zt_load_env() {
	local env_file="${1:-$ZT_ROOT/.env}"

	[ -r "$env_file" ] || zt_die "не найден файл окружения $env_file (см. .env.example)"

	local line key value
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			''|'#'*) continue ;;
		esac
		case "$line" in
			*=*) ;;
			*) continue ;;
		esac
		key="${line%%=*}"
		value="${line#*=}"
		# Убираем пробелы вокруг имени и обрамляющие кавычки у значения.
		key="${key// /}"
		key="${key#export}"
		# Уже заданное в окружении значение имеет приоритет.
		if [ -n "${!key:-}" ]; then
			continue
		fi
		case "$value" in
			\"*\") value="${value:1:${#value}-2}" ;;
			\'*\') value="${value:1:${#value}-2}" ;;
		esac
		printf -v "$key" '%s' "$value" 2>/dev/null || continue
		export "${key?}"
	done <"$env_file"
}

# Проверяет, что переменные заданы и непусты. Сообщает обо всех недостающих
# сразу, а не по одной за запуск.
zt_require() {
	local missing=()
	local name
	for name in "$@"; do
		if [ -z "${!name:-}" ]; then
			missing+=("$name")
		fi
	done
	if [ "${#missing[@]}" -gt 0 ]; then
		zt_die "не заданы или пусты переменные: ${missing[*]}"
	fi
}

# Обёртка над docker compose. При ZT_LOCAL=1 добавляется надстройка локальной
# копии: иначе служебные команды (wp-cli, дамп) обращались бы к томам сервера,
# а не к локальным.
zt_compose() {
	local files=(-f "$ZT_ROOT/docker-compose.yml")
	if [ "${ZT_LOCAL:-0}" = "1" ]; then
		files+=(-f "$ZT_ROOT/docker-compose.local.yml")
	fi
	docker compose --project-directory "$ZT_ROOT" "${files[@]}" "$@"
}

# Запускает wp-cli в служебном контейнере, подключённом к тому же тому и сети.
# Точка входа образа ожидает команду, начинающуюся с `wp`.
zt_wp() {
	zt_compose --profile tools run --rm -T wpcli wp "$@"
}

# Проверяет, что стек запущен: без этого сообщения об ошибках wp-cli
# нечитаемы.
zt_require_stack_running() {
	local state
	state="$(zt_compose ps --status running --services 2>/dev/null || true)"
	case "$state" in
		*wordpress*) ;;
		*) zt_die "стек не запущен: сначала docker compose up -d" ;;
	esac
}

# Запущен ли сервис. Отдельная функция, а не `... | grep -qx имя`, по причине,
# описанной у zt_gz_has: конвейер с досрочно выходящим потребителем при
# включённом pipefail даёт случайный ложный ответ. Здесь цена такого ответа
# особенно велика — deploy.sh по нему решает, снимать ли дамп перед деплоем,
# и ложное «не запущена» означало бы молча пропущенную резервную копию.
zt_service_running() {
	local service="$1" state
	state="$(zt_compose ps --status running --services 2>/dev/null || true)"
	case $'\n'"$state"$'\n' in
		*$'\n'"$service"$'\n'*) return 0 ;;
		*) return 1 ;;
	esac
}

# Ищет образец в сжатом файле.
#
# Написано подстановкой процесса, а не конвейером `gzip -dc … | grep -q …`,
# и это не стилистика. При `set -o pipefail` такой конвейер даёт СЛУЧАЙНЫЙ
# ложный отказ: grep выходит по первому совпадению, gzip получает SIGPIPE и
# завершается кодом 141, а pipefail делает его кодом всего конвейера. Замер на
# дампе в 22 КБ: 44 ложных отказа из 100 запусков. Годный дамп при этом
# объявлялся негодным, бэкап из cron падал бы почти каждую вторую ночь, а
# деплой срывался бы без внятной причины.
#
# Подстановка процесса выводит распаковщик из конвейера: код возврата даёт
# только grep, а завершение gzip по SIGPIPE никого не касается.
zt_gz_has() {
	local file="$1" pattern="$2"
	grep -qm1 -- "$pattern" < <(gzip -dc -- "$file" 2>/dev/null)
}

# То же для хвоста файла: завершающая отметка mariadb-dump.
zt_gz_tail_has() {
	local file="$1" pattern="$2" bytes="${3:-200}"
	grep -q -- "$pattern" < <(gzip -dc -- "$file" 2>/dev/null | tail -c "$bytes")
}

# Ждёт, пока сервис не станет healthy. Аргументы: имя сервиса, предел в секундах.
zt_wait_healthy() {
	local service="$1" timeout="${2:-180}" waited=0 cid status
	while :; do
		cid="$(zt_compose ps -q "$service" 2>/dev/null || true)"
		if [ -n "$cid" ]; then
			status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo unknown)"
			case "$status" in
				healthy) return 0 ;;
				none) zt_log "у сервиса $service нет проверки готовности, считаем запущенным"; return 0 ;;
			esac
		fi
		if [ "$waited" -ge "$timeout" ]; then
			zt_die "сервис $service не прошёл проверку готовности за ${timeout} с (состояние: ${status:-нет контейнера})"
		fi
		sleep 5
		waited=$((waited + 5))
	done
}

# Проверяет, что страница отвечает не ошибкой сервера. Аргументы: адрес, что
# проверяем. Считает успехом любой код кроме 5xx и отсутствия ответа:
# редирект на HTTPS и 302 в админке — нормальные ответы.
zt_check_url() {
	local url="$1" what="${2:-страница}" code
	# Страховка ставится присваиванием, а не `|| echo 000` внутри подстановки.
	# curl печатает %{http_code} и при неудаче — там будет «000» — и при этом
	# возвращает ненулевой код. Прежний `|| echo 000` дописывал второе значение
	# к первому: получалось «000000», что не совпадало с образцом 000 ниже и
	# уходило в ветку успеха. Деплой при полностью недоступном сайте объявлял
	# себя успешным — то есть проверка, ради которой этот шаг существует, не
	# работала вовсе.
	code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -k "$url" 2>/dev/null)" || code=000
	# Любой неожиданный вид ответа считаем отсутствием ответа, а не успехом.
	case "$code" in
		[0-9][0-9][0-9]) ;;
		*) code=000 ;;
	esac
	case "$code" in
		000) zt_die "$what не отвечает: $url" ;;
		5*) zt_die "$what отвечает ошибкой сервера $code: $url" ;;
		*) zt_log "$what отвечает $code: $url" ;;
	esac
}
