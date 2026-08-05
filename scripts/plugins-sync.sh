#!/usr/bin/env bash
# Сверка установленного набора плагинов с декларативным списком plugins.txt
# и приведение набора в соответствие.
#
#   ./scripts/plugins-sync.sh check    показать расхождения, ничего не менять
#   ./scripts/plugins-sync.sh apply    привести набор к списку
#
# `check` завершается кодом 1 при любом расхождении: годится как шаг проверки
# перед вводом сервера в работу.
#
# wp-cli запускается в служебном контейнере, подключённом к тому же тому и
# сети, что и WordPress. Своего wp-cli на хосте не нужно.

set -euo pipefail

. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

PLUGINS_FILE="$ZT_ROOT/plugins.txt"

usage() {
	sed -n '2,12p' "$0"
	exit 2
}

# Читает plugins.txt в массив строк `slug версия`.
read_declared() {
	[ -r "$PLUGINS_FILE" ] || zt_die "не найден $PLUGINS_FILE"

	local line slug version
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%%#*}"
		line="$(printf '%s' "$line" | tr -d '[:space:]')"
		[ -n "$line" ] || continue
		case "$line" in
			*==*) ;;
			*) zt_die "строка «$line» в plugins.txt не в формате slug==версия" ;;
		esac
		slug="${line%%==*}"
		version="${line##*==}"
		[ -n "$slug" ] && [ -n "$version" ] || zt_die "строка «$line» в plugins.txt неполна"
		printf '%s %s\n' "$slug" "$version"
	done <"$PLUGINS_FILE"
}

# Читает установленный набор в том же формате.
#
# mu-plugin и dropin-файлы исключаются: они версионируются в репозитории как
# свой код, а не устанавливаются как сторонние плагины, и в списке их быть
# не должно.
read_installed() {
	zt_wp plugin list --fields=name,version,status --format=csv 2>/dev/null |
		tail -n +2 | tr -d '\r' |
		awk -F, 'NF >= 3 && $3 != "must-use" && $3 != "dropin" { print $1, $2 }'
}

main() {
	local mode="${1:-}"
	case "$mode" in
		check | apply) ;;
		*) usage ;;
	esac

	zt_load_env
	zt_require_stack_running

	local declared installed
	declared="$(read_declared)"
	installed="$(read_installed)" || zt_die "не удалось получить список плагинов через wp-cli"

	local missing=() extra=() mismatched=()
	local slug version installed_version

	while read -r slug version; do
		[ -n "${slug:-}" ] || continue
		installed_version="$(printf '%s\n' "$installed" | awk -v s="$slug" '$1 == s { print $2 }')"
		if [ -z "$installed_version" ]; then
			missing+=("$slug==$version")
		elif [ "$installed_version" != "$version" ]; then
			mismatched+=("$slug: установлена $installed_version, в списке $version")
		fi
	done <<<"$declared"

	while read -r slug version; do
		[ -n "${slug:-}" ] || continue
		if ! printf '%s\n' "$declared" | awk -v s="$slug" '$1 == s { found = 1 } END { exit !found }'; then
			extra+=("$slug (установлена $version)")
		fi
	done <<<"$installed"

	local diverged=0

	if [ "${#missing[@]}" -gt 0 ]; then
		diverged=1
		zt_log "отсутствуют, но перечислены в списке:"
		printf '    %s\n' "${missing[@]}"
	fi
	if [ "${#mismatched[@]}" -gt 0 ]; then
		diverged=1
		zt_log "версия отличается от списка:"
		printf '    %s\n' "${mismatched[@]}"
	fi
	if [ "${#extra[@]}" -gt 0 ]; then
		diverged=1
		zt_log "установлены в обход списка:"
		printf '    %s\n' "${extra[@]}"
	fi

	if [ "$diverged" -eq 0 ]; then
		zt_log "набор плагинов соответствует plugins.txt"
		return 0
	fi

	if [ "$mode" = check ]; then
		zt_log "расхождение обнаружено; привести набор в соответствие: $0 apply"
		return 1
	fi

	# apply: сначала доустановить и выровнять версии, потом убрать лишние.
	# Порядок важен: удаление в конце не мешает установке при частичной ошибке.
	local item
	for item in "${missing[@]:-}"; do
		[ -n "$item" ] || continue
		slug="${item%%==*}"
		version="${item##*==}"
		zt_log "устанавливаю $slug $version"
		zt_wp plugin install "$slug" --version="$version" --activate ||
			zt_die "не удалось установить $slug $version"
	done

	for item in "${mismatched[@]:-}"; do
		[ -n "$item" ] || continue
		slug="${item%%:*}"
		version="$(printf '%s\n' "$declared" | awk -v s="$slug" '$1 == s { print $2 }')"
		zt_log "привожу $slug к версии $version"
		zt_wp plugin install "$slug" --version="$version" --force --activate ||
			zt_die "не удалось привести $slug к версии $version"
	done

	for item in "${extra[@]:-}"; do
		[ -n "$item" ] || continue
		slug="${item%% *}"
		zt_log "удаляю $slug — его нет в списке"
		zt_wp plugin delete "$slug" || zt_die "не удалось удалить $slug"
	done

	zt_log "набор приведён к plugins.txt; проверяю"
	main check
}

main "$@"
