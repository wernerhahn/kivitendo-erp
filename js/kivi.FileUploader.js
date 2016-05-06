namespace('kivi.FileUploader', function(ns) {
  //opens a popupdialog for fileupload

  //id                  = id of the id in the table files
  //trans_id            = id of the object (part_id, shoppart_id, project_id,...) where the file belongs to
  //modul               = name where the file belongs to like IC, shop_part, CV ....
  //controller_action   = Controller/Action wich will be called by button save in popupdialog the todo whatever you want to to with the file(save it to db, save it to webdav)
  //                      controller_action is passed to the popup_dialog fileupload form and can/will be called from the form to deal with the uploaded file
  //allowed_filetypes   = must be seperated by | like jpg|gif|pdf
  ns.add_file = function(id,trans_id,modul,controller_action,allowed_filetypes) {
    kivi.popup_dialog({
        url :           'controller.pl?action=FileUploader/ajax_add_file',
        data:           'id=' + id + '&trans_id=' + trans_id + '&modul=' + modul + '&ca=' + controller_action + '&aft=' + allowed_filetypes,
        dialog:         { title: kivi.t8('File upload') }
    } );
    return true;
  };

  ns.delete_file = function(id,controller_action) {
    $.post('controller.pl', { action: controller_action, id: id }, function(data) {
      kivi.eval_json_result(data);
    });
  };
});
