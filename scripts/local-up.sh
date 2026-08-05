#!/usr/bin/env bash
# Локальная копия стека для разработки темы.
#
#   ./scripts/local-up.sh          поднять
#   ./scripts/local-up.sh down     остановить, тома сохранить
#   ./scripts/local-up.sh reset    удалить локальные тома и поднять заново
#
# Отличия от сервера — в docker-compose.local.yml: свои тома, порт напрямую
# на localhost:8080, Caddy и TLS не участвуют.
#
# Данные локальной копии живут в отдельных томах, поэтому её изменения не
# затрагивают сервер. Файл `.env` на машине разработки — свой, с заглушками:
# секреты сервера здесь не нужны.
#
# Остальные скрипты работают с локальной копией так же, если задать ZT_LOCAL=1:
#   ZT_LOCAL=1 ./scripts/wp-provision.sh
#   ZT_LOCAL=1 ./scripts/plugins-sync.sh check

set -euo pipefail

. "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

export ZT_LOCAL=1
LOCAL_URL=http://localhost:8080

zt_load_env

case "${1:-up}" in
	down)
		zt_compose down
		zt_log "локальная копия остановлена, тома сохранены"
		exit 0
		;;
	reset)
		zt_log "удаляю локальные тома"
		zt_compose down --volumes
		;;
	up) ;;
	*) zt_die "неизвестный аргумент «$1»; ожидается up, down или reset" ;;
esac

zt_compose up -d

zt_wait_healthy db 240
zt_wait_healthy wordpress 300

zt_log "локальная копия поднята: $LOCAL_URL"
zt_log "правки в wp-content/themes/zt-web и wp-content/mu-plugins видны сразу, без пересборки"
zt_log "первичная настройка, если нужна: ZT_LOCAL=1 ./scripts/wp-provision.sh"
