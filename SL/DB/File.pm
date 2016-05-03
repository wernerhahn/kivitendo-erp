# This file has been auto-generated only because it didn't exist.
# Feel free to modify it at will; it will not be overwritten automatically.

package SL::DB::File;

use strict;

use SL::DB::MetaSetup::File;
use SL::DB::Manager::File;
use SL::DB::Helper::ActsAsList;
use SL::DB::Helper::ThumbnailCreator;
use SL::Locale::String;

__PACKAGE__->meta->initialize;

__PACKAGE__->configure_acts_as_list(group_by => [qw(trans_id modul)]);

#__PACKAGE__->before_save(\&file_update_thumbnail);

sub validate {
  my ( $self ) = @_;

  my @errors;
  push @errors, t8('The file name is missing') if !$self->filename;

  if (!length($self->file_content // '')) {
    push @errors, t8('No file has been uploaded');
  } else {
    push @errors, $self->file_update_type_and_dimensions;
  }
  return @errors;
}

1;
__END__

=pod

=encoding utf8

=head1 NAME

  SL::DB::File - Databaseclass for Fileuploader

=head1 SYNOPSIS

  use SL::DB::File;

  # synopsis...

=head1 DESCRIPTION

  # longer description.


=head1 INTERFACE


=head1 DEPENDENCIES


=head1 SEE ALSO

=head1 AUTHOR

  Werner Hahn E<lt>wh@futureworldsearch.netE<gt>

=cut
