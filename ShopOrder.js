namespace('kivi.ShopOrder', function(ns) {

  this.massTransferInitialize = function() {
    kivi.popup_dialog({
      id: 'status_mass_transfer',
      dialog: {
        title: kivi.t8('Status Shoptransfer')
      }
    });
  }

  this.massTransferStarted = function() {
    $('#status_mass_transfer').data('timerId', setInterval(function() {
      $.get("controller.pl", {
        action: 'ShopOrderMassTransfer/_transfer_status',
        job_id: $('smt_job_id').val()
      }, kivi.eval_json_result);
    }, 5000));
  };

  this.setup = function() {
    alert('HALLO');
    $('#mass_transfer').click(kivi.ShopOrderMassTransfer.massTransferInitialize);
  };
});

$(kivi.ShopOrderMassTransfer.setup);
