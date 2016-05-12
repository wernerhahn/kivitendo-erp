package SL::Controller::Shop;

use strict;

use parent qw(SL::Controller::Base);

use SL::Helper::Flash;
use SL::Locale::String;
use SL::DB::Default;
use SL::DB::Manager::Shop;
use SL::DB::Pricegroup;

use Rose::Object::MakeMethods::Generic (
  scalar                  => [ qw(connectors price_types price_sources) ],
  'scalar --get_set_init' => [ qw(shop) ]
);

__PACKAGE__->run_before('check_auth');
__PACKAGE__->run_before('load_types',    only => [ qw(new edit) ]);

#
# actions
#

sub action_list {
  my ($self) = @_;

  $self->render('shops/list',
                title => t8('Shops'),
                SHOPS => SL::DB::Manager::Shop->get_all_sorted,
               );
}

sub action_new {
  my ($self) = @_;

  $self->shop(SL::DB::Shop->new);
  $self->render('shops/form', title       => t8('Add shop'));
};

sub action_edit {
  my ($self) = @_;

  $self->render('shops/form', title       => t8('Edit shop'));
}

sub action_create {
  my ($self) = @_;

  $self->shop(SL::DB::Shop->new);
  $self->create_or_update;
}

sub action_update {
  my ($self) = @_;
  $self->create_or_update;
}

sub action_delete {
  my ($self) = @_;

  if ( eval { $self->shop->delete; 1; } ) {
    flash_later('info',  $::locale->text('The shop has been deleted.'));
  } else {
    flash_later('error', $::locale->text('The shop has been used and cannot be deleted.'));
  };
  $self->redirect_to(action => 'list');
}

sub action_reorder {
  my ($self) = @_;

  SL::DB::Shop->reorder_list(@{ $::form->{shop_id} || [] });
  $self->render(\'', { type => 'json' });
}

#
# filters
#

sub check_auth {
  $::auth->assert('config');
}

sub init_shop {
  SL::DB::Shop->new(id => $::form->{id})->load;
}

#
# helpers
#

sub create_or_update {
  my ($self) = @_;
  my $is_new = !$self->shop->id;

  my $params = delete($::form->{shop}) || { };

  $self->shop->assign_attributes(%{ $params });

  my @errors = $self->shop->validate;

  if (@errors) {
    flash('error', @errors);
    $self->render('shops/form',
                   title => $is_new ? t8('Add shop') : t8('Edit shop'));
    return;
  }

  $self->shop->save;

  flash_later('info', $is_new ? t8('The shop has been created.') : t8('The shop has been saved.'));
  $self->redirect_to(action => 'list');
}

sub load_types {
  my ($self) = @_;
  # data for the dropdowns when editing Shop configs

  # hardcoded the possible connectors, which correspond to
  # SL/ShopConnector/xxxx classes
  $self->connectors( [ { id => "xtcommerce", description => "XT Commerce"},
                       { id => "shopware",   description => "Shopware" },
                       { id => "ideal",      description => "IDeal" }
                     ]);

  # whether the shop presents its prices as brutto or netto
  $self->price_types( [ { id => "brutto", name => t8('brutto')}, { id => "netto", name => t8('netto') } ] );

  # the possible default price sources to use for the shops: sellprice, lastcost,
  # listprice, or one of the pricegroups
  my $pricesources;
  push( @{ $pricesources } , { id => "master_data/sellprice", name => t8("Master Data")." - ".t8("Sellprice") },
                             { id => "master_data/listprice", name => t8("Master Data")." - ".t8("Listprice") },
                             { id => "master_data/lastcost",  name => t8("Master Data")." - ".t8("Lastcost") }
                             );
  my $pricegroups = SL::DB::Manager::Pricegroup->get_all;
  foreach my $pg ( @$pricegroups ) {
    push( @{ $pricesources } , { id => "pricegroup/".$pg->id, name => t8("Pricegroup") . " - " . $pg->pricegroup} );
  };

  $self->price_sources( $pricesources );
};


1;

__END__

=encoding utf-8

=head1 NAME

  SL::Controller::Shop

=head1 SYNOPSIS


=head1 DESCRIPTION


=head1 BUGS

  None yet. :)

=head1 AUTHOR

  G. Richardson E<lt>information@kivitendo-premium.deE<gt>
  W. Hahn E<lt>wh@futureworldsearch.netE<gt>
