<?php
/**
 * Title: Мета-обзор
 * Slug: zt-web/meta-review
 * Categories: zt-web
 * Block Types: core/post-content
 * Post Types: post
 * Description: Каркас сравнительного теста нескольких камней с таблицей сравнения. Для камней разных типов абразива — рубрика «Мета-обзоры»; для камней одного типа — рубрика этого типа и метка «сравнительный тест».
 * Keywords: мета-обзор, сравнение, тест, таблица
 * Inserter: yes
 *
 * Вставляется копией.
 *
 * Таблица сравнения устроена столбцом на камень, а не строкой: сравнивают
 * взглядом по горизонтали, вдоль одного свойства. Столбцов в заготовке три —
 * лишние удаляются, недостающие добавляются.
 *
 * Состав строк повторяет заготовку характеристик одного камня. Это не
 * дублирование ради удобства: два разных набора строк развалили бы то самое
 * единообразие разметки, ради которого блок характеристик и существует.
 *
 * @package zt-web
 */

$zt_note_ref = function_exists( 'zt_method_note_ref' ) ? zt_method_note_ref() : 0;

?>
<!-- wp:paragraph -->
<p>Что сравнивается и почему именно эти камни оказались в одном тесте.</p>
<!-- /wp:paragraph -->

<?php if ( $zt_note_ref > 0 ) : ?>
<!-- wp:block {"ref":<?php echo (int) $zt_note_ref; ?>} /-->
<?php else : ?>
<!-- wp:paragraph {"fontSize":"small"} -->
<p class="has-small-font-size">Все камни тестируются по одной методике: <a href="/metodika-testirovaniya/">как проводятся тесты</a>.</p>
<!-- /wp:paragraph -->
<?php endif; ?>

<!-- wp:heading -->
<h2 class="wp-block-heading">Участники</h2>
<!-- /wp:heading -->

<!-- wp:table {"className":"is-style-zt-specs"} -->
<figure class="wp-block-table is-style-zt-specs"><table><thead>
<tr><th></th><th>Камень 1</th><th>Камень 2</th><th>Камень 3</th></tr>
</thead><tbody>
<tr><td>Зерно</td><td>1000 JIS</td><td>3000 JIS</td><td>не нормируется</td></tr>
<tr><td>Связка</td><td>керамическая</td><td>керамическая</td><td>природная</td></tr>
<tr><td>Размер</td><td>210 × 70 × 20 мм</td><td>210 × 70 × 20 мм</td><td>180 × 60 × 30 мм</td></tr>
<tr><td>Смачивание</td><td>вода</td><td>вода</td><td>масло</td></tr>
<tr><td>Цена</td><td>0 ₽ на 1 января 2026</td><td>0 ₽ на 1 января 2026</td><td>0 ₽ на 1 января 2026</td></tr>
</tbody></table></figure>
<!-- /wp:table -->

<!-- wp:heading -->
<h2 class="wp-block-heading">Поверхность после каждого</h2>
<!-- /wp:heading -->

<!-- wp:paragraph -->
<p>По тройке на камень, в одном порядке: сам камень и два снимка поверхности.</p>
<!-- /wp:paragraph -->

<!-- wp:pattern {"slug":"zt-web/triple"} /-->

<!-- wp:pattern {"slug":"zt-web/triple"} /-->

<!-- wp:pattern {"slug":"zt-web/triple"} /-->

<!-- wp:heading -->
<h2 class="wp-block-heading">Выводы</h2>
<!-- /wp:heading -->

<!-- wp:paragraph -->
<p>Кто из участников для чего годится и в каком порядке их имеет смысл ставить в набор.</p>
<!-- /wp:paragraph -->
