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
  return $self->multimarkdown->markdown($markup);
}

1;
