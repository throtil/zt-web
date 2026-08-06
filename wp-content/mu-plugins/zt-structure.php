<?php
/**
 * Plugin Name: zt-web structure
 * Description: Структура содержания, которая обязана воспроизводиться при пересоздании сервера: вид постоянных адресов, активная тема, дерево рубрик, метка сборных тестов.
 * Version: 1.0.0
 * Author: zt-web
 *
 * Отделено от zt-guardrails.php по предмету: там — ограничения (что кому
 * нельзя и сколько памяти можно), здесь — структура содержания (какие
 * разделы есть и как устроены адреса).
 *
 * Всё задано кодом, а не кликами в админке. Рубрика, созданная из админки,
 * исчезнет при пересоздании сервера, и исчезнет молча.
 *
 * @package zt-web
 */

defined( 'ABSPATH' ) || exit;

/**
 * Вид постоянного адреса статьи.
 *
 * Без рубрики в пути. Разбивка на рубрики объявлена предварительной, и адрес,
 * содержащий рубрику, делал бы каждую переорганизацию разделов ломающей все
 * ранее сохранённые ссылки.
 */
const ZT_PERMALINK_STRUCTURE = '/%postname%/';

/**
 * Сообщить о неудавшемся приведении структуры.
 *
 * В журнал, а не в вывод страницы: вывод сломал бы заголовки, а на подъёме с
 * нуля никто на страницу и не смотрит.
 *
 * Молчать здесь нельзя: неудача приведения даёт отказ ровно того сорта, от
 * которого спека и защищается, — деплой прошёл, в журнале чисто, рубрики или
 * меню на сайте нет.
 *
 * **Куда смотреть — зависит от машины**, и это выяснено опытом, а не выведено:
 *
 * - на сервере `WORDPRESS_DEBUG` не задан, `error_log` остаётся `/dev/stderr`,
 *   и строки видны в `docker compose logs wordpress`. Русский текст Apache в
 *   своём журнале экранирует побайтно (`\xd0\x9f…`); опознавательный знак
 *   `zt-structure` при этом остаётся читаемым, а сообщение целиком
 *   разворачивается через `printf '%b'`;
 * - локально `docker-compose.local.yml` задаёт `WORDPRESS_DEBUG=1`, образ из
 *   этого включает `WP_DEBUG_LOG`, и WordPress уводит `error_log` в
 *   `wp-content/debug.log` внутри контейнера — в `docker compose logs` при этом
 *   не видно ничего. Файл лежит в томе ядра, не в репозитории.
 *
 * Под wp-cli (`zt_wp eval`) сообщения идут на stderr и видны сразу.
 *
 * @param string $message Что не удалось.
 * @return void
 */
function zt_structure_warn( $message ) {
	// phpcs:ignore WordPress.PHP.DevelopmentFunctions.error_log_error_log
	error_log( 'zt-structure: ' . $message );
}

/**
 * Версия структуры содержания.
 *
 * Считается из самой структуры, а не задаётся числом вручную: изменил дерево
 * рубрик, метку или вид адресов — версия изменилась сама. Ручную версию
 * пришлось бы помнить, а забытая давала бы тихий отказ худшего сорта: деплой
 * прошёл, журнал чист, новой рубрики на сайте нет.
 *
 * Опорные записи под эту версию не попадают — у них отдельный одноразовый
 * признак, см. ZT_ANCHOR_OPTION. Иначе добавление рубрики воскрешало бы
 * страницу, которую редактор намеренно удалил.
 *
 * @return string Отпечаток структуры.
 */
function zt_structure_version() {
	return md5(
		(string) wp_json_encode(
			array(
				zt_category_tree(),
				ZT_COMPARISON_TAG_SLUG,
				ZT_PERMALINK_STRUCTURE,
			)
		)
	);
}

/* -------------------------------------------------------------------------
 * Постоянные адреса
 * ---------------------------------------------------------------------- */

