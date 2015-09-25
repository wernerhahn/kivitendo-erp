use strict;
use Test::More;

use lib 't';
use Support::TestSetup;
use Carp;
use Test::Exception;
use Data::Dumper;
use SL::DB::Shop;
use SL::DB::Part;
use SL::DB::Order;
use SL::DB::OrderItem;
use SL::DB::ShopPart;
use SL::DB::Pricegroup;
use SL::DB::Price;
use SL::DB::ShopOrderItem;
use SL::DB::ShopOrder;
use SL::Shop;
use SL::ShopConnector::ALL;
use Rose::DB::Object::Helpers qw(clone_and_reset);
use List::Util qw(sum);
use DateTime;

# use SL::DBUtils;

use utf8;

Support::TestSetup::login();

clear_up();

my $VERBOSE = 0;
my $DEBUG   = 0;
my $DANCER  = 0; # activate the mock shop


# initialise data:
my $pricegroup_a = SL::DB::Pricegroup->new(pricegroup => "typ a")->save;
my $pricegroup_b = SL::DB::Pricegroup->new(pricegroup => "typ b")->save;
my $pricegroup_c = SL::DB::Pricegroup->new(pricegroup => "typ c")->save;

# all parts and shop_parts will be updated with roughly this mtime due to trigger
my $reference_time = DateTime->now;

# all parts are created a day earlier
my $part_itime = $reference_time->clone->subtract(days => 1);

my $buchungsgruppe  = SL::DB::Manager::Buchungsgruppe->find_by(description => 'Standard 19%');
my $unit            = SL::DB::Manager::Unit->find_by(name => 'Stck');
my $part            = SL::DB::Part->new(
                                         partnumber         => 'T4254',
                                         description        => 'Fourty-two fifty-four',
                                         lastcost           => 1.93,
                                         sellprice          => 2.34,
                                         buchungsgruppen_id => $buchungsgruppe->id,
                                         unit               => $unit->name,
                                         shop               => 1,
                                         itime              => $part_itime,
                                       )->save;

my $part2 = $part->clone_and_reset;
$part2->description("part 2");
$part2->save;

my $baseprice1 = "12.34";
my $baseprice2 = "3.33";
foreach my $pg ( $pricegroup_a, $pricegroup_b, $pricegroup_c ) {
  SL::DB::Price->new( parts_id => $part->id,  pricegroup => $pg, price => $baseprice1)->save;
  SL::DB::Price->new( parts_id => $part2->id, pricegroup => $pg, price => $baseprice2)->save;
  $baseprice1 += 1;
  $baseprice2 += 1;
};
# foreach my $p ( $part, $part2 ) {
#     foreach ( $p->prices ) {
#         printf("%s: %s ( %s ) \n", $_->pricegroup->pricegroup, $_->price, $p->displayable_name);
#     };
# };


my $employee    = SL::DB::Manager::Employee->current;
my $taxzone     = SL::DB::Manager::TaxZone->find_by( description => 'Inland') || croak "No taxzone";
my $currency_id = $::instance_conf->get_currency_id;
my $customer    = SL::DB::Customer->new(
                                         name        => 'Flintstone',
                                         currency_id => $currency_id,
                                         taxzone_id  => $taxzone->id,
                                         email       => 'fred@flintstone.org',
                                         zipcode     => '12345',
                                       )->save;

my @pricesources = qw(sellprice lastcost listprice);
push(@pricesources, map { $_->id } @{ SL::DB::Manager::Pricegroup->get_all });

my $config1 = SL::DB::Shop->new( description => 'TestShop',
                                 connector   => 'xtcommerce',
                                 pricetype   => 'netto',
                                 url         => 'http://localhost',
                                 port        => '3000',
                                 login       => 'foo',
                                 password    => 'bar',
                                 obsolete    => 0,
                               )->save;
my $config2 = SL::DB::Shop->new( description => 'TestShop 2',
                                 connector   => 'xtcommerce',
                                 pricetype   => 'brutto',
                                 url         => 'http://localhost',
                                 port        => '3000',
                                 login       => 'foo',
                                 password    => 'bar',
                                 obsolete    => 0,
                               )->save;

