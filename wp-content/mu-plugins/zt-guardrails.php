<?php
/**
 * Plugin Name: zt-web guardrails
 * Description: Правила, которые обязаны воспроизводиться при пересоздании сервера: обработка изображений, предел загрузки, права ролей, закрытая индексация.
 * Version: 1.0.0
 * Author: zt-web
 *
 * Это mu-plugin: он загружается всегда и не может быть отключён из админки.
 * Всё, что здесь задано, задано кодом в репозитории, а не кликами в админке,
 * и поэтому переживает пересоздание сервера.
 *
 * Определения, которые нужны раньше загрузки WordPress (адрес сайта, работа
 * за прокси, запрет правки файлов), лежат в config/wordpress/wp-config-zt.php.
 *
 * @package zt-web
 */

defined( 'ABSPATH' ) || exit;

/**
 * Версия набора правил для ролей. Увеличивается при изменении списка прав
 * ниже: по несовпадению с сохранённым значением права переназначаются.
 */
const ZT_ROLES_VERSION = '1';

/**
 * Запас в байтах на накладные расходы multipart-запроса.
 *
 * Предел размера тела запроса един для Caddy и PHP (ZT_REQUEST_LIMIT), но файл
 * идёт в запросе не один: есть границы частей, имя файла и поля формы. Если
 * показать редактору предел, равный размеру запроса, файл ровно по этому
 * пределу будет отклонён уже после нескольких минут загрузки.
 */
const ZT_UPLOAD_OVERHEAD_BYTES = 8 * 1024 * 1024;

/**
 * Читает переменную окружения как строку.
 *
 * @param string $name Имя переменной.
 * @return string Значение или пустая строка.
 */
function zt_env( $name ) {
	$value = getenv( $name );

	return is_string( $value ) ? $value : '';
}

/* -------------------------------------------------------------------------
 * Обработка изображений
 * ---------------------------------------------------------------------- */

/**
 * Обрабатывать изображения только через GD.
 *
 * В образе есть и Imagick, и GD, и WordPress по умолчанию предпочитает
 * Imagick. GD расходует на пиксель меньше и предсказуемее: Imagick во многих
 * сборках хранит пиксель в 8 байтах, что на машине без запаса памяти
 * означает остановку процесса системой вместо ошибки обработки.
 *
 * @param string[] $editors Классы обработчиков.
 * @return string[] Только GD.
 */
function zt_force_gd_image_editor( $editors ) {
	unset( $editors );

	return array( 'WP_Image_Editor_GD' );
}
add_filter( 'wp_image_editors', 'zt_force_gd_image_editor' );

/**
 * Сократить набор автоматически создаваемых размеров.
 *
 * Каждый лишний размер — ещё один проход обработки на загрузку. Большие
 * дополнительные размеры WordPress (1536 и 2048 пикселей) в вёрстке не нужны:
 * крупные изображения отдаются из `large` и из масштабированного оригинала.
 *
 * Черновое значение. Окончательный набор определится вместе с вёрсткой темы —
 * см. группу задач 4 в openspec/changes/bootstrap-vps-wordpress/tasks.md.
 *
 * @param array $sizes Размеры для создания.
 * @return array Сокращённый набор.
 */
function zt_trim_image_sizes( $sizes ) {
	unset( $sizes['1536x1536'], $sizes['2048x2048'] );

	return $sizes;
}
add_filter( 'intermediate_image_sizes_advanced', 'zt_trim_image_sizes' );

/**
 * Оценить, хватит ли памяти на обработку изображения, и отклонить файл с
 * понятным сообщением, если не хватит.
 *
 * Без этой проверки нехватка памяти проявляется худшим образом: процесс PHP
 * останавливает система, редактор видит обрыв или пустую запись в
 * медиабиблиотеке, а не сообщение об ошибке.
 *
 * Оценка: GD держит распакованное изображение как четыре байта на пиксель,
 * и при изменении размера в памяти одновременно живут источник и результат.
 * Коэффициент 2.2 — источник плюс крупнейший результат плюс промежуточные
 * буферы; сверху фиксированный запас на сам WordPress.
 *
 * @param array $file Элемент $_FILES.
 * @return array Тот же элемент, при нехватке памяти — с ключом error.
 */
function zt_reject_oversized_image( $file ) {
	if ( ! empty( $file['error'] ) || empty( $file['tmp_name'] ) ) {
		return $file;
	}

	$info = @getimagesize( $file['tmp_name'] );
	if ( false === $info || empty( $info[0] ) || empty( $info[1] ) ) {
		return $file;
	}

	$limit = wp_convert_hr_to_bytes( ini_get( 'memory_limit' ) );
	if ( $limit <= 0 ) {
		// Предел не задан — оценивать нечего, пусть решает система.
		return $file;
	}

	$pixels   = (int) $info[0] * (int) $info[1];
	$estimate = (int) ( $pixels * 4 * 2.2 ) + 16 * 1024 * 1024;

	if ( $estimate <= $limit ) {
		return $file;
	}

	$file['error'] = sprintf(
		/* translators: 1: megapixels, 2: required memory, 3: available memory */
		__( 'Изображение слишком большое для обработки на этом сервере: %1$s Мпикс потребуют примерно %2$s памяти, доступно %3$s. Уменьшите разрешение файла или обратитесь к разработчику — на сервере нужно больше памяти.', 'zt-web' ),
		number_format_i18n( $pixels / 1000000, 1 ),
		size_format( $estimate ),
		size_format( $limit )
	);

	return $file;
}
add_filter( 'wp_handle_upload_prefilter', 'zt_reject_oversized_image' );

