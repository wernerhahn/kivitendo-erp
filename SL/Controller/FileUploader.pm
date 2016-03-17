package SL::Controller::FileUploader;

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
sub action_test_page{
  my ($self) = @_;
  $self->render('fileuploader/test_page');
}

sub action_upload_form{
  my ($self) = @_;
  $self->file(SL::DB::File->new);
  $self->render('common/file_upload', {header => 0});
}

sub action_show_files {
  my ($self) = @_;


}

sub action_ajax_add_file{
  my ($self) = @_;
  $self->file(SL::DB::File->new);
  $self->render('common/file_upload', { layout => 0}, DATA => $::form);
}

sub action_ajax_upload_file{
  my ($self, %params) = @_;
  my $attributes                  = $::form->{ $::form->{form_prefix} } || die "Missing FormPrefix";
  $attributes->{trans_id}         = $::form->{id} || die "Missing ID";
  $attributes->{modul}            = $::form->{modul} || die "Missing Modul";
  $attributes->{filename}         = $::form->{FILENAME} || die "Missing Filename";
  $attributes->{title}            = $::form->{ $::form->{form_prefix} }->{title};
  $attributes->{description}      = $::form->{ $::form->{form_prefix} }->{description};
  my @image_types = ("jpg","tif","png");

  my @errors = $self->file(SL::DB::File->new(%{ $attributes }))->validate;
  return $self->js->error(@errors)->render($self) if @errors;

  $self->file->save;

  # TODO js call
  $self->render('fileuploader/test_page');
}

#
# helpers
#

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

# longer description...


=head1 INTERFACE


=head1 DEPENDENCIES


=head1 SEE ALSO

=head1 AUTHOR

Werner Hahn E<lt>wh@futureworldsearch.netE<gt>

=cut
