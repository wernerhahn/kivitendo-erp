namespace('kivi.SalesPurchase', function(ns) {
  this.edit_longdescription = function(row) {
    var $element = $('#longdescription_' + row);

    if (!$element.length) {
      console.error("kivi.SalesPurchase.edit_longdescription: Element #longdescription_" + row + " not found");
      return;
    }

    var params = { element: $element,
                   runningnumber: row,
                   partnumber: $('#partnumber_' + row).val() || '',
                   description: $('#description_' + row).val() || '',
                   default_longdescription: $('#longdescription_' + row).val() || ''
                 };
    this.edit_longdescription_with_params(params);
  };

  this.edit_longdescription_with_params = function(params) {
    var $container = $('#popup_edit_longdescription_input_container');
    var $edit      = $('<textarea id="popup_edit_longdescription_input" class="texteditor-in-dialog" wrap="soft" style="width: 750px; height: 220px;"></textarea>');

    $container.children().remove();
    $container.append($edit);

    if (params.element) {
      $container.data('element', params.element);
    }

    $edit.val(params.default_longdescription);

    kivi.init_text_editor($edit);

    $('#popup_edit_longdescription_runningnumber').html(params.runningnumber);
    $('#popup_edit_longdescription_partnumber').html(params.partnumber);

    var description = params.description.replace(/[\n\r]+/, '');
    if (description.length >= 50)
      description = description.substring(0, 50) + "…";
    $('#popup_edit_longdescription_description').html(description);

    kivi.popup_dialog({
      id:    'edit_longdescription_dialog',
      dialog: {
        title: kivi.t8('Enter longdescription'),
        open:  function() { kivi.focus_ckeditor_when_ready('#popup_edit_longdescription_input'); },
        close: function() { $('#popup_edit_longdescription_input_container').children().remove(); }
      }
    });
  };

  this.set_longdescription = function() {
    $('#popup_edit_longdescription_input_container')
      .data('element')
      .val( $('#popup_edit_longdescription_input').val() );

    $('#edit_longdescription_dialog').dialog('close');
  };

  this.delivery_order_check_transfer_qty = function() {
    var all_match = true;
    var rowcount  = $('input[name=rowcount]').val();
    for (var i = 1; i < rowcount; i++)
      if ($('#stock_in_out_qty_matches_' + i).val() != 1)
        all_match = false;

    if (all_match)
      return true;

    return confirm(kivi.t8('There are still transfers not matching the qty of the delivery order. Stock operations can not be changed later. Do you really want to proceed?'));
  };

  this.oe_warn_save_active_periodic_invoice = function() {
    return confirm(kivi.t8('This sales order has an active configuration for periodic invoices. If you save then all subsequently created invoices will contain those changes as well, but not those that have already been created. Do you want to continue?'));
  };

  this.check_transaction_description = function() {
    if ($('#transaction_description').val() != '')
      return true;

    alert(kivi.t8('A transaction description is required.'));
    return false;
  };

  this.on_submit_checks = function() {
    var $button = $(this);
    if (($button.data('check-transfer-qty') == 1) && !kivi.SalesPurchase.delivery_order_check_transfer_qty())
      return false;

    if (($button.data('warn-save-active-periodic-invoice') == 1) && !kivi.SalesPurchase.oe_warn_save_active_periodic_invoice())
      return false;

    if (($button.data('require-transaction-description') == 1) && !kivi.SalesPurchase.check_transaction_description())
      return false;

    return true;
  };

  this.init_on_submit_checks = function() {
     $('input[type=submit]').click(kivi.SalesPurchase.on_submit_checks);
  };

  this.set_duedate_on_reference_date_change = function(reference_field_id) {
    setTimeout(function() {
      var data = {
        action:     'set_duedate',
        invdate:    $('#' + reference_field_id).val(),
        duedate:    $('#duedate').val(),
        payment_id: $('#payment_id').val(),
      };
      $.post('is.pl', data, kivi.eval_json_result);
    });
  };
});
