namespace('kivi.shop_part', function(ns) {
  var $dialog;

  // this is called by sub render, with a certain prerendered html (edit.html,categories.html)
  ns.shop_part_dialog = function(title, html) {
    var id            = 'jqueryui_popup_dialog';
    var dialog_params = {
      id:     id,
      width:  800,
      height: 500,
      modal:  true,
      close: function(event, ui) { $dialog.remove(); },
    };

    $('#' + id).remove();

    $dialog = $('<div style="display:none" id="' + id + '"></div>').appendTo('body');
    $dialog.attr('title', title);
    $dialog.html(html);
    $dialog.dialog(dialog_params);

    $('.cancel').click(ns.close_dialog);

    return true;
  };

  ns.close_dialog = function() {
    $dialog.dialog("close");
  }


  // save existing shop_part_id with new params from form, calls create_or_update and saves to db
  ns.save_shop_part = function(shop_part_id) {
    var form = $('form').serializeArray();
    form.push( { name: 'action', value: 'ShopPart/update' }
             , { name: 'shop_part_id',  value: shop_part_id }
    );

    $.post('controller.pl', form, function(data) {
      kivi.eval_json_result(data);
    });
  }

  // add part to a shop
  ns.add_shop_part = function(part_id,shop_id) {
    var form = $('form').serializeArray();
    form.push( { name: 'action', value: 'ShopPart/update' }
    );
//alert(form.join('\n'));
    $.post('controller.pl', form, function(data) {
      kivi.eval_json_result(data);
    });
  }

  // this is called from tabs/_shop.html, opens edit_window (render)
  ns.edit_shop_part = function(shop_part_id) {
    $.post('controller.pl', { action: 'ShopPart/create_or_edit_popup', shop_part_id: shop_part_id }, function(data) {
      kivi.eval_json_result(data);
    });
  }

  // does the same as edit_shop_part (existing), but with part_id and shop_id, opens edit window (render)
  ns.create_shop_part = function(part_id, shop_id) {
    $.post('controller.pl', { action: 'ShopPart/create_or_edit_popup', part_id: part_id, shop_id: shop_id }, function(data) {
      kivi.eval_json_result(data);
    });
  }

  // gets all categories from the webshop
  ns.get_all_categories = function(shop_part_id) {
    var form = $('form').serializeArray();
    form.push( { name: 'action', value: 'ShopPart/get_categories' }
             , { name: 'shop_part_id', value: shop_part_id }
    );

    $.post('controller.pl', form, function(data) {
      kivi.eval_json_result(data);
    });
  }
  // write categories in kivi DB not in the shops DB TODO: create new categories in the shops db
  ns.save_categories = function(shop_part_id, shop_id) {
    var form = $('form').serializeArray();
    form.push( { name: 'action', value: 'ShopPart/save_categories' }
             , { name: 'shop_id', value: shop_id }
             , { name: 'shop_part_id', value: shop_part_id }
    );

    $.post('controller.pl', form, function(data) {
      kivi.eval_json_result(data);
    });
  }

  ns.update_shop_part = function(shop_part_id) {
    $.post('controller.pl', { action: 'ShopPart/update_shop', shop_part_id: shop_part_id }, function(data) {
      kivi.eval_json_result(data);
    });
  }

  ns.update_discount_source = function(row, source, discount_str) {
    $('#active_discount_source_' + row).val(source);
    if (discount_str) $('#discount_' + row).val(discount_str);
    $('#update_button').click();
  }

  ns.show_images = function(id) {
    var url = 'controller.pl?action=ShopPart/show_files&modul=shop_part&id='+id;
    $('#shop_images').load(url);
  }

  //shows the Name and price in _shop.html. Pricerules not implemented yet, just master_data and pricegroups
  ns.update_price_n_price_source = function(shop_part_id,price_source) {
    $.post('controller.pl', { action: 'ShopPart/show_price_n_pricesource', shop_part_id: shop_part_id, pricesource: price_source }, function(data) {
      kivi.eval_json_result(data);
    });
  }
  //shows the local and the online stock
  ns.update_stock = function(shop_part_id) {
    $.post('controller.pl', { action: 'ShopPart/show_stock', shop_part_id: shop_part_id }, function(data) {
      kivi.eval_json_result(data);
    });
  }

});