/**
 * Навязать вид постоянного адреса значением из репозитория.
 *
 * Фильтром, а не записью в базу, по той же причине, по какой закрыта
 * индексация в zt-guardrails.php: значение в базе не воспроизводится при
 * пересоздании сервера и может быть изменено случайно. Здесь цена ошибки
 * выше обычного — смена вида адресов ломает все внешние ссылки разом.
 *
 * WP_Rewrite создаётся в wp-settings.php после загрузки mu-plugins, поэтому
 * фильтр успевает подействовать на разбор адресов с первого же запроса.
 *
 * @return string Вид адреса.
 */
function zt_permalink_structure() {
	return ZT_PERMALINK_STRUCTURE;
}
add_filter( 'pre_option_permalink_structure', 'zt_permalink_structure' );

/*
 * Правила разбора адресов WordPress хранит в базе и перестраивает только по
 * требованию. Без перестроения отфильтрованный вид адреса действовал бы на
 * вывод ссылок, но не на разбор входящих запросов: ссылки красивые, переход
 * по ним — 404. Перестроение вызывается один раз на версию структуры, ниже.
 *
 * Apache при этом обязан направлять все несуществующие пути на index.php.
 * В образе `AllowOverride None`, то есть .htaccess не читается вовсе, и это
 * сделано конфигурацией: config/apache/zt-permalinks.conf.
 */

/* -------------------------------------------------------------------------
 * Активная тема
 * ---------------------------------------------------------------------- */

/**
 * Слог темы сайта.
 *
 * Родительская тема здесь не названа сознательно: её имя объявлено в заголовке
 * `Template:` файла `style.css` дочерней темы, и второе место, где то же имя
 * написано, разошлось бы с первым при смене родителя.
 */
const ZT_THEME_SLUG = 'zt-web';

/**
 * Пара значений активной темы: дочерняя и родительская.
 *
 * @return array|false Пара `stylesheet`/`template` либо false, если навязывать нельзя.
 */
function zt_theme_pair() {
	static $pair = null;

	if ( null !== $pair ) {
		return $pair;
	}

	$themes = WP_CONTENT_DIR . '/themes/';

	/*
	 * Если каталога темы нет — не навязываем ничего. Без этой проверки
	 * несмонтированный каталог темы белил бы сайт наглухо: обычно ядро в такой
	 * ситуации само переключается на стандартную тему, но фильтр ниже отменил бы
	 * и это переключение, а сменить тему из админки нельзя — её значение тоже
	 * приходит из фильтра. То есть цена ошибки монтирования была бы «сайта нет и
	 * вернуть его из браузера невозможно».
	 */
	if ( ! is_readable( $themes . ZT_THEME_SLUG . '/style.css' ) ) {
		zt_structure_warn( 'каталог темы ' . ZT_THEME_SLUG . ' не читается: активная тема оставлена как в базе' );
		$pair = false;

		return $pair;
	}

	$data   = get_file_data( $themes . ZT_THEME_SLUG . '/style.css', array( 'template' => 'Template' ) );
	$parent = isset( $data['template'] ) ? trim( $data['template'] ) : '';

	// Дочерняя тема без родителя не работает: половина шаблонов и заготовок
	// приходит из родительской.
	if ( '' !== $parent && ! is_readable( $themes . $parent . '/style.css' ) ) {
		zt_structure_warn( 'родительская тема ' . $parent . ' не читается: активная тема оставлена как в базе' );
		$pair = false;

		return $pair;
	}

	$pair = array(
		'stylesheet' => ZT_THEME_SLUG,
		'template'   => '' === $parent ? ZT_THEME_SLUG : $parent,
	);

	return $pair;
}

/**
 * Навязать активную тему значением из репозитория.
 *
 * Фильтром, а не записью в базу, по той же причине, что и вид постоянных
 * адресов выше: значение в базе не воспроизводится при пересоздании сервера.
 * Здесь у этого есть ещё одна причина — деплой. Активная тема живёт в базе, а
 * деплой базу не трогает; на уже настроенном сервере `git pull` привёз бы
 * шаблоны, сетку и меню, а сайт остался бы стандартной темой. Деплой прошёл, в
 * журнале чисто, сайт прежний — отказ того же сорта, что и забытая перестройка
 * правил адресов.
 *
 * Следствие принято сознательно: сменить тему из админки нельзя. Тема — слой с
 * хозяином в репозитории, и переключатель в админке был бы вторым хозяином.
 *
 * Два значения, а не одно: `zt-web` — дочерняя тема, `stylesheet` указывает на
 * неё, `template` — на родительскую.
 *
 * @param mixed  $value  Значение до обращения к базе; false — обращаться.
 * @param string $option Имя настройки.
 * @return mixed Слог темы либо $value, если навязывать нельзя.
 */
