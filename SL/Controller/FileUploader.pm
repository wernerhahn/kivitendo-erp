package SL::Controller::FileUploader;
# Controller will not be used if things for FILES needed they can go in Helpers
use strict;
use parent qw(SL::Controller::Base);

use SL::DB::File;

use SL::Helper::Flash;
use SL::Locale::String;

use Rose::Object::MakeMethods::Generic
(
  'scalar --get_set_init' => [ qw(file) ],
);

#
# actions
#

# this action can be thrown out, they where only for testing the testpage
sub action_test_page{
  my ($self) = @_;
  $self->render('fileuploader/test_page');
}

# this action renders the popup dialog to upload the file
sub action_ajax_add_file{
  my ($self) = @_;
  $self->file(SL::DB::File->new);
  $self->render('common/file_upload', { layout => 0}, data => $::form);
}


#
# helpers
#

sub validate_filetype {
  my ($self,$filename,$allowed_filetypes) = @_;

  my @errors;
  my($file,$filetype) = split /\./, $filename;
  my @file_types = split /\|/, $allowed_filetypes;

  if (!grep {$_ eq $filetype} @file_types) {
      push @errors, t8("Filetype not allowed");
  }
  return @errors
}

sub init_file {
  return SL::DB::File->new(id => $::form->{id})->load;
}

1;
__END__

=pod

=encoding utf8

=head1 NAME

  SL::Controller::FileUploader - Controller to manage fileuploads

=head1 SYNOPSIS

  use SL::Controller::FileUploader;

  # synopsis.. =>

=head1 DESCRIPTION

  just the action ajax_add_file is needed and its automaticly called by. The other ones are for the testpage templates/webpages/testpage.html
  kivi.add.file(id[shop_part_id,part_id, cv_id, project_id,...],modul[part,shop_part,project,IC,...],controller_action[ShopPart/do_something_file],allowed_filestypes) in your template.
  [% L.button_tag("kivi.add_file(this.form.id.value,'shop_part', 'Part/do_something_with_file','jpg,png,gif,pdf')", 'Fileupload') %]

  The called Controller/Action deals with the uploaded file in wich you can do whatever you want with the file.
  like
  - Store it in the Database SL::DB::File
  - Store it in Webdav
  - Store it in Webdav and DB (be careful: files wich deleted in the filesystem will not be deleted in the database automaticly)
  - do something very fancy with the file


=head1 INTERFACE


=head1 DEPENDENCIES


=head1 SEE ALSO

=head1 AUTHOR

Werner Hahn E<lt>wh@futureworldsearch.netE<gt>

=cut
