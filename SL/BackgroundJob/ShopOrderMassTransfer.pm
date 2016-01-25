package SL::BackgroundJob::ShopOrderMassTransfer;

use strict;
use warnings;

use parent qw(SL::BackgroundJob::Base);

#
# Workflow Dreschflegel Shoporder import -> wo geht automatisch nach Order(Auftrag) und DeliveryOrder (Lieferschein) mit auslagern transferieren
#

use SL::DBUtils;
use SL::DB::ShopOrder;
use SL::DB::ShopOrderItem;
use SL::DB::Order;
use SL::DB::DeliveryOrder;
use SL::DB::Inventory;
use Sort::Naturally ();

use constant WAITING_FOR_EXECUTION        => 0;
use constant CONVERTING_TO_ORDER          => 1;
use constant CONVERTING_TO_DELIVERY_ORDER => 2;
use constant DONE                         => 3;

# Data format:
# my $data                  = {
#     shop_order_record_ids       => [ 603, 604, 605],
#     num_order_created           => 0,
#     num_delivery_order_created  => 0,
#     conversation_errors         => [ { id => 603 , item => 2, message => "Out of stock"}, ],
# };
#

sub create_order {
  my ( $self ) = @_;
  my $job_obj = $self->{job_obj};
  my $db      = $job_obj->db;
  my %error_report;
  $job_obj->set_data(CONVERTING_TO_DELIVERY_ORDER())->save;

  foreach my $shop_order_id (@{ $job_obj->data_as_hash->{shop_order_record_ids} }) {
    my $shop_order = SL::DB::ShopOrder->new(id => $shop_order_id)->load;
    # die "can't find shoporder with id $shop_order_id" unless $shop_order;
    #TODO Kundenabfrage so ändern, dass es nicht abricht
    unless($shop_order){
      push @{ $error_report{$shop_order_id}} }, 'Shoporder not found';
    }
    my $customer = SL::DB::Manager::Customer->find_by(id => $shop_order->{kivi_customer_id});
    die "Can't find customer" unless $customer;
    my $employee = SL::DB::Manager::Employee->current;
    my $items = SL::DB::Manager::ShopOrderItem->get_all( where => [shop_order_id => $shop_order_id],
                                                          sort_by => 'partnumber::int' );
    # check inventory onhand > 0
    my $onhand = 0;
    foreach my $item (@$items) {
      my $qty = SL::DB::Manager::Part->find_by(partnumber => $item->{partnumber})->onhand; # > 0 ? $onhand = 1 : 0;
      $qty >= $item->{quantity} ? $onhand = 1 : 0;
      last if $onhand == 0;
    }
    if ($onhand == 1) {
      $shop_order->{shop_order_items} = $items;

      my $order = $shop_order->convert_to_sales_order(customer => $customer, employee => $employee);
      $order->save;
      $shop_order->transferred(1);
      $shop_order->transfer_date(DateTime->now_local);
      $shop_order->oe_transid($order->id);
      $shop_order->save;
      $shop_order->link_to_record($order);

      my $delivery_order = $order->convert_to_delivery_order(customer => $customer, employee => $employee);
      $delivery_order->save;
      $order->link_to_record($delivery_order);
      my $delivery_order_items = $delivery_order->{orderitems};
      # Lagerentnahme
      # entsprechende defaults holen, falls standardlagerplatz verwendet werden soll
      my $test = $::instance_conf->get_transfer_default_use_master_default_bin;
      require SL::DB::Inventory;
      my $rose_db = SL::DB::Inventory->new->db;
      my $dbh = $db->dbh;
      my $default_warehouse_id;
      my $default_bin_id;
      my @parts_ids;
      my @transfers;
      my @errors;
      my $qty;
      my $stock_out;
      require SL::WH;
      require SL::IS;
      require SL::DB::DeliveryOrderItemsStock;
      foreach my $item (@{$delivery_order_items}) {
        my ($err, $wh_id, $bin_id) = IS->_determine_wh_and_bin($dbh, $::instance_conf,
                                                           $item->{parts_id},
                                                           $item->{qty},
                                                           $item->{unit}
                                                           );
        if (!@{ $err } && $wh_id && $bin_id) {
          my $delivery_order_items_stock = SL::DB::DeliveryOrderItemsStock->new;
          $delivery_order_items_stock->assign_attributes (
            'delivery_order_item_id'  => $item->{id},
            'qty'                     => $item->{qty},
            'unit'                    => $item->{unit},
            'warehouse_id'            => $wh_id,
            'bin_id'                  => $bin_id,
          );
          $delivery_order_items_stock->save;

          my ($trans_id) = selectrow_query($::form, $::form->get_standard_dbh, qq|SELECT nextval('id')|);
          my $wh_transfer = SL::DB::Inventory->new;
          $wh_transfer->assign_attributes (
            'trans_id'                      => $trans_id,
            'employee'                      => $employee->{id},
            'bestbefore'                    => undef,
            'chargenumber'                  => '',
            'shippingdate'                  => DateTime->today,
            'delivery_order_items_stock_id' => $delivery_order_items_stock->id,
            'project_id'                    => '',
            'parts_id'                      => $item->{parts_id},
            'qty'                           => $item->{qty} * -1,
            'trans_type_id'              => 889,#hardcodiert
            'warehouse_id'                  => $wh_id,
            'bin_id'                        => $bin_id,
            'comment'                       => $main::locale->text("Default transfer delivery order"),
            'oe_id'                         => $delivery_order->{id},
          );
          $wh_transfer->save;
        }
        push @errors, @{ $err };
      }
      if (!@errors) {
          $delivery_order->delivered(1);
          $delivery_order->save;
      }
    }
  }
}

sub run {
  my ($self, $job_obj) = @_;

  $self->{job_obj}         = $job_obj;
  $self->create_order;

  $job_obj->set_data(status => DONE())->save;

  return 1;
}
1;