function zt_theme_option( $value, $option ) {
	$pair = zt_theme_pair();

	if ( false === $pair ) {
		return $value;
	}

	return $pair[ $option ] ?? $value;
}
add_filter( 'pre_option_stylesheet', 'zt_theme_option', 10, 2 );
add_filter( 'pre_option_template', 'zt_theme_option', 10, 2 );

/* -------------------------------------------------------------------------
 * Дерево рубрик
 * ---------------------------------------------------------------------- */

/**
 * Дерево рубрик сайта.
 *
 * Порядок вложенности задаётся вложенностью массива. Слоги латиницей и
 * заданы явно: транслитерация русского названия средствами WordPress зависит
 * от локали, а слог входит в адрес страницы рубрики и в пункты меню темы.
 *
 * `Мета-обзоры` стоит рядом с типами абразива, а не над ними: это тесты, где
 * сравниваются камни разных типов. Сравнительный тест внутри одного типа
 * лежит в рубрике этого типа и помечается меткой, см. ZT_COMPARISON_TAG.
 *
 * @return array Дерево: слог => [name, children].
 */
function zt_category_tree() {
	return array(
		'obzory'   => array(
			'name'     => 'Обзоры и тесты',
			'children' => array(
				'abrazivy'    => array(
					'name'     => 'Абразивы',
					'children' => array(
						'sintetika'   => array( 'name' => 'Синтетика' ),
						'prirodnye'   => array( 'name' => 'Природные' ),
						'almaz'       => array( 'name' => 'Алмаз' ),
						'elbor'       => array( 'name' => 'Эльбор' ),
						'meta-obzory' => array( 'name' => 'Мета-обзоры' ),
					),
				),
				'stanki'      => array( 'name' => 'Станки' ),
				'raskhodniki' => array( 'name' => 'Расходники' ),
			),
		),
		'poleznoe' => array(
			'name' => 'Полезное',
		),
	);
}

/**
 * Метка сборных тестов.
 *
 * Заводится кодом, а не редактором, в отличие от остальных меток: на неё
 * опирается правило «сравнительный тест лежит в рубрике своего типа», и
 * список всех сборных тестов собирается именно по ней. Разъехавшееся
 * написание сломало бы этот список молча.
 */
const ZT_COMPARISON_TAG      = 'сравнительный тест';
const ZT_COMPARISON_TAG_SLUG = 'sravnitelnyj-test';

/**
 * Привести существующую рубрику к дереву: имя и вложенность.
 *
 * Спека требует, чтобы изменение дерева в репозитории применялось самим
 * деплоем. Одного создания недостающих рубрик для этого мало: разбивка
 * объявлена предварительной, то есть перекладывание рубрики в другого родителя
 * и уточнение названия — ожидаемые правки, а не редкость. Без этой функции они
 * молча не применялись бы, хотя отпечаток дерева менялся.
 *
 * Слог не меняется никогда: он опознавательный признак рубрики для этого файла
 * и её адрес на сайте. Правка слога в дереве означает новую рубрику, а старая
 * остаётся на месте — как и рубрика, из дерева убранная: в ней могут лежать
 * статьи, и удалять её кодом было бы хуже, чем оставить.
 *
 * Описание передаётся текущим значением, а не опускается: `wp_update_term`
 * записывает описание всегда, а по умолчанию оно пустое, поэтому правка имени
 * без этого стёрла бы описание, написанное редактором.
 *
 * @param WP_Term $term   Существующая рубрика.
 * @param string  $name   Имя из дерева.
 * @param int     $parent Родитель из дерева.
 * @return bool Удалось ли привести.
 */
