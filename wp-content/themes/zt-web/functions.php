<?php
/**
 * Подключение оформления темы и регистрация стилей блоков.
 *
 * Заготовки разметки регистрировать не требуется: у блочных тем WordPress сам
 * читает каталог `patterns/`.
 *
 * @package zt-web
 */

defined( 'ABSPATH' ) || exit;

/**
 * Подключить style.css темы на сайте и в редакторе.
 *
 * У блочных тем WordPress не подключает style.css сам — родительская
 * Twenty Twenty-Five, например, обходится одним theme.json и своего style.css
 * на страницах не отдаёт. Нашему файлу подключение нужно: в нём правила сетки
 * фотографий, без которых тройка складывается на телефоне.
 *
 * Второй вызов — для полотна редактора: без него редактор показывает сетку не
 * так, как её увидит читатель, и расхождение обнаруживается уже на сайте.
 *
 * @return void
 */
function zt_enqueue_theme_style() {
	$theme = wp_get_theme();

	wp_enqueue_style(
		'zt-web-style',
		get_stylesheet_uri(),
		array(),
		$theme->get( 'Version' )
	);
}
add_action( 'wp_enqueue_scripts', 'zt_enqueue_theme_style' );
add_action( 'after_setup_theme', 'zt_add_editor_style' );

/**
 * Показать те же правила в редакторе блоков.
 *
 * @return void
 */
function zt_add_editor_style() {
	add_editor_style( 'style.css' );
}

/**
 * Зарегистрировать стили блоков, на которые опираются заготовки.
 *
 * Стиль блока, а не класс, вписанный в заготовку: класс исчезнет, если
 * редактор удалит и вставит блок заново, а стиль остаётся в списке и
 * выбирается мышью. Оформление всех трёх — в style.css.
 *
 * @return void
 */
function zt_register_block_styles() {
	register_block_style(
		'core/gallery',
		array(
			'name'  => 'zt-triple',
			'label' => __( 'Тройка фотографий', 'zt-web' ),
		)
	);

	register_block_style(
		'core/table',
		array(
			'name'  => 'zt-specs',
			'label' => __( 'Характеристики', 'zt-web' ),
		)
	);

	register_block_style(
		'core/group',
		array(
			'name'  => 'zt-method-note',
			'label' => __( 'Врезка о методике', 'zt-web' ),
		)
	);
}
add_action( 'init', 'zt_register_block_styles' );

/**
 * Завести раздел для своих заготовок разметки.
 *
 * Без него заготовки рассыпаются по разделам ядра, и редактору, ищущему
 * каркас обзора, приходится опознавать его среди чужих.
 *
 * @return void
 */
function zt_register_pattern_category() {
	register_block_pattern_category(
		'zt-web',
		array( 'label' => __( 'Обзоры и тесты', 'zt-web' ) )
	);
}
add_action( 'init', 'zt_register_pattern_category' );

/* -------------------------------------------------------------------------
 * Отметка текущего раздела в меню
 * ---------------------------------------------------------------------- */

/**
 * Пути, считающиеся текущими для меню, и вид отметки для каждого.
 *
 * Два вида, потому что совпадения бывают двух родов:
 *
 * - `page` — открыта сама страница пункта: список рубрики, главная, «О проекте»;
 * - `section` — открыта статья из этого раздела. **Адрес статьи рубрику не
 *   содержит** (решение итерации: разбивка предварительная, и рубрика в адресе
 *   делала бы переорганизацию ломающей ссылки), поэтому на странице обзора ни
 *   один пункт меню не совпадает с путём запроса. Без этой части меню выглядело
 *   бы одинаково на всех статьях — а статья и есть основная страница сайта.
 *   Спека `site-navigation` требует различимости текущего раздела на любой
 *   странице.
 *
 * @return array Путь => `page`|`section`.
 */
