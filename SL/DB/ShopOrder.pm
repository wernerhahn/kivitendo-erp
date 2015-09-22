# This file has been auto-generated only because it didn't exist.
# Feel free to modify it at will; it will not be overwritten automatically.

package SL::DB::ShopOrder;

use strict;

use SL::DB::MetaSetup::ShopOrder;
use SL::DB::Manager::ShopOrder;
use SL::DB::Helper::LinkedRecords;

__PACKAGE__->meta->add_relationships(
  shop_order_items => {
    class      => 'SL::DB::ShopOrderItem',
    column_map => { id => 'shop_order_id' },
    type       => 'one to many',
  },
);

__PACKAGE__->meta->initialize;

sub convert_to_sales_order {
  my ($self, %params) = @_;

  my $customer = $params{customer};
  my $employee = $params{employee};
  die unless ref($customer) eq 'SL::DB::Customer';
  die unless ref($employee) eq 'SL::DB::Employee';

  require SL::DB::Order;
  require SL::DB::OrderItem;
  require SL::DB::Part;
  require SL::DB::Shipto;

  my @order_items;
  foreach my $items (@{$self->shop_order_items}) {
    my $item = SL::DB::OrderItem->new;
    my $part = SL::DB::Manager::Part->find_by( partnumber => $items->{partnumber} );

    $item->assign_attributes(
        parts_id        => $part->id,
        description     => $items->description,
        qty             => $items->quantity,
        sellprice       => $items->price,
        unit            => $part->unit,
        );
    push(@order_items,$item);
  }

  my $shipto_id;
  if ($self->{billing_firstname} ne $self->{delivery_firstname} || $self->{billing_lastname} ne $self->{delivery_lastname} || $self->{billing_city} ne $self->{delivery_city} || $self->{billing_street} ne $self->{delivery_street}) {
    if(my $address = SL::DB::Manager::Shipto->find_by( shiptoname          => $self->{delivery_firstname} . " " . $self->{delivery_lastname}, 
                                                        shiptostreet        => $self->{delivery_street},
                                                        shiptocity          => $self->{delivery_city},
                                                      )) {
      $shipto_id = $address->{shipto_id};
    } else {
      my $gender = $self->{delivery_greeting} eq "Frau" ? 'f' : 'm';
      my $deliveryaddress = SL::DB::Shipto->new;
      $deliveryaddress->assign_attributes(
        shiptoname      => $self->{delivery_firstname} . " " . $self->{delivery_lastname},
        shiptocp_gender => $gender,
        shiptostreet    => $self->{delivery_street},
        shiptozipcode   => $self->{delivery_zipcode},
        shiptocity      => $self->{delivery_city},
        shiptocountry   => $self->{delivery_country},
        trans_id        => $customer->id,   # ????
        module          => "CT",
      );
      $deliveryaddress->save;
      $shipto_id = $deliveryaddress->{shipto_id};
    }
  }

  my $order = SL::DB::Order->new(
                  amount                  => $self->amount,
                  cusordnumber            => $self->shop_id,
                  customer_id             => $customer->id,
                  shipto_id               => $shipto_id,
                  orderitems              => [ @order_items ],
                  employee_id             => $employee->id,
                  intnotes                => $self->{shop_customer_comment},
                  salesman_id             => $employee->id,
                  taxincluded             => 1,   # TODO: make variable
                  taxzone_id              => $customer->taxzone_id,
                  currency_id             => $customer->currency_id,
                  transaction_description => 'Shop Import',
                  transdate               => DateTime->today_local
                );
  # $order->save;
  return $order;
};

1;