function zt_align_category( $term, $name, $parent ) {
	if ( $term->name === $name && (int) $term->parent === (int) $parent ) {
		return true;
	}

	$updated = wp_update_term(
		(int) $term->term_id,
		'category',
		array(
			'name'        => $name,
			'parent'      => (int) $parent,
			'slug'        => $term->slug,
			'description' => $term->description,
		)
	);

	if ( is_wp_error( $updated ) ) {
		zt_structure_warn(
			sprintf(
				'рубрика «%s» не приведена к дереву: %s',
				$term->slug,
				$updated->get_error_message()
			)
		);

		return false;
	}

	return true;
}

/**
 * Создать недостающие рубрики дерева и привести существующие, сохранив
 * вложенность.
 *
 * @param array $tree   Уровень дерева.
 * @param int   $parent Идентификатор родительской рубрики.
 * @return bool Удалось ли привести весь уровень и всё, что под ним.
 */
function zt_ensure_categories( $tree, $parent = 0 ) {
	$ok = true;

	foreach ( $tree as $slug => $node ) {
		$term = get_term_by( 'slug', $slug, 'category' );

		if ( false === $term ) {
			$created = wp_insert_term(
				$node['name'],
				'category',
				array(
					'slug'   => $slug,
					'parent' => $parent,
				)
			);

			if ( is_wp_error( $created ) ) {
				zt_structure_warn(
					sprintf(
						'рубрика «%s» (%s) не создана: %s',
						$node['name'],
						$slug,
						$created->get_error_message()
					)
				);

				// Вложенные — тоже мимо: созданные без родителя, они всплыли бы
				// на верхний уровень, и это пришлось бы разбирать руками.
				$ok = false;
				continue;
			}

			$term_id = (int) $created['term_id'];
		} else {
			$term_id = (int) $term->term_id;

			if ( ! zt_align_category( $term, $node['name'], $parent ) ) {
				$ok = false;
			}
		}

		if ( ! empty( $node['children'] ) && ! zt_ensure_categories( $node['children'], $term_id ) ) {
			$ok = false;
		}
	}

	return $ok;
}

/* -------------------------------------------------------------------------
 * Опорное содержимое
 * ---------------------------------------------------------------------- */

/*
 * Четыре записи ниже — не статьи, а часть устройства сайта: на страницу «О
 * проекте» ведёт пункт меню, на описание методики ссылается врезка из каждого
 * обзора, сама врезка — общая заготовка, то есть запись в базе, и меню — тоже
 * запись в базе, потому что хозяин ему редактор.
 *
 * Поэтому они заводятся кодом, а не руками: без них сайт, поднятый из одного
 * репозитория, встречает читателя пустой шапкой и ссылками в никуда. Заводятся
 * один раз, с заготовкой текста: дальше это содержание, и хозяин ему редактор.
 * Если он их удалит или перепишет, повторный запуск ничего не вернёт и не
 * перепишет — признак засева к тому времени уже сохранён.
 */

const ZT_ANCHOR_OPTION    = 'zt_anchor_seeded';
const ZT_METHOD_PAGE_SLUG = 'metodika-testirovaniya';
const ZT_METHOD_NOTE_SLUG = 'vrezka-o-metodike';
const ZT_ABOUT_PAGE_SLUG  = 'o-proekte';
const ZT_NAV_SLUG         = 'osnovnoe-menyu';

/**
 * Разметка врезки о методике.
 *
 * Ссылка записана адресом, а не идентификатором записи: идентификаторы выдаёт
 * база, и на пересозданном сервере они другие, а слог задан здесь же.
 *
 * @return string Разметка блоков.
 */
function zt_method_note_content() {
	$url = '/' . ZT_METHOD_PAGE_SLUG . '/';

	return '<!-- wp:group {"className":"is-style-zt-method-note","layout":{"type":"constrained"}} -->'
		. '<div class="wp-block-group is-style-zt-method-note">'
		. '<!-- wp:paragraph {"fontSize":"small"} -->'
		. '<p class="has-small-font-size">Все камни тестируются по одной методике: '
		. '<a href="' . esc_url( $url ) . '">как проводятся тесты</a>. '
		. 'Снимки поверхности сделаны при одинаковом увеличении.</p>'
		. '<!-- /wp:paragraph -->'
		. '</div>'
		. '<!-- /wp:group -->';
}

