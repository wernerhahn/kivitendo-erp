package SL::HelpSystem;

use strict;

use parent qw(Rose::Object);

use List::Util qw(first);

use SL::System::Process;

use Rose::Object::MakeMethods::Generic (
  'scalar --get_set_init' => [ qw(context base_path driver) ],
);

my %custom_help_contexts;

sub init_base_path { SL::System::Process::exe_dir() . '/templates/webpages/help' }

sub init_driver {
  require SL::HelpSystem::MultiMarkdown;
  return SL::HelpSystem::MultiMarkdown->new;
}

sub init_context {
  my ($controller, $action) = $::request ? ($::request->controller, $::request->action) : ();

  return undef if !$controller;

  my $override = ($custom_help_contexts{$controller} // {})->{$action};

  return $override               if $override && ($override =~ m{/});
  return "$controller/$override" if $override;
  return "$controller/$action"   if $action;
  return $controller;
}

sub page_available {
  my ($self, @pages) = @_;

  return first { -f $self->file_name_for_page(%$_) } @pages;
}

sub file_name_for_page {
  my ($self, %page) = @_;

  my $sub_path = join '/', grep { ($_ // '') ne '' } @page{ qw(language category topic) };

  return $self->base_path . '/content/' . $sub_path . '.' . $self->driver->file_name_extension;
}

sub convert_page_to_html {
  my ($self, %page) = @_;

  my $file_name = $self->file_name_for_page(%page);

  return -f $file_name ? $self->driver->convert_page_to_html($file_name) : undef;
}

sub sanitize {
  my ($self, $name) = @_;

  $name //= '';
  $name   =~ s{[^a-z0-9_-]+}{}gi;

  return $name;
}

sub override_help_contexts {
  my ($class, $controller, %help_contexts) = @_;

  $custom_help_contexts{$controller} = \%help_contexts;
}

1;

__END__

=pod

=encoding utf8

=head1 NAME

SL::HelpSystem - Help system helper functions

=head1 SYNOPSIS

  my $help_system = SL::HelpSystem->new;
  my $page = $help_system->page_available('de/ic/add');
  if ($page) {
    $self->render(
      'help/show',
      title   => t8('kivitendo help'),
      content => $help_system->convert_page_to_html($page),
    );
  }

=head1 FUNCTIONS

=over 4

=item C<base_path>

Returns the base path where all the help pages are stored.

=item C<context>

This gets or sets the help context. The help context is used by the
layout when displaying a link to the help system.

If a controller does not set a help context then it defaults to
C<controller/action> as returned by the two functions with the same
name in the L<SL::Request> object.

=item C<convert_page_to_html %page>

Converts a markup help page to HTML and returns the converted
HTML. The C<%page> parameter must be a hash suitable for
L</file_name_for_page>.

=item C<driver>

Gets or sets the driver to use. The default driver supports
MultiMarkdown via L<SL::HelpSystem::MultiMarkdown>.

=item C<file_name_for_page %page>

Returns the file name for a help page. Note that the file may or may
not exist.

The C<%page> must be a hash with the following keys: C<language>,
C<category> and C<topic>. Their values are sanitized with the
L</sanitize> function and concatenated in exactly this order to form
the actual file name. Elements that aren't set are skipped.

The C<category> will usually be a controller name and the C<topic>
will usually be an action for that controller.

=item C<page_available @pages>

Returns the first page for which a file name as given by
L</file_name_for_page> exists. C<@pages> must be an array of hash refs
suitable for L</file_name_for_page>.

=item C<sanitize $name>

Page name components may only consist of the following characters: the
characters C<a-z> and C<A-Z>, digits C<0-9> and the special characters
C<_> and C<->.

This function removes all other characters from C<$name> and returns
the cleaned version.

=back

=head1 BUGS

Nothing here yet.

=head1 AUTHOR

Moritz Bunkus E<lt>m.bunkus@linet-services.deE<gt>

=cut