/* -------------------------------------------------------------------------
 * Предел размера загрузки
 * ---------------------------------------------------------------------- */

/**
 * Показать и применить предел размера файла, согласованный с Caddy и PHP.
 *
 * Третье из трёх мест, где живёт предел. Источник один — ZT_REQUEST_LIMIT;
 * здесь из него вычитается запас на накладные расходы запроса, поэтому
 * названный редактору предел — тот, который действительно проходит.
 *
 * @param int $limit Предел, вычисленный WordPress из настроек PHP.
 * @return int Согласованный предел в байтах.
 */
function zt_upload_size_limit( $limit ) {
	$request_limit = wp_convert_hr_to_bytes( zt_env( 'ZT_REQUEST_LIMIT' ) );
	if ( $request_limit <= ZT_UPLOAD_OVERHEAD_BYTES ) {
		return $limit;
	}

	return min( (int) $limit, $request_limit - ZT_UPLOAD_OVERHEAD_BYTES );
}
add_filter( 'upload_size_limit', 'zt_upload_size_limit' );

/* -------------------------------------------------------------------------
 * Индексация поисковыми системами
 * ---------------------------------------------------------------------- */

/**
 * Закрыть индексацию, пока сайт живёт на IP-адресе.
 *
 * Значение навязывается фильтром, а не выставляется в админке: настройка,
 * сделанная кликом, не воспроизводится при пересоздании сервера и может быть
 * снята случайно. Снимается вместе с переходом на домен — переменной
 * ZT_DISCOURAGE_INDEXING в `.env`.
 *
 * @return string '0' — просить поисковые системы не индексировать сайт.
 */
function zt_force_no_indexing() {
	return '0';
}
if ( '1' === zt_env( 'ZT_DISCOURAGE_INDEXING' ) ) {
	add_filter( 'pre_option_blog_public', 'zt_force_no_indexing' );
}

/* -------------------------------------------------------------------------
 * Права ролей
 * ---------------------------------------------------------------------- */

/**
 * Права, которых у редактора быть не должно.
 *
 * Роль `editor` в WordPress их и не даёт — список нужен, чтобы расхождение
 * исправлялось само, если права окажутся выданы плагином или вручную.
 *
 * @return string[] Список прав.
 */
function zt_editor_forbidden_caps() {
	return array(
		'activate_plugins',
		'delete_plugins',
		'delete_themes',
		'edit_files',
		'edit_plugins',
		'edit_theme_options',
		'edit_themes',
		'edit_users',
		'create_users',
		'delete_users',
		'list_users',
		'promote_users',
		'remove_users',
		'install_plugins',
		'install_themes',
		'switch_themes',
		'update_core',
		'update_plugins',
		'update_themes',
		'manage_options',
	);
}

/**
 * Права, которые редактору нужны для полного цикла заполнения обзора.
 *
 * Роль `editor` даёт их по умолчанию; список сторожит от случайного изъятия.
 *
 * @return string[] Список прав.
 */
function zt_editor_required_caps() {
	return array(
		'read',
		'upload_files',
		'edit_posts',
		'edit_others_posts',
		'edit_published_posts',
		'publish_posts',
		'delete_posts',
		'edit_pages',
		'publish_pages',
		'manage_categories',
		'moderate_comments',
	);
}

/**
 * Привести права роли редактора к заданным здесь.
 *
 * Выполняется один раз на версию набора: права хранятся в базе, а база живёт
 * в томе, поэтому переназначать их на каждый запрос незачем.
 */
function zt_enforce_roles() {
	if ( get_option( 'zt_roles_version' ) === ZT_ROLES_VERSION ) {
		return;
	}

	$role = get_role( 'editor' );
	if ( null === $role ) {
		return;
	}

	foreach ( zt_editor_forbidden_caps() as $cap ) {
		if ( $role->has_cap( $cap ) ) {
			$role->remove_cap( $cap );
		}
	}

	foreach ( zt_editor_required_caps() as $cap ) {
		if ( ! $role->has_cap( $cap ) ) {
			$role->add_cap( $cap );
		}
	}

	update_option( 'zt_roles_version', ZT_ROLES_VERSION, false );
}
add_action( 'init', 'zt_enforce_roles' );

/**
 * Убрать из админки пункты редактора файлов темы и плагинов.
 *
 * Сама правка уже запрещена константой DISALLOW_FILE_EDIT в wp-config.
 * Пункты меню убираем, чтобы не предлагать администратору путь, который
 * всё равно закрыт.
 */
function zt_remove_file_editor_menus() {
	remove_submenu_page( 'themes.php', 'theme-editor.php' );
	remove_submenu_page( 'plugins.php', 'plugin-editor.php' );
}
add_action( 'admin_menu', 'zt_remove_file_editor_menus', 100 );