function zt_current_menu_paths() {
	static $paths = null;

	if ( null !== $paths ) {
		return $paths;
	}

	$request = isset( $_SERVER['REQUEST_URI'] ) ? sanitize_text_field( wp_unslash( $_SERVER['REQUEST_URI'] ) ) : '/';
	$paths   = array( zt_normalize_menu_path( (string) wp_parse_url( $request, PHP_URL_PATH ) ) => 'page' );

	if ( ! is_singular( 'post' ) ) {
		return $paths;
	}

	// Рубрика статьи — по правилу проекта одна, но помечаются все назначенные:
	// правило это правило, а не механизм, и вторая рубрика не должна лишать
	// меню отметки. Родительские пункты помечает ядро, см. ниже.
	foreach ( get_the_category( get_queried_object_id() ) as $term ) {
		$path = zt_normalize_menu_path( (string) wp_parse_url( get_category_link( $term->term_id ), PHP_URL_PATH ) );

		if ( ! isset( $paths[ $path ] ) ) {
			$paths[ $path ] = 'section';
		}
	}

	return $paths;
}

/**
 * Привести путь к сравнимому виду: без кодирования, с завершающей чертой.
 *
 * Кириллические слоги в адресе приходят закодированными, а в разметке меню
 * записаны буквами — без раскодирования пункт «Полезное» никогда не совпал бы
 * сам с собой.
 *
 * @param string $path Путь.
 * @return string Приведённый путь.
 */
function zt_normalize_menu_path( $path ) {
	$path = rawurldecode( $path );
	$path = '/' . ltrim( $path, '/' );

	return user_trailingslashit( untrailingslashit( $path ) );
}

/**
 * Отметить пункт меню, ведущий на текущую страницу.
 *
 * Зачем это здесь. Ядро считает пункт текущим, сверяя записанный в нём
 * числовой идентификатор рубрики или страницы с идентификатором открытого
 * объекта. Идентификаторы выдаёт база, и на пересозданном сервере они другие,
 * поэтому в разметке меню их нет: пункты записаны обычными адресами. Плата за
 * воспроизводимость — ядро перестаёт узнавать текущий раздел, и меню
 * выглядит одинаково на всех страницах. Сверка по адресу возвращает отметку,
 * ничего не привязывая к базе.
 *
 * Родительский пункт помечать не нужно: ядро само добавляет
 * `current-menu-ancestor`, найдя отметку во вложенных пунктах, а они к этому
 * времени уже отрисованы вместе с нашим фильтром.
 *
 * @param string $content Разметка пункта.
 * @param array  $block   Разобранный блок.
 * @return string Разметка, при совпадении — с отметкой.
 */
function zt_mark_current_menu_item( $content, $block ) {
	if ( empty( $block['attrs']['url'] ) || ! empty( $block['attrs']['id'] ) ) {
		// С идентификатором ядро справляется само.
		return $content;
	}

	$link_path = zt_normalize_menu_path( (string) wp_parse_url( $block['attrs']['url'], PHP_URL_PATH ) );
	$paths     = zt_current_menu_paths();

	if ( ! isset( $paths[ $link_path ] ) ) {
		return $content;
	}

	$processor = new WP_HTML_Tag_Processor( $content );

	if ( $processor->next_tag( 'li' ) ) {
		/*
		 * Класс один и тот же для обоих видов совпадения, и это не небрежность:
		 * ядро ищет в отрисованных вложенных пунктах строку `current-menu-item`
		 * (`blocks/navigation-submenu.php`) и только по ней помечает
		 * родительские пункты `current-menu-ancestor`. Отметь мы раздел статьи
		 * другим классом — отметка осталась бы внутри свёрнутого подменю, то
		 * есть невидимой, а различимость раздела и есть цель.
		 */
		$processor->add_class( 'current-menu-item' );
	}

	if ( $processor->next_tag( 'a' ) ) {
		// Различие видов — здесь: `page` значит «это и есть открытая страница»,
		// и говорить так про раздел, в котором она лежит, было бы неправдой.
		$processor->set_attribute( 'aria-current', 'page' === $paths[ $link_path ] ? 'page' : 'true' );
	}

	return $processor->get_updated_html();
}
add_filter( 'render_block_core/navigation-link', 'zt_mark_current_menu_item', 10, 2 );
add_filter( 'render_block_core/navigation-submenu', 'zt_mark_current_menu_item', 10, 2 );
