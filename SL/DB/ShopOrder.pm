# This file has been auto-generated only because it didn't exist.
# Feel free to modify it at will; it will not be overwritten automatically.

package SL::DB::ShopOrder;

use strict;

use SL::DB::MetaSetup::ShopOrder;
use SL::DB::Manager::ShopOrder;

__PACKAGE__->meta->add_relationships(
  shop_order_items => {
    class      => 'SL::DB::ShopOrderItem',
    column_map => { id => 'shop_order_id' },
    type       => 'one to many',
  },
);

__PACKAGE__->meta->initialize;

1;
