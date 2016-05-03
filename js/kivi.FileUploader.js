namespace('kivi.FileUploader', function(ns) {
  //opens a popupdialog for fileupload
  //controller_action is passed to the popup_dialog fileupload form and can/will be called from the form to deal with the uploaded file
  ns.add_file = function(id,modul,controller_action,allowed_filetypes) {
    kivi.popup_dialog({
        url :           'controller.pl?action=FileUploader/ajax_add_file',
        data:           'id=' + id + '&modul=' + modul + '&ca=' + controller_action + '&aft=' + allowed_filetypes,
        dialog:         { title: kivi.t8('File upload') }
    } );
    return true;
  };
});
