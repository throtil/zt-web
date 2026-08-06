<?php
/**
 * Title: Обзор станка
 * Slug: zt-web/machine-review
 * Categories: zt-web
 * Block Types: core/post-content
 * Post Types: post
 * Description: Каркас обзора точильного станка: характеристики станка вместо характеристик камня.
 * Keywords: обзор, станок, каркас
 * Inserter: yes
 *
 * Вставляется копией.
 *
 * Отдельная заготовка, а не «обзор камня с другой таблицей»: у станка нет
 * зерна и связки, а есть привод, углы и оснастка. Подставить одно в другое
 * означало бы или оставлять половину строк пустыми, или заполнять их не тем,
 * что подписано, — и то и другое разрушает единообразие разметки.
 *
 * Состав строк — такой же зонд, как и у камня, и так же подлежит пересмотру
 * по итогам заполнения.
 *
 * @package zt-web
 */

$zt_note_ref = function_exists( 'zt_method_note_ref' ) ? zt_method_note_ref() : 0;

?>
<!-- wp:paragraph -->
<p>Вступление: что за станок, для каких задач куплен.</p>
<!-- /wp:paragraph -->

<?php if ( $zt_note_ref > 0 ) : ?>
<!-- wp:block {"ref":<?php echo (int) $zt_note_ref; ?>} /-->
<?php else : ?>
<!-- wp:paragraph {"fontSize":"small"} -->
<p class="has-small-font-size">Тесты проводятся по одной методике: <a href="/metodika-testirovaniya/">как проводятся тесты</a>.</p>
<!-- /wp:paragraph -->
<?php endif; ?>

<!-- wp:heading -->
<h2 class="wp-block-heading">Характеристики</h2>
<!-- /wp:heading -->

<!-- wp:table {"className":"is-style-zt-specs"} -->
<figure class="wp-block-table is-style-zt-specs"><table><tbody>
<tr><td>Тип</td><td>настольный, с водяным охлаждением</td></tr>
<tr><td>Привод</td><td>электрический, 120 Вт</td></tr>
<tr><td>Скорость</td><td>120 об/мин</td></tr>
<tr><td>Диапазон углов</td><td>от 10 до 30 градусов</td></tr>
<tr><td>Оснастка в комплекте</td><td>не указано</td></tr>
<tr><td>Габариты и вес</td><td>не указано</td></tr>
<tr><td>Цена</td><td>0 ₽ на 1 января 2026</td></tr>
</tbody></table></figure>
<!-- /wp:table -->

<!-- wp:heading -->
<h2 class="wp-block-heading">В работе</h2>
<!-- /wp:heading -->

<!-- wp:paragraph -->
<p>Как станок ведёт себя в деле: удобство настройки, повторяемость угла, что мешает.</p>
<!-- /wp:paragraph -->

<!-- wp:pattern {"slug":"zt-web/triple"} /-->

<!-- wp:heading -->
<h2 class="wp-block-heading">Заключение</h2>
<!-- /wp:heading -->

<!-- wp:paragraph -->
<p>Кому такой станок нужен и что стоит докупить сразу.</p>
<!-- /wp:paragraph -->
