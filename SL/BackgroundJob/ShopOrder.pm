package SL::BackgroundJob::ShopOrder;

use strict;
use warnings;

use parent qw(SL::BackgroundJob::Base);

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
#     transdate                   => $today,
#     num_order_created           => 0,
#     num_delivery_order_created  => 0,
#     conversation_errors         => [ { id => 603 , item => 2, message => "Out of stock"}, ],
# };
#

sub create_order {
  my ( $self ) = @_;
  $::lxdebug->dump(0, 'WH: ', \$self);
  my $job_obj = $self->{job_obj};
}

sub create_delivery_order {
  my ( $self ) = @_;
}
1;
