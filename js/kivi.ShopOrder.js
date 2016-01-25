namespace('kivi.ShopOrder', function(ns) {
  this.massTransferInitialize = function() {
    kivi.popup_dialog({
      id: 'status_mass_transfer',
      dialog: {
        title: kivi.t8('Status Shoptransfer')
      }
    });
    alert('Hallo');
  };

  this.massTransferStarted = function() {
    $('#status_mass_transfer').data('timerId', setInterval(function() {
      $.get("controller.pl", {
        action: 'ShopOrder/transfer_status',
        job_id: $('#smt_job_id').val()
      }, kivi.eval_json_result);
    }, 5000));
  };

  this.massTransferFinished = function() {
    clearInterval($('#status_mass_transfer').data('timerId'));
    $('.ui-dialog-titlebar button.ui-dialog-titlebar-close').prop('disabled', '')
  };

  this.setup = function() {
    kivi.ShopOrder.massTransferInitialize();
    kivi.submit_ajax_form('controller.pl?action=ShopOrder/mass_transfer','[name=shop_orders]');
  };

});
//$(kivi.ShopOrder.setup);
