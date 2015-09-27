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


# old:
sub action_edit {
  my ($self) = @_;

  $self->render('shop_part/edit'); #, { output => 0 }); #, price_source => $price_source)
}

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
  $::request->{layout}->add_javascripts(qw(kivi.shop_part.js));
}

sub check_auth {
  return 1; # TODO: implement shop rights
  # $::auth->assert('shop');
}

sub init_shop_part {
  if ($::form->{shop_part_id}) { 
    SL::DB::ShopPart->new(id => $::form->{shop_part_id})->load;
  } else {
    SL::DB::ShopPart->new(shop_id => $::form->{shop_id}, part_id => $::form->{part_id});
  };
}

1;

