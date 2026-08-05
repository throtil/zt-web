#!/usr/bin/env bash
# Подготовка хоста под стек сайта. Выполняется на сервере от root.
# Воспроизводит шаги 2.1-2.6 из openspec/changes/bootstrap-vps-wordpress/tasks.md
# на чистой машине; каждый шаг идемпотентен.
#
#   ./scripts/host-prepare.sh swap                  файл подкачки 2 ГБ
#   ./scripts/host-prepare.sh sysctl                умеренная swappiness
#   ./scripts/host-prepare.sh docker-check          проверка версий, без установки
#   ./scripts/host-prepare.sh user <логин> <файл-с-публичным-ключом>
#   ./scripts/host-prepare.sh ssh-harden            запрет пароля и входа под root
#   ./scripts/host-prepare.sh backup-dir <логин> [путь]   каталог под дампы
#   ./scripts/host-prepare.sh base                  swap + sysctl + docker-check
#
# ЧЕГО ЭТОТ СКРИПТ НЕ ДЕЛАЕТ, СОЗНАТЕЛЬНО:
#   - не устанавливает и не переустанавливает Docker: он на сервере уже есть;
#   - не включает ufw и не правит правила пакетного фильтра. На машине работает
#     Amnezia (AmneziaWG, UDP 43421), и она держится на транзитном трафике:
#     включение ufw — самый вероятный способ уронить VPN. Порты 80 и 443
#     свободны, публикации их Docker'ом достаточно, изменения файрвола не нужны.
#
# После любого шага, затрагивающего сеть или ресурсы хоста, работоспособность
# Amnezia проверяется отдельно — подключением VPN-клиента. Из того, что сайт
# отвечает, это не следует.

set -euo pipefail

SWAPFILE=/swapfile
SWAPSIZE_MB=2048
SYSCTL_FILE=/etc/sysctl.d/99-zt-web.conf
SSHD_DROPIN=/etc/ssh/sshd_config.d/99-zt-web.conf
COMPOSE_MIN=2.20