/**
 * Идентификатор общей заготовки с врезкой о методике.
 *
 * Нужен заготовкам разметки: вставить общую заготовку можно только ссылкой на
 * её запись. Заготовка обзора вызывает эту функцию при регистрации, поэтому
 * идентификатор в файлах темы не записан и на другом сервере не разъедется.
 *
 * @return int Идентификатор записи или 0, если её нет.
 */
function zt_method_note_ref() {
	$found = get_posts(
		array(
			'name'             => ZT_METHOD_NOTE_SLUG,
			'post_type'        => 'wp_block',
			'post_status'      => 'publish',
			'numberposts'      => 1,
			'suppress_filters' => false,
		)
	);

	return empty( $found ) ? 0 : (int) $found[0]->ID;
}

/**
 * Разметка пунктов меню по уровню дерева рубрик.
 *
 * Меню строится из того же дерева, что и рубрики, а не переписывается вторым
 * списком в файле темы: два списка разошлись бы при первой же добавленной
 * рубрике, и разошлись бы молча.
 *
 * Адреса берутся у самих рубрик и приводятся к относительным. Абсолютный
 * адрес заморозил бы в базе имя узла, а числовой идентификатор рубрики —
 * значение, которое на пересозданном сервере другое.
 *
 * @param array $tree Уровень дерева.
 * @param bool  $top  Верхний ли это уровень.
 * @return string Разметка блоков.
 */
function zt_navigation_items( $tree, $top = true ) {
	$markup = '';

	foreach ( $tree as $slug => $node ) {
		$term = get_term_by( 'slug', $slug, 'category' );

		if ( false === $term ) {
			continue;
		}

		$attrs = array(
			'label' => $node['name'],
			'url'   => wp_make_link_relative( get_category_link( $term->term_id ) ),
			'kind'  => 'custom',
		);

		if ( empty( $node['children'] ) ) {
			$markup .= '<!-- wp:navigation-link ' . wp_json_encode( $attrs, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES ) . ' /-->';
			continue;
		}

		if ( $top ) {
			$attrs['isTopLevelItem'] = true;
		}

		$markup .= '<!-- wp:navigation-submenu ' . wp_json_encode( $attrs, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES ) . ' -->'
			. zt_navigation_items( $node['children'], false )
			. '<!-- /wp:navigation-submenu -->';
	}

	return $markup;
}

/**
 * Разметка основного меню.
 *
 * Порядок пунктов задан спекой: `Главная`, `Обзоры и тесты` с раскрытием
 * вложенных рубрик, `Полезное`, `О проекте`. Первый и последний пункты в
 * дереве рубрик отсутствуют и дописываются здесь.
 *
 * @return string Разметка блоков.
 */
function zt_navigation_content() {
	return '<!-- wp:home-link {"label":"Главная"} /-->'
		. zt_navigation_items( zt_category_tree() )
		. '<!-- wp:navigation-link {"label":"О проекте","url":"/' . ZT_ABOUT_PAGE_SLUG . '/","kind":"custom"} /-->';
}

/**
 * Идентификатор записи с меню.
 *
 * @return int Идентификатор или 0, если записи нет.
 */
function zt_navigation_ref_id() {
	static $ref = null;

	if ( null !== $ref ) {
		return $ref;
	}

	$found = get_posts(
		array(
			'name'             => ZT_NAV_SLUG,
			'post_type'        => 'wp_navigation',
			'post_status'      => 'publish',
			'numberposts'      => 1,
			'suppress_filters' => false,
		)
	);

	$ref = empty( $found ) ? 0 : (int) $found[0]->ID;

	return $ref;
}