my $shop       = SL::Shop->new( config => $config1 );
my $shop2      = SL::Shop->new( config => $config2 );
my $result     = $shop->connector->get_order('1') if $DANCER;
my $new_orders = $shop->connector->get_new_orders if $DANCER;

# printf("order %s has amount %s\n", $result->{ordnumber}, $result->{amount});

is( $config1->connector,  'xtcommerce', 'created shop object');
is( $shop->config->connector,  'xtcommerce', 'created SL::Shop');
is( $result->{amount}, '12.34' , 'fetched amount for order 1234') if $DANCER;
is( $shop->connector->url, "http://localhost:3000", 'connector url');
is( scalar keys %{ $new_orders } , 2, '2 new orders') if $DANCER;

my $active_shops = SL::DB::Manager::Shop->get_all(query => [ obsolete => 0 ]);
foreach my $shop_config ( @{ $active_shops } ) {
  my $shop = SL::Shop->new( config => $shop_config );
  my $new_orders = $shop->connector->get_new_orders if $DANCER;
  # printf("Shop \"%s\" has %s new orders\n", $shop->config->description, scalar keys %{ $new_orders });
};

# create some orders for shop $shop
my %shop_customer_fred = (   customer_firstname => 'Fred',
                             customer_lastname => 'Flintstone',
                             customer_email => 'fred@flintstones.org',
                             customer_zipcode => '12345',
                         );
my %shop_customer_barney = ( customer_firstname => 'Barney',
                             customer_lastname => 'Rubble',
                             customer_email => 'b.rubble@boulder.org',
                             customer_zipcode => '12345',
                           );

# create ShopOrders, 9 Freds and 1 Barney
foreach my $i ( 1 .. 10 ) {
    my $so = SL::DB::ShopOrder->new( shop_ordernumber     => $i,
                                     shop_trans_id        => $i,
                                     shop_customer_number => 15,
                                     host                 => $shop->config->description,
                                     order_date           => DateTime->today_local,
                                     $i == 5 ? %shop_customer_barney : %shop_customer_fred,
                                   );
    my $soi = SL::DB::ShopOrderItem->new( partnumber    => $part->partnumber,
                                          price         => (12.34 + $i),
                                          quantity      => '2',
                                          shop_trans_id => $i,
                                          description   => $part->description,
                                        );
    $so->add_shop_order_items($soi);
    $so->amount( $soi->price * $soi->quantity );
    $so->save;
};

my $shoporder = SL::DB::Manager::ShopOrder->get_first();

my $order = $shoporder->convert_to_sales_order(customer => $customer, employee => $employee);
$order->save;
is( $order->amount, $shoporder->amount, 'Shoporder and converted oe have same amount');

my $dt2 = $reference_time->clone->add(hours => 1); #->add(years => 1);

my $s1p1 = SL::DB::ShopPart->new( part => $part,
                                  shop             => $config1,
                                  shop_description => 'marketing speak for part 1 in shop 1',
                                  last_update      => $reference_time,
                                  active           => 1,
                                  itime            => $part_itime,
                                )->save;

my $s1p2 = SL::DB::ShopPart->new( part => $part2,
                                  shop => $config1,
                                  shop_description => 'marketing speak for part 2 in shop 1',
                                  itime => $part_itime,
                                )->save;

my $s2p1 = SL::DB::ShopPart->new( part => $part,
                                  shop => $config2,
                                  last_update => $dt2,
                                  shop_description => 'marketing speak for part 1 in shop 2',
                                  itime => $part_itime,
                                )->save;

my $number_of_active_shops = $part->find_shop_parts( { active => 1 } );
# my $number_of_active_shops = $part->find_shop_parts( { shop_id => $config1->id, active => 1 } );
is( scalar @{ $number_of_active_shops } , 1, 'part 1 is active in 1 shop');

is( scalar @{ $part2->find_shop_parts( { active => 1 } ) }, 0, 'part2 isn\'t active in any shop');