log() { printf '==> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }
die() {
	printf 'ОШИБКА: %s\n' "$*" >&2
	exit 1
}

require_root() {
	[ "$(id -u)" -eq 0 ] || die "нужны права root"
}

step_swap() {
	require_root

	if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
		log "подкачка $SWAPFILE уже включена"
	else
		if [ ! -e "$SWAPFILE" ]; then
			local avail_mb
			avail_mb="$(df --output=avail -m / | tail -1 | tr -d ' ')"
			# Оставляем запас: диск делится с Amnezia, загрузками и дампами.
			[ "$avail_mb" -gt $((SWAPSIZE_MB + 4096)) ] ||
				die "на / свободно ${avail_mb} МБ — мало для файла подкачки ${SWAPSIZE_MB} МБ с запасом"

			log "создаю $SWAPFILE на ${SWAPSIZE_MB} МБ"
			# dd, а не fallocate: на некоторых файловых системах разреженный
			# файл подкачки не принимается ядром.
			dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAPSIZE_MB" status=none
		fi
		chmod 600 "$SWAPFILE"
		if ! file "$SWAPFILE" 2>/dev/null | grep -q 'swap file'; then
			mkswap "$SWAPFILE" >/dev/null
		fi
		swapon "$SWAPFILE"
		log "подкачка включена"
	fi

	if grep -qs "^${SWAPFILE}[[:space:]]" /etc/fstab; then
		log "запись в /etc/fstab уже есть"
	else
		printf '%s none swap sw 0 0\n' "$SWAPFILE" >>/etc/fstab
		log "добавлена запись в /etc/fstab — подкачка переживёт перезагрузку"
	fi

	free -m | sed 's/^/    /'
}

step_sysctl() {
	require_root

	cat >"$SYSCTL_FILE" <<'EOF'
# Подкачка здесь — запас на короткий пик обработки изображений, а не
# постоянно используемая память: на 981 МБ без неё запаса нет вообще.
# Умеренное значение: система прибегает к подкачке под давлением,
# но не выталкивает страницы заранее.
vm.swappiness = 10

# Кэш метаданных файловой системы освобождается охотнее: на этой машине
# память нужнее процессам обработки изображений.
vm.vfs_cache_pressure = 50
EOF
	sysctl --system >/dev/null
	log "применено: $(sysctl -n vm.swappiness) — vm.swappiness, $(sysctl -n vm.vfs_cache_pressure) — vm.vfs_cache_pressure"
}

step_docker_check() {
	command -v docker >/dev/null || die "docker не найден, а устанавливать его этот скрипт не должен"

	log "docker: $(docker --version)"

	local compose_version
	compose_version="$(docker compose version --short 2>/dev/null || true)"
	[ -n "$compose_version" ] || die "плагин docker compose не найден: нужен Compose v2, обновить только плагин"

	log "docker compose: $compose_version"

	# Стек опирается на depends_on с условием готовности, профили сервисов и
	# oom_score_adj. Всё это есть в Compose v2 начиная с 2.20.
	if [ "$(printf '%s\n%s\n' "$COMPOSE_MIN" "$compose_version" | sort -V | head -1)" != "$COMPOSE_MIN" ]; then
		warn "версия Compose ниже $COMPOSE_MIN: обновить нужно только плагин docker-compose-plugin, не Docker"
		warn "после обновления проверить, что контейнер Amnezia продолжает работать: docker ps"
	fi

	if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
		warn "ufw активен, хотя по решению итерации он не используется — см. design.md"
	else
		log "ufw не активен — так и оставляем"
	fi

	log "правил пакетного фильтра сейчас: $(iptables-save 2>/dev/null | grep -c '^-A' || echo '?') (принадлежат Amnezia, не трогаем)"
}

step_user() {
	require_root

	local login="${1:-}" keyfile="${2:-}"
	[ -n "$login" ] || die "использование: $0 user <логин> <файл-с-публичным-ключом>"
	[ -n "$keyfile" ] || die "использование: $0 user <логин> <файл-с-публичным-ключом>"
	[ -r "$keyfile" ] || die "не читается файл с публичным ключом: $keyfile"
	grep -qE '^(ssh|ecdsa)-' "$keyfile" || die "$keyfile не похож на публичный ключ SSH"

	if id -u "$login" >/dev/null 2>&1; then
		log "пользователь $login уже есть"
	else
		adduser --disabled-password --gecos '' "$login"
		log "создан пользователь $login без пароля — вход только по ключу"
	fi

	getent group docker >/dev/null || die "группы docker нет: Docker установлен иначе, чем ожидается"
	usermod -aG docker "$login"
	log "$login добавлен в группу docker"

	local home ssh_dir
	home="$(getent passwd "$login" | cut -d: -f6)"
	ssh_dir="$home/.ssh"
	install -d -m 700 -o "$login" -g "$login" "$ssh_dir"
	touch "$ssh_dir/authorized_keys"
	# Ключ добавляется, а не затирает файл: у пользователя может быть второй.
	if ! grep -qxFf "$keyfile" "$ssh_dir/authorized_keys" 2>/dev/null; then
		cat "$keyfile" >>"$ssh_dir/authorized_keys"
		log "ключ добавлен в $ssh_dir/authorized_keys"
	else
		log "такой ключ уже есть в authorized_keys"
	fi
	chmod 600 "$ssh_dir/authorized_keys"
	chown "$login:$login" "$ssh_dir/authorized_keys"

	cat <<EOF

Дальше — проверка ДО запрета пароля, с другой машины и в отдельном окне:

    ssh $login@<адрес сервера> "id && docker ps"

Убедившись, что вход по ключу работает и docker доступен без sudo, выполнить:

    ZT_SSH_HARDEN_CONFIRMED=yes $0 ssh-harden

EOF
}

step_ssh_harden() {
	require_root

	[ "${ZT_SSH_HARDEN_CONFIRMED:-}" = "yes" ] || die \
		"шаг опасен без проверки: сначала убедиться, что вход по ключу работает, затем запустить с ZT_SSH_HARDEN_CONFIRMED=yes"

	[ -d /etc/ssh/sshd_config.d ] || die "нет /etc/ssh/sshd_config.d — проверить, что sshd_config подключает Include"
	grep -qs '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config ||
		warn "в sshd_config нет Include для sshd_config.d — правки могут не примениться, проверить вручную"

	cat >"$SSHD_DROPIN" <<'EOF'
# Гигиена доступа обеспечивается на уровне SSH, а не пакетным фильтром:
# файрвол на этой машине не используется, чтобы не сломать Amnezia.

# Несущая часть шага: пока пароль принимается, 22-й порт открыт наружу и
# перебор имени root — вопрос времени. Без пароля угадывать нечего.
PasswordAuthentication no
KbdInteractiveAuthentication no

# prohibit-password, а не no: вход под root по ключу остаётся.
#
# Полный запрет root выглядит строже, но здесь почти ничего не даёт, а ломает
# многое. Не даёт — потому что рабочий пользователь состоит в группе `docker`,
# а из неё root получается одной командой (`docker run -v /:/host --privileged`);
# разграничение «zt против root» при таком членстве косметическое. Ломает —
# потому что пользователь создаётся с --disabled-password и в группе sudo не
# состоит: при `PermitRootLogin no` root недостижим ни по SSH, ни через sudo,
# остаётся только консоль провайдера. А root ещё нужен: каталог дампов,
# /etc/cron.d, обновления.
#
# Если когда-нибудь понадобится именно полный запрет — сначала решить, как
# рабочий пользователь получает root (sudo с паролем или NOPASSWD-правило),
# и только потом менять это значение. Само по себе оно запирает обслуживание.
PermitRootLogin prohibit-password
EOF
	chmod 644 "$SSHD_DROPIN"

	sshd -t || {
		rm -f "$SSHD_DROPIN"
		die "проверка конфигурации sshd не прошла, изменения откачены"
	}

	# reload, а не restart: текущие сессии не разрываются, и при ошибке
	# остаётся открытое подключение, чтобы всё исправить.
	systemctl reload ssh 2>/dev/null || systemctl reload sshd
	log "вход по паролю запрещён; root — только по ключу; текущая сессия не разорвана"
	log "проверить новым подключением ДО закрытия текущего окна"
	log "пароль учётной записи root для входа по SSH теперь не используется — сменить его отдельно, он остаётся действительным на консоли провайдера"
}

step_backup_dir() {
	require_root

	local login="${1:-}" dir="${2:-/var/backups/zt-web}"
	[ -n "$login" ] || die "использование: $0 backup-dir <логин> [путь]"
	id -u "$login" >/dev/null 2>&1 || die "нет пользователя $login"

	# Каталог создаётся заранее и от root, чтобы бэкап из cron мог работать от
	# непривилегированного пользователя: /var/backups ему не принадлежит.
	install -d -m 700 -o "$login" -g "$login" "$dir"
	log "каталог $dir создан, владелец $login, права 700"
	log "то же значение должно стоять в ZT_BACKUP_DIR в .env"
}

case "${1:-}" in
	swap) step_swap ;;
	sysctl) step_sysctl ;;
	docker-check) step_docker_check ;;
	user)
		shift
		step_user "$@"
		;;
	ssh-harden) step_ssh_harden ;;
	backup-dir)
		shift
		step_backup_dir "$@"
		;;
	base)
		step_swap
		step_sysctl
		step_docker_check
		cat <<'EOF'

Готово. Дальше:
  1. ./scripts/host-prepare.sh user <логин> <ключ.pub>
  2. проверить вход по ключу, затем ssh-harden
  3. проверить VPN-подключение Amnezia — отдельной проверкой
EOF
		;;
	*)
		sed -n '2,30p' "$0"
		exit 2
		;;
esac
