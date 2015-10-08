package SL::Controller::ShopPart;

use strict;

use parent qw(SL::Controller::Base);

use Data::Dumper;
use SL::Locale::String qw(t8);
use SL::DB::ShopPart;
use SL::Helper::Flash;

use Rose::Object::MakeMethods::Generic
(
  'scalar --get_set_init' => [ qw(shop_part js) ],
);

__PACKAGE__->run_before('check_auth');
__PACKAGE__->run_before('add_javascripts', only => [ qw(edit_popup) ]);
#
# actions
#

sub action_create_or_edit_popup {
  my ($self) = @_;

  $self->render_shop_part_edit_dialog();
};

sub action_update_shop {
  my ($self, %params) = @_;

  my $shop_part = SL::DB::Manager::ShopPart->find_by(id => $::form->{shop_part_id});
  die unless $shop_part;
  require SL::Shop;
  my $shop = SL::Shop->new( config => $shop_part->shop );

  # TODO: generate data to upload to shop
  my $part_hash = $shop_part->part->as_tree;
  my $json      = SL::JSON::to_json($part_hash);
  my $return    = $shop->connector->update_part($self->shop_part, $json);

  # the connector deals with parsing/result verification, just needs to return success or failure
  if ( $return == 1 ) {
    # TODO: write update time to DB
    my $now = DateTime->now;
    $self->js->html('#shop_part_last_update_' . $shop_part->id, $now->to_kivitendo('precision' => 'minute'))
           ->flash('info', t8("Updated part [#1] in shop [#2] at #3", $shop_part->part->displayable_name, $shop_part->shop->description, $now->to_kivitendo('precision' => 'minute') ) )
           ->render;
  } else {
    $self->js->flash('error', t8('The shop part wasn\'t updated.'))->render;
  };

};



# old:
# sub action_edit {
#   my ($self) = @_;
# 
#   $self->render('shop_part/edit'); #, { output => 0 }); #, price_source => $price_source)
# }
#
# used when saving existing ShopPart

sub action_update {
  my ($self) = @_;

  $self->create_or_update;
}

sub create_or_update {
  my ($self) = @_;

  my $is_new = !$self->shop_part->id;

  # in edit.html all variables start with shop_part
  my $params = delete($::form->{shop_part}) || { };

  $self->shop_part->assign_attributes(%{ $params });

  $self->shop_part->save;

  flash('info', $is_new ? t8('The shop part has been created.') : t8('The shop part has been saved.'));
  # $self->js->val('#partnumber', 'ladida');
  $self->js->html('#shop_part_description_' . $self->shop_part->id, $self->shop_part->shop_description)
           ->html('#shop_part_active_' . $self->shop_part->id, $self->shop_part->active)
           ->run('kivi.shop_part.close_dialog')
           ->flash('info', t8("Updated shop part"))
           ->render;
}

sub render_shop_part_edit_dialog {
  my ($self) = @_;

  # when self->shop_part is called in template, it will be an existing shop_part with id,
  # or a new shop_part with only part_id and shop_id set
  $self->js
    ->run(
      'kivi.shop_part.shop_part_dialog',
      t8('Shop part'),
      $self->render('shop_part/edit', { output => 0 }) #, shop_part => $self->shop_part)
    )
    ->reinit_widgets;

  $self->js->render;
}

#
# internal stuff
#
sub add_javascripts  {
  # is this needed?
  $::request->{layout}->add_javascripts(qw(kivi.shop_part.js));
}

sub check_auth {
  return 1; # TODO: implement shop rights
  # $::auth->assert('shop');
}

sub init_shop_part {
  if ($::form->{shop_part_id}) {
    SL::DB::Manager::ShopPart->find_by(id => $::form->{shop_part_id});
  } else {
    SL::DB::ShopPart->new(shop_id => $::form->{shop_id}, part_id => $::form->{part_id});
  };
}

1;

=pod

=encoding utf-8

=head1 NAME

SL::Controller::ShopPart - Controller for managing ShopParts

=head1 SYNOPSIS

ShopParts are configured in a tab of the corresponding part.

=head1 FUNCTIONS

=over 4

=item C<action_update_shop>

To be called from the "Update" button, for manually syncing a part with its
shop. Generates a  Calls some ClientJS functions to modifiy original page.

=back

=head1 AUTHORS

G. Richardson E<lt>information@kivitendo-premium.deE<gt>

=cut
