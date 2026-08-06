<?php
/**
 * Title: Инструкция
 * Slug: zt-web/howto
 * Categories: zt-web
 * Block Types: core/post-content
 * Post Types: post
 * Description: Каркас статьи для раздела «Полезное»: не обзор предмета, а порядок действий.
 * Keywords: инструкция, полезное, методика
 * Inserter: yes
 *
 * Вставляется копией.
 *
 * Ни характеристик, ни врезки о методике здесь нет: инструкция не про
 * предмет, а про действие, и ссылаться из неё на методику незачем — она сама
 * может быть той методикой, на которую ссылаются обзоры.
 *
 * @package zt-web
 */

?>
<!-- wp:paragraph -->
<p>Зачем это делать и когда это нужно.</p>
<!-- /wp:paragraph -->

<!-- wp:heading -->
<h2 class="wp-block-heading">Что понадобится</h2>
<!-- /wp:heading -->

<!-- wp:list -->
<ul class="wp-block-list">
<!-- wp:list-item --><li>Первое</li><!-- /wp:list-item -->
<!-- wp:list-item --><li>Второе</li><!-- /wp:list-item -->
</ul>
<!-- /wp:list -->

<!-- wp:heading -->
<h2 class="wp-block-heading">Порядок действий</h2>
<!-- /wp:heading -->

<!-- wp:list {"ordered":true} -->
<ol class="wp-block-list">
<!-- wp:list-item --><li>Шаг первый.</li><!-- /wp:list-item -->
<!-- wp:list-item --><li>Шаг второй.</li><!-- /wp:list-item -->
</ol>
<!-- /wp:list -->

<!-- wp:pattern {"slug":"zt-web/triple"} /-->

<!-- wp:heading -->
<h2 class="wp-block-heading">Частые ошибки</h2>
<!-- /wp:heading -->

<!-- wp:paragraph -->
<p>Что обычно идёт не так и как это выглядит.</p>
<!-- /wp:paragraph -->