my $shop_parts = $part->shop_parts;
is( scalar @{ $part->shop_parts } , 2, 'part 1 appears in 2 shops');

is( scalar @{ $shop->config->shop_parts  } , 2, 'shop 1 has 2 parts');

my $active_shop_parts = $shop->config->find_shop_parts( { active => 1 } );
is( scalar @{ $active_shop_parts  } , 1, 'shop 1 has 1 active part');

is( scalar @{ $shop2->config->shop_parts } , 1, 'shop 2 has 1 part');

$active_shop_parts = $shop2->config->find_shop_parts( { active => 1 } );
is( scalar @{ $active_shop_parts  } , 0, 'shop 2 has no active parts');

# debug_on();
# set part1 active in shop2
# because of constraint there can only be one match
my ($shop_part) =  $part->find_shop_parts( { shop_id => $shop2->config->id } );
$shop_part->active(1);
$shop_part->save(changes_only =>1);
$shop_part->load;

diag("activated part " . $shop_part->part->displayable_name . " in shop " . $shop_part->shop->description);
# print "shop_part was last changed: " . $shop_part->mtime  . "\n";

$active_shop_parts = $shop2->config->find_shop_parts( { active => 1 } );
is( scalar @{ $active_shop_parts  } , 1, 'shop 2 now has 1 active part');

# debug_on();
# 1 hour after first part: only s1p1
my $dt_now = $reference_time->clone->subtract(hours => 1); #->add(years => 1);
my $updatable_parts = $shop->updatable_parts($dt_now);
diag("parts to be updated at " . $dt_now . " :");
foreach ( @{$updatable_parts} ) {
  diag(sprintf("  %s: %s\n", $_->shop->description, $_->part->displayable_name));
  # print ". last update: " . $dt_now  . "\n";
  # print "      part itime     : " . $_->part->itime . "\n";
  # print "      part mtime     : " . $_->part->mtime . "\n";
  # print "      shop_part itime: " . $_->itime . "\n";
  # print "      shop_part mtime: " . $_->mtime . "\n";
};
# 3 hours after first part: s1p1 and s2p1
$dt_now = $reference_time->clone->add(hours => 3); #->add(years => 1);
$updatable_parts = $shop->updatable_parts($dt_now);
diag("parts to be updated at " . $dt_now . " :");
foreach ( @{$updatable_parts} ) {
  diag(sprintf(" %s: %s\n", $_->shop->description, $_->part->displayable_name));
  # print "  last update: " . $dt_now  . "\n";
  # print "      part itime     : " . $_->part->itime . "\n";
  # print "      part mtime     : " . $_->part->mtime . "\n";
  # print "      shop_part itime: " . $_->itime . "\n";
  # print "      shop_part mtime: " . $_->mtime . "\n";
};
# debug_off();

done_testing;

# disable final clear_up while developing
# done_testing(21);
# clear_up();

sub clear_up {
  # remove all transactions after test has run
  SL::DB::Manager::Price->delete_all         ( all => 1)  ;
  SL::DB::Manager::Pricegroup->delete_all    ( all => 1)  ;
  SL::DB::Manager::OrderItem->delete_all     ( all => 1)  ;
  SL::DB::Manager::Order->delete_all         ( all => 1)  ;
  SL::DB::Manager::ShopPart->delete_all      ( all => 1)  ;
  SL::DB::Manager::Part->delete_all          ( all => 1)  ;
  SL::DB::Manager::ShopOrderItem->delete_all ( all => 1)  ;
  SL::DB::Manager::ShopOrder->delete_all     ( all => 1)  ;
  SL::DB::Manager::Customer->delete_all      ( all => 1)  ;
  SL::DB::Manager::Shop->delete_all          ( all => 1)  ;
};

sub debug_on {
  return unless $DEBUG;
  $Rose::DB::Object::Debug = 1;
  $Rose::DB::Object::Manager::Debug = 1;
};
sub debug_off {
  $Rose::DB::Object::Debug = 0;
  $Rose::DB::Object::Manager::Debug = 0;
};

1;
