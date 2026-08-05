<?php
/**
 * Дополнения к wp-config.php. Версионируется в репозитории и подключается из
 * WORDPRESS_CONFIG_EXTRA через require, поэтому правки применяются
 * перезапуском стека, без пересоздания wp-config.php.
 *
 * Здесь только то, что обязано быть определено до загрузки WordPress:
 * адрес сайта, работа за обратным прокси и запрет правки файлов.
 * Всё остальное — в wp-content/mu-plugins/zt-guardrails.php.
 *
 * @package zt-web
 */

/**
 * Определяет константу, если её ещё нет.
 *
 * Часть констант задаёт сам образ из своих переменных (WP_DEBUG из
 * WORDPRESS_DEBUG, адрес сайта из WORDPRESS_HOME). Повторное define() писало бы
 * предупреждение в журнал на каждом запросе, поэтому определения идут через эту
 * обёртку: значение, заданное образом, имеет приоритет.
 *
 * @param string $name  Имя константы.
 * @param mixed  $value Значение.
 * @return void
 */
function zt_define( $name, $value ) {
	if ( ! defined( $name ) ) {
		define( $name, $value );
	}
}

/*
 * Адрес сайта — из окружения, а не из базы данных.
 *
 * По умолчанию WordPress хранит адрес в опциях. Если бы там оказался IP,
 * переход на домен превратился бы в поиск с заменой по всей базе, включая
 * содержимое статей. С константами это правка переменной и перезапуск.
 */
$zt_site_url = getenv( 'ZT_SITE_URL' );
if ( is_string( $zt_site_url ) && '' !== $zt_site_url ) {
	zt_define( 'WP_HOME', $zt_site_url );
	zt_define( 'WP_SITEURL', $zt_site_url );
}

/*
 * Работа за обратным прокси.
 *
 * Заголовкам можно верить только если запрос пришёл от Caddy, а не напрямую
 * от клиента. Признак этого — непубличный адрес непосредственного узла:
 * снаружи в контейнер попасть нельзя, порт не публикуется, а Caddy обращается
 * к нему по внутренней сети Docker.
 */
$zt_peer = isset( $_SERVER['REMOTE_ADDR'] ) ? $_SERVER['REMOTE_ADDR'] : '';
$zt_behind_proxy = '' !== $zt_peer
	&& false === filter_var(
		$zt_peer,
		FILTER_VALIDATE_IP,
		FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE
	);

if ( $zt_behind_proxy ) {
	// Исходный запрос пришёл по HTTPS: без этого WordPress генерирует ссылки
	// по схеме http и вход в админку уходит в цикл редиректов.
	if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] )
		&& 'https' === strtolower( explode( ',', $_SERVER['HTTP_X_FORWARDED_PROTO'] )[0] ) ) {
		$_SERVER['HTTPS'] = 'on';
		$_SERVER['SERVER_PORT'] = '443';
	}

	// Реальный IP посетителя. Caddy задаёт X-Real-IP значением {client_ip},
	// которое учитывает список доверенных прокси, поэтому при появлении CDN
	// разбор здесь менять не придётся. X-Forwarded-For не используем: его
	// первый элемент клиент может подделать.
	if ( ! empty( $_SERVER['HTTP_X_REAL_IP'] )
		&& filter_var( $_SERVER['HTTP_X_REAL_IP'], FILTER_VALIDATE_IP ) ) {
		$_SERVER['ZT_PROXY_ADDR'] = $zt_peer;
		$_SERVER['REMOTE_ADDR'] = $_SERVER['HTTP_X_REAL_IP'];
	}
} elseif ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) ) {
	/*
	 * Запрос пришёл не от нашего прокси, но принёс X-Forwarded-Proto.
	 *
	 * wp-config.php, сгенерированный образом, доверяет этому заголовку без
	 * проверки источника и уже выставил признак HTTPS. Снимаем его: иначе любой,
	 * кто может обратиться к контейнеру напрямую, заставляет WordPress считать
	 * соединение защищённым. На сервере порт не публикуется и обратиться так
	 * нельзя, но у локальной копии порт открыт, и поведение должно быть
	 * одинаковым в обоих случаях.
	 */
	$zt_scheme = isset( $_SERVER['REQUEST_SCHEME'] ) ? $_SERVER['REQUEST_SCHEME'] : 'http';
	$zt_port = isset( $_SERVER['SERVER_PORT'] ) ? (string) $_SERVER['SERVER_PORT'] : '';
	if ( 'https' !== $zt_scheme && '443' !== $zt_port ) {
		unset( $_SERVER['HTTPS'] );
	}
	unset( $zt_scheme, $zt_port );
}
unset( $zt_peer, $zt_behind_proxy );

/*
 * Правка файлов через админку запрещена всем, включая администратора.
 *
 * Встроенный редактор темы и плагинов позволяет создать на сервере изменение,
 * которого нет в репозитории и которое исчезнет при следующем деплое.
 * Отключение делает границу «код только из git» свойством системы,
 * а не договорённостью.
 *
 * DISALLOW_FILE_MODS сознательно не задан: он запретил бы и установку
 * плагинов из декларативного списка через wp-cli.
 */
zt_define( 'DISALLOW_FILE_EDIT', true );

/*
 * Тип окружения. На локальной копии включаются диагностические сообщения,
 * на сервере они пишутся только в журнал.
 *
 * Сам WP_DEBUG задаёт образ из своей переменной WORDPRESS_DEBUG, поэтому
 * локальная надстройка compose выставляет её в 1; здесь только то, чего
 * образ не задаёт.
 */
$zt_env = getenv( 'ZT_ENV' );
if ( 'local' === $zt_env ) {
	zt_define( 'WP_ENVIRONMENT_TYPE', 'local' );
	zt_define( 'WP_DEBUG_LOG', true );
	zt_define( 'WP_DEBUG_DISPLAY', false );
	zt_define( 'SCRIPT_DEBUG', true );
} else {
	zt_define( 'WP_ENVIRONMENT_TYPE', 'production' );
}
unset( $zt_env );

/*
 * Ревизии статей: черновики редактора сохраняются автоматически, но
 * бесконечная история ревизий раздувает базу, которая уезжает в бэкап целиком.
 */
zt_define( 'WP_POST_REVISIONS', 10 );
zt_define( 'AUTOSAVE_INTERVAL', 60 );

/*
 * Обновления ядра — решение разработчика, выполняемое осознанно, поскольку
 * перед деплоем, затрагивающим базу, создаётся дамп. Автоматические
 * обновления ограничиваем только исправлениями безопасности.
 */
zt_define( 'WP_AUTO_UPDATE_CORE', 'minor' );