/**
 * Подставить блоку меню ссылку на нашу запись.
 *
 * В файле части шаблона ссылки нет и быть не может: её значение — числовой
 * идентификатор, который выдаёт база, а на пересозданном сервере он другой.
 * Поэтому в `parts/header.html` стоит блок меню без ссылки, а ссылка
 * находится здесь по слогу.
 *
 * Без этого ядро повело бы себя само: не найдя ссылки, оно берёт последнее
 * опубликованное меню, а не найдя ни одного — заводит своё из списка страниц.
 * То есть отсутствие подстановки давало бы не пустую шапку, а чужое меню.
 *
 * @param array $block Разобранный блок.
 * @return array Блок, при необходимости — со ссылкой.
 */
function zt_navigation_ref( $block ) {
	if ( 'core/navigation' !== ( $block['blockName'] ?? '' ) || ! empty( $block['attrs']['ref'] ) ) {
		return $block;
	}

	$ref = zt_navigation_ref_id();

	if ( $ref > 0 ) {
		$block['attrs']['ref'] = $ref;
	}

	return $block;
}
add_filter( 'render_block_data', 'zt_navigation_ref' );

/**
 * Убедиться, что у существующей опорной записи есть нужная рубрика.
 *
 * Чужой выбор не переписывается: если у записи стоит рубрика, отличная от
 * рубрики по умолчанию, значит её поставили осознанно — редактор перенёс статью,
 * и возвращать её обратно кодом нельзя. Дозначение делается только когда рубрики
 * нет вовсе или стоит одна `uncategorized`, то есть когда след виден именно от
 * недоделанного засева.
 *
 * @param int    $post_id Идентификатор записи.
 * @param int    $term_id Нужная рубрика.
 * @param string $slug    Слог записи — для сообщения в журнал.
 * @return bool Лежит ли запись в рубрике после вызова.
 */
function zt_ensure_post_term( $post_id, $term_id, $slug ) {
	$current = array_map( "intval", wp_get_post_categories( $post_id ) );

	if ( in_array( (int) $term_id, $current, true ) ) {
		return true;
	}

	$chosen = array_diff( $current, array( (int) get_option( 'default_category' ) ) );

	if ( ! empty( $chosen ) ) {
		return true;
	}

	$assigned = wp_set_post_terms( $post_id, array( (int) $term_id ), 'category' );

	if ( is_wp_error( $assigned ) || false === $assigned ) {
		zt_structure_warn(
			sprintf(
				'опорной записи «%s» так и не назначена рубрика %d: %s',
				$slug,
				$term_id,
				is_wp_error( $assigned ) ? $assigned->get_error_message() : 'wp_set_post_terms вернул false'
			)
		);

		return false;
	}

	// Сообщение и при успехе: значит предыдущая попытка засева прошла наполовину,
	// и об этом стоит знать, даже когда починилось само.
	zt_structure_warn( sprintf( 'опорной записи «%s» дозначена рубрика %d при повторной попытке', $slug, $term_id ) );

	return true;
}

/**
 * Создать запись, если записи с таким слогом ещё нет.
 *
 * @param string $slug    Слог.
 * @param string $type    Тип записи.
 * @param string $title   Заголовок.
 * @param string $content Разметка блоков.
 * @param int    $term_id Рубрика для статьи, 0 — не назначать.
 * @return bool Есть ли запись после вызова.
 */
