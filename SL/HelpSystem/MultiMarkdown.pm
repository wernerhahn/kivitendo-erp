package SL::HelpSystem::MultiMarkdown;

use strict;

use parent qw(Rose::Object);

use Encode ();
use File::Slurp ();
use Text::MultiMarkdown;

use Rose::Object::MakeMethods::Generic (
  'scalar --get_set_init' => [ qw(multimarkdown) ],
);

sub init_multimarkdown {
  return Text::MultiMarkdown->new(
    empty_element_suffix => '>',
    tab_width            => 4,
  );
}

sub file_name_extension { "mmd" }

sub convert_to_html {
  my ($self, $file_name) = @_;

  my $markup = Encode::decode('utf-8', scalar(File::Slurp::slurp($file_name)));
  my $html   = $self->multimarkdown->markdown($markup);
  $html      = $self->_processh_intra_help_links($html);

  return $html;
}

sub _processh_intra_help_links {
  my ($self, $html) = @_;

  # <a href="help:_tests/lorem_ipsum">

  $html =~ s{
    ( <a \s+ href \s* = \s* " ) help:
  }{
    $1 . qq|controller.pl?action=Help/show&context=|
  }gxe;

  return $html;
}


1;
