# This file has been auto-generated only because it didn't exist.
# Feel free to modify it at will; it will not be overwritten automatically.

package SL::DB::Shop;

use strict;

use SL::DB::MetaSetup::Shop;
use SL::DB::Manager::Shop;
use SL::DB::Helper::ActsAsList;

__PACKAGE__->meta->add_relationships(
  shop_parts     => {
    type         => 'one to many',
    class        => 'SL::DB::ShopPart',
    column_map   => { id => 'shop_id' },
  },
);

__PACKAGE__->meta->initialize;

sub validate {
  my ($self) = @_;

  my @errors;

  push @errors, $::locale->text('The description is missing.') unless $self->{description};

  return @errors;
}
1;