function zt_ensure_post( $slug, $type, $title, $content, $term_id = 0 ) {
	$found = get_posts(
		array(
			'name'             => $slug,
			'post_type'        => $type,
			'post_status'      => 'any',
			'numberposts'      => 1,
			'suppress_filters' => false,
		)
	);

	if ( ! empty( $found ) ) {
		// Запись есть — но этого мало, если ей нужна рубрика: создание могло
		// пройти, а назначение рубрики отказать. Тогда «запись есть» было бы
		// неправдой: статья о методике осталась бы вне «Полезного», а признак
		// засева записался бы как успех, и второй попытки уже не было бы.
		return $term_id > 0 ? zt_ensure_post_term( (int) $found[0]->ID, $term_id, $slug ) : true;
	}

	// Второй аргумент — чтобы получить причину отказа: без него wp_insert_post
	// возвращает 0, и дальше нечего ни записать в журнал, ни проверить. Ноль при
	// этом проходил бы проверку is_wp_error, и рубрика назначалась бы записи с
	// идентификатором 0.
	$post_id = wp_insert_post(
		array(
			'post_name'    => $slug,
			'post_type'    => $type,
			'post_title'   => $title,
			'post_content' => $content,
			'post_status'  => 'publish',
		),
		true
	);

	if ( is_wp_error( $post_id ) || $post_id <= 0 ) {
		zt_structure_warn(
			sprintf(
				'опорная запись «%s» (%s, %s) не создана: %s',
				$title,
				$slug,
				$type,
				is_wp_error( $post_id ) ? $post_id->get_error_message() : 'wp_insert_post вернул ' . (int) $post_id
			)
		);

		return false;
	}

	if ( $term_id > 0 ) {
		$assigned = wp_set_post_terms( $post_id, array( $term_id ), 'category' );

		if ( is_wp_error( $assigned ) || false === $assigned ) {
			zt_structure_warn(
				sprintf(
					'опорной записи «%s» не назначена рубрика %d: %s',
					$slug,
					$term_id,
					is_wp_error( $assigned ) ? $assigned->get_error_message() : 'wp_set_post_terms вернул false'
				)
			);

			return false;
		}
	}

	return true;
}

/**
 * Завести опорные записи: страницу о проекте, описание методики и врезку.
 *
 * Каждая заводится независимо от судьбы остальных — отказ на одной не отменяет
 * остальных трёх, — но признак засева ставится только при полном успехе, см.
 * zt_enforce_structure.
 *
 * @return bool Все ли опорные записи на месте.
 */
function zt_ensure_anchor_content() {
	$ok = zt_ensure_post(
		ZT_ABOUT_PAGE_SLUG,
		'page',
		'О проекте',
		'<!-- wp:paragraph --><p>Личный некоммерческий сайт с обзорами и тестами заточных камней, '
		. 'станков и расходников. Текст этой страницы — заготовка, её предстоит написать.</p><!-- /wp:paragraph -->'
	);

	$poleznoe = get_term_by( 'slug', 'poleznoe', 'category' );

	if ( ! $poleznoe ) {
		zt_structure_warn( 'рубрики poleznoe нет — описание методики завелось бы вне разделов' );
		$ok = false;
	} else {
		$ok = zt_ensure_post(
			ZT_METHOD_PAGE_SLUG,
			'post',
			'Как проводятся тесты',
			'<!-- wp:paragraph --><p>Описание методики тестирования. Текст — заготовка, '
			. 'её предстоит написать. На эту страницу ссылается врезка в каждом обзоре, '
			. 'поэтому методика описывается здесь один раз, а не пересказывается в обзорах.</p><!-- /wp:paragraph -->',
			(int) $poleznoe->term_id
		) && $ok;
	}

	$ok = zt_ensure_post(
		ZT_METHOD_NOTE_SLUG,
		'wp_block',
		'Врезка о методике',
		zt_method_note_content()
	) && $ok;

	return zt_ensure_post(
		ZT_NAV_SLUG,
		'wp_navigation',
		'Основное меню',
		zt_navigation_content()
	) && $ok;
}

/**
 * Завести метку сборных тестов, если её ещё нет.
 *
 * @return bool Есть ли метка после вызова.
 */
function zt_ensure_comparison_tag() {
	if ( term_exists( ZT_COMPARISON_TAG_SLUG, 'post_tag' ) ) {
		return true;
	}

	$created = wp_insert_term( ZT_COMPARISON_TAG, 'post_tag', array( 'slug' => ZT_COMPARISON_TAG_SLUG ) );

	if ( is_wp_error( $created ) ) {
		zt_structure_warn(
			sprintf( 'метка «%s» не создана: %s', ZT_COMPARISON_TAG, $created->get_error_message() )
		);

		return false;
	}

	return true;
}

