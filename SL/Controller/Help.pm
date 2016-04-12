package SL::Controller::Help;

use strict;

use parent qw(SL::Controller::Base);

use SL::HelpSystem;
use SL::Helper::Flash;
use SL::Locale::String;

use Rose::Object::MakeMethods::Generic
(
  'scalar --get_set_init' => [ qw(context context_controller context_action) ],
);

#
# actions
#

sub action_show {
  my ($self) = @_;

  my @potential_pages;

  my $language = $::myconfig{countrycode};
  $language    = undef if ($language // '') eq 'de';

  if ($self->context_controller) {
    if ($language) {
      push @potential_pages, { language => $language, category => $self->context_controller, topic => $self->context_action } if $self->context_action;
      push @potential_pages, { language => $language, category => $self->context_controller, topic => '_index' };
    }

    push @potential_pages, { language => 'de', category => $self->context_controller, topic => $self->context_action } if $self->context_action;
    push @potential_pages, { language => 'de', category => $self->context_controller, topic => '_index' };
  }

  push @potential_pages, { language => $language, topic => '_index' } if $language;
  push @potential_pages, { language => 'de',      topic => '_index' };

  my $page = $::request->help_system->page_available(@potential_pages);

  return $::form->error(t8("No help page to show was found.")) if !$page;

  $::request->layout(SL::Layout::Dispatcher->new(style => 'none'));
  $::request->layout->use_stylesheet('help.css');

  $self->render(
    'help/show',
    title   => t8('kivitendo help'),
    content => $::request->help_system->convert_page_to_html(%$page),
  );
}

#
# helpers
#

sub init_context            { $::form->{context} // ''           }
sub init_context_controller { (split m{/}, $_[0]->context, 2)[0] }
sub init_context_action     { (split m{/}, $_[0]->context, 2)[1] }

1;
