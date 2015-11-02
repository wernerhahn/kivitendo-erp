package SL::BackgroundJob::ShopOrder;

use strict;
use warnings;

use parent qw(SL::BackgroundJob::Base);

#
# Workflow Dreschflegel Shoporder import -> wo geht automatisch nach Order(Auftrag) und DeliveryOrder (Lieferschein) mit auslagern transferieren
#

use SL::DB::ShopOrder;
use SL::DB::Order;
use SL::DB::DeliveryOrder;
use SL::DB::Inventory;

use constant WAITING_FOR_EXECUTION        => 0;
use constant CONVERTING_TO_DELIVERY_ORDER => 1;
use constant DONE                         => 5;

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
  $::lxdebug->dump(0, 'WH: Taskmanager: ', \$self);
  my $job_obj = $self->{job_obj};
  my $db      = $job_obj->db;
  foreach my $shop_order_id (@{ $job_obj->data_as_hash->{shop_order_record_ids} }) {
    #my $shop_order = SL::DB::Manager::ShopOrder->find_by( id => $shop_order_id );
    my $shop_order = SL::DB::ShopOrder->new(id => $shop_order_id)->load;
    die "can't find shoporder with id $shop_order_id" unless $shop_order;
    my $customer = SL::DB::Manager::Customer->find_by(id => $::form->{customer});
    die "Can't find customer" unless $customer;
    my $employee = SL::DB::Manager::Employee->current;
    my $items = SL::DB::Manager->ShopOrderItem->get_all( where => [shop_order_id => $shop_order_id] );
    $::lxdebug->dump(0, 'WH: CREATE:I ', \$shop_order);
    $::lxdebug->dump(0, 'WH: CREATE:II ', \$items);

  }
}

sub create_delivery_order {
  my ( $self ) = @_;
}

sub run {
  my ($self, $job_obj) = @_;

  $self->{job_obj}         = $job_obj;
  $self->create_order;

  $job_obj->set_data(status => DONE())->save;

  return 1;
}
1;