/**
 * Привести структуру содержания к заданной здесь.
 *
 * Выполняется один раз на версию: дерево рубрик и правила разбора адресов
 * живут в базе, а база живёт в томе. Пересоздание сервера начинается с пустой
 * базы, версии в ней нет — структура создаётся заново.
 *
 * Два признака, а не один: структура пересчитывается при каждом её изменении,
 * опорные записи заводятся один раз за жизнь базы. Общий признак означал бы,
 * что добавление рубрики воскрешает страницу, которую редактор удалил, и
 * возвращает исходный вид меню, которое он переставил.
 *
 * Признак ставится только после успеха того, что им отмечено. Иначе неудача
 * записывалась бы как выполнение: сайт остался бы без рубрики, врезки или меню,
 * а повторной попытки не было бы — тот самый тихий отказ, от которого спека и
 * защищается. Каждый признак отвечает за своё: отказ опорных записей не мешает
 * записать версию структуры, и наоборот.
 *
 * @return void
 */
function zt_enforce_structure() {
	/*
	 * До установки WordPress таблиц ещё нет, а `init` уже происходит: mu-plugins
	 * загружаются на каждом запросе, в том числе на том, которым WordPress себя
	 * и устанавливает. Без этой проверки установка сопровождается четырьмя
	 * десятками сообщений «Table wp_terms doesn't exist» — установка при этом
	 * проходит, но в журнале остаётся картина сломанного сервера, и настоящая
	 * ошибка в ней потеряется. Найдено подъёмом с нуля 6 августа 2026.
	 */
	if ( wp_installing() || ! is_blog_installed() ) {
		return;
	}

	$version  = zt_structure_version();
	$changed  = ( get_option( 'zt_structure_version' ) !== $version );
	$unseeded = ! get_option( ZT_ANCHOR_OPTION );

	if ( ! $changed && ! $unseeded ) {
		return;
	}

	/*
	 * Неудача повторяется не чаще раза в минуту. Неустранимая причина — скажем,
	 * рубрика с таким же именем, созданная руками, — иначе повторялась бы на
	 * каждом запросе к сайту, отнимая запросы к базе и заполняя журнал одной и
	 * той же строкой. Минута выбрана так, чтобы деплой не приходилось ждать.
	 */
	if ( get_transient( 'zt_structure_retry_after' ) ) {
		return;
	}

	// Первыми — рубрики: на них опираются и опорные записи (методика лежит в
	// «Полезном»), и пункты меню, которые строятся по этому же дереву.
	if ( ! zt_ensure_categories( zt_category_tree() ) ) {
		/*
		 * Дальше не идём вовсе, хотя часть дерева могла создаться. Причина в том,
		 * что опорные записи заводятся один раз за жизнь базы: меню, собранное по
		 * неполному дереву, осталось бы неполным навсегда, и починить его можно
		 * было бы только руками в админке. Отсутствие меню заметно и исправляется
		 * следующим удачным запуском, тихо неполное меню — нет.
		 */
		zt_structure_warn( 'дерево рубрик приведено не полностью: опорные записи и версия структуры не записаны, попытка повторится' );
		set_transient( 'zt_structure_retry_after', 1, MINUTE_IN_SECONDS );

		return;
	}

	$retry = false;

	if ( $unseeded ) {
		if ( zt_ensure_anchor_content() ) {
			update_option( ZT_ANCHOR_OPTION, '1', false );
		} else {
			zt_structure_warn( 'опорные записи созданы не полностью: признак засева не записан, попытка повторится' );
			$retry = true;
		}
	}

	if ( $changed ) {
		// Мягкое перестроение: правила пересчитываются и кладутся в базу,
		// .htaccess не трогается — он всё равно не читается, см. выше.
		flush_rewrite_rules( false );

		if ( zt_ensure_comparison_tag() ) {
			update_option( 'zt_structure_version', $version, false );
		} else {
			zt_structure_warn( 'версия структуры не записана: попытка повторится' );
			$retry = true;
		}
	}

	if ( $retry ) {
		set_transient( 'zt_structure_retry_after', 1, MINUTE_IN_SECONDS );
	}
}
add_action( 'init', 'zt_enforce_structure', 20 );
