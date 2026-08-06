<?php
/**
 * Title: Обзор камня
 * Slug: zt-web/stone-review
 * Categories: zt-web
 * Block Types: core/post-content
 * Post Types: post
 * Description: Каркас обзора одного камня: вступление, врезка о методике, характеристики, тройки фотографий, заключение.
 * Keywords: обзор, камень, каркас
 * Inserter: yes
 *
 * Вставляется копией: структуру отдельного обзора редактор меняет свободно,
 * и это не должно затрагивать остальные.
 *
 * Врезка о методике внутри — наоборот, общая: она вставлена ссылкой на
 * запись, а не текстом. Изменение методики правится в одном месте и видно во
 * всех обзорах сразу; вставленная копией, она потребовала бы через год
 * правки десятков опубликованных статей.
 *
 * @package zt-web
 */

$zt_note_ref = function_exists( 'zt_method_note_ref' ) ? zt_method_note_ref() : 0;

?>
<!-- wp:paragraph -->
<p>Вступление: что за камень, откуда взялся, зачем его тестировали.</p>
<!-- /wp:paragraph -->

<?php if ( $zt_note_ref > 0 ) : ?>
<!-- wp:block {"ref":<?php echo (int) $zt_note_ref; ?>} /-->
<?php else : ?>
<?php // Общей заготовки нет — сайт поднят из репозитория и ещё не наполнен.
	// Врезка вставляется текстом, чтобы каркас не разъехался; при следующей
	// вставке заготовки она подтянется ссылкой.
?>
<!-- wp:paragraph {"fontSize":"small"} -->
<p class="has-small-font-size">Все камни тестируются по одной методике: <a href="/metodika-testirovaniya/">как проводятся тесты</a>.</p>
<!-- /wp:paragraph -->
<?php endif; ?>

<!-- wp:heading -->
<h2 class="wp-block-heading">Характеристики</h2>
<!-- /wp:heading -->

<!-- wp:pattern {"slug":"zt-web/specs-stone"} /-->

<!-- wp:heading -->
<h2 class="wp-block-heading">Поверхность</h2>
<!-- /wp:heading -->

<!-- wp:paragraph -->
<p>Что видно на снимках: характер поверхности, следы обработки, изменения по ходу работы.</p>
<!-- /wp:paragraph -->

<!-- wp:pattern {"slug":"zt-web/triple"} /-->

<!-- wp:heading -->
<h2 class="wp-block-heading">В работе</h2>
<!-- /wp:heading -->

<!-- wp:paragraph -->
<p>Как камень ведёт себя при заточке: скорость съёма, засаливание, требования к правке.</p>
<!-- /wp:paragraph -->

<!-- wp:pattern {"slug":"zt-web/triple"} /-->

<!-- wp:heading -->
<h2 class="wp-block-heading">Заключение</h2>
<!-- /wp:heading -->

<!-- wp:paragraph -->
<p>Кому и для чего этот камень подходит, а кому не стоит.</p>
<!-- /wp:paragraph -->
