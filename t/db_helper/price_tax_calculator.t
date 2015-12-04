use Test::More;

use strict;

use lib 't';
use utf8;

use Carp;
use Data::Dumper;
use List::MoreUtils qw(uniq);
use Support::TestSetup;
use Test::Exception;

use SL::DB::Buchungsgruppe;
use SL::DB::Currency;
use SL::DB::Customer;
use SL::DB::DeliveryOrder;
use SL::DB::Employee;
use SL::DB::Invoice;
use SL::DB::Order;
use SL::DB::Part;
use SL::DB::Unit;
use SL::DB::TaxZone;

my $default_manager;
my ($customer, $currency_id, @parts, $buchungsgruppe, $buchungsgruppe7, $unit, $employee, $tax, $tax7, $taxzone);

sub clear_up {
  SL::DB::Manager::Order->delete_all(all => 1);
  SL::DB::Manager::DeliveryOrder->delete_all(all => 1);
  SL::DB::Manager::Invoice->delete_all(all => 1);
  SL::DB::Manager::Part->delete_all(all => 1);
  SL::DB::Manager::Customer->delete_all(all => 1);
};

sub reset_state {
  my %params = @_;

  $params{$_} ||= {} for qw(buchungsgruppe unit customer part tax);

  clear_up();

  $default_manager = $::lx_office_conf{system}->{default_manager};
  if ($default_manager eq "swiss") {
    $buchungsgruppe  = SL::DB::Manager::Buchungsgruppe->find_by(description => 'Standard 8%', %{ $params{buchungsgruppe} })  || croak "No accounting group for 8\%";
    $buchungsgruppe7 = SL::DB::Manager::Buchungsgruppe->find_by(description => 'Standard 2.5%', %{ $params{buchungsgruppe} })|| croak "No accounting group for 2.5\%";
    $unit            = SL::DB::Manager::Unit->find_by(name => 'kg', %{ $params{unit} })                                      || croak "No unit";
    $employee        = SL::DB::Manager::Employee->current                                                                    || croak "No employee";
    $tax             = SL::DB::Manager::Tax->find_by(taxkey => 2, rate => 0.08, %{ $params{tax} })                           || croak "No tax for 8\%";
    $tax7            = SL::DB::Manager::Tax->find_by(taxkey => 3, rate => 0.025)                                             || croak "No tax for 2.5\%";
    $taxzone         = SL::DB::Manager::TaxZone->find_by( description => 'Schweiz')                                          || croak "No taxzone";
  } else {
    $buchungsgruppe  = SL::DB::Manager::Buchungsgruppe->find_by(description => 'Standard 19%', %{ $params{buchungsgruppe} }) || croak "No accounting group";
    $buchungsgruppe7 = SL::DB::Manager::Buchungsgruppe->find_by(description => 'Standard 7%')                                || croak "No accounting group for 7\%";
    $unit            = SL::DB::Manager::Unit->find_by(name => 'kg', %{ $params{unit} })                                      || croak "No unit";
    $employee        = SL::DB::Manager::Employee->current                                                                    || croak "No employee";
    $tax             = SL::DB::Manager::Tax->find_by(taxkey => 3, rate => 0.19, %{ $params{tax} })                           || croak "No tax";
    $tax7            = SL::DB::Manager::Tax->find_by(taxkey => 2, rate => 0.07)                                              || croak "No tax for 7\%";
    $taxzone         = SL::DB::Manager::TaxZone->find_by( description => 'Inland')                                           || croak "No taxzone";
  }

  $currency_id     = $::instance_conf->get_currency_id;

  $customer     = SL::DB::Customer->new(
    name        => 'Test Customer',
    currency_id => $currency_id,
    taxzone_id  => $taxzone->id,
    %{ $params{customer} }
  )->save;

  @parts = ();
  push @parts, SL::DB::Part->new(
    partnumber         => 'T4254',
    description        => 'Fourty-two fifty-four',
    lastcost           => 1.93,
    sellprice          => 2.34,
    buchungsgruppen_id => $buchungsgruppe->id,
    unit               => $unit->name,
    %{ $params{part1} }
  )->save;

  push @parts, SL::DB::Part->new(
    partnumber         => 'T0815',
    description        => 'Zero EIGHT fifteeN @ 7%',
    lastcost           => 5.473,
    sellprice          => 9.714,
    buchungsgruppen_id => $buchungsgruppe7->id,
    unit               => $unit->name,
    %{ $params{part2} }
  )->save;
}

sub new_invoice {
  my %params  = @_;

  return SL::DB::Invoice->new(
    customer_id => $customer->id,
    currency_id => $currency_id,
    employee_id => $employee->id,
    salesman_id => $employee->id,
    gldate      => DateTime->today_local->to_kivitendo,
    taxzone_id  => $taxzone->id,
    transdate   => DateTime->today_local->to_kivitendo,
    invoice     => 1,
    type        => 'invoice',
    %params,
  );
}

sub new_item {
  my (%params) = @_;

  my $part = delete($params{part}) || $parts[0];

  return SL::DB::InvoiceItem->new(
    parts_id    => $part->id,
    lastcost    => $part->lastcost,
    sellprice   => $part->sellprice,
    description => $part->description,
    unit        => $part->unit,
    %params,
  );
}

sub test_default_invoice_one_item_19_tax_not_included() {
  reset_state();

  my $item    = new_item(qty => 2.5);
  my $invoice = new_invoice(
    taxincluded  => 0,
    invoiceitems => [ $item ],
  );

  my $taxkey = $item->part->get_taxkey(date => DateTime->today_local, is_sales => 1, taxzone => $invoice->taxzone_id);

  # sellprice 2.34 * qty 2.5 = 5.85
  # 19%(5.85) = 1.1115; rounded = 1.11             # 8%(5.85) = 0.468; rounded = 0.47
  # total rounded = 6.96                           # total rounded = 6.32

  # lastcost 1.93 * qty 2.5 = 4.825; rounded 4.83
  # line marge_total = 1.02
  # line marge_percent = 17.4358974358974

  my $title = $default_manager eq "swiss" ? 'default invoice, one item, 8% tax not included' : 'default invoice, one item, 19% tax not included';
  my %data  = $invoice->calculate_prices_and_taxes;

  is($item->marge_total,        1.02,             "${title}: item marge_total");
  is($item->marge_percent,      17.4358974358974, "${title}: item marge_percent");
  is($item->marge_price_factor, 1,                "${title}: item marge_price_factor");

  is($invoice->netamount,       5.85,             "${title}: netamount");
  if ($default_manager eq "swiss") {
    is($invoice->amount,        6.32,             "${title}: amount");
  } else {
    is($invoice->amount,        6.96,             "${title}: amount");
  }
  is($invoice->marge_total,     1.02,             "${title}: marge_total");
  is($invoice->marge_percent,   17.4358974358974, "${title}: marge_percent");

  is_deeply(\%data, {
    allocated                                    => {},
    amounts                                      => {
      $buchungsgruppe->income_accno_id($taxzone) => {
        amount                                   => 5.85,
        tax_id                                   => $tax->id,
        taxkey                                   => $default_manager eq "swiss" ? 2 : 3,
      },
    },
    amounts_cogs                                 => {},
    assembly_items                               => [
      [],
    ],
    exchangerate                                 => 1,
    taxes                                        => {
      $tax->chart_id                             => $default_manager eq "swiss" ? 0.47 : 1.11,
    },
    items                                        => [
      { linetotal                                => 5.85,
        linetotal_cost                           => 4.83,
        sellprice                                => 2.34,
        tax_amount                               => $default_manager eq "swiss" ? 0.468 : 1.1115,
        taxkey_id                                => $taxkey->id,
      },
    ],
  }, "${title}: calculated data");
}

sub test_default_invoice_two_items_19_7_tax_not_included() {
  reset_state();

  my $item1   = new_item(qty => 2.5);
  my $item2   = new_item(qty => 1.2, part => $parts[1]);
  my $invoice = new_invoice(
    taxincluded  => 0,
    invoiceitems => [ $item1, $item2 ],
  );

  my $taxkey1 = $item1->part->get_taxkey(date => DateTime->today_local, is_sales => 1, taxzone => $invoice->taxzone_id);
  my $taxkey2 = $item2->part->get_taxkey(date => DateTime->today_local, is_sales => 1, taxzone => $invoice->taxzone_id);

  # item 1:
  # sellprice 2.34 * qty 2.5 = 5.85
  # 19%(5.85) = 1.1115; rounded = 1.11                # 8%(5.85) = 0.468; rounded = 0.47
  # total rounded = 6.96                              # total rounded = 6.32

  # lastcost 1.93 * qty 2.5 = 4.825; rounded 4.83
  # line marge_total = 1.02
  # line marge_percent = 17.4358974358974

  # item 2:
  # sellprice 9.714 * qty 1.2 = 11.6568 rounded 11.66
  # 7%(11.6568) = 0.815976; rounded = 0.82            # 2.5%(11.6568) = 0.29142; rounded = 0.29
  # total rounded = 12.48                             # total rounded = 11.95

  # lastcost 5.473 * qty 1.2 = 6.5676; rounded 6.57
  # line marge_total = 5.09
  # line marge_percent = 43.6535162950257

  my $title = $default_manager eq "swiss" ? 'default invoice, two item, 8/2.5% tax not included' : 'default invoice, two item, 19/7% tax not included';
  my %data  = $invoice->calculate_prices_and_taxes;

  is($item1->marge_total,        1.02,             "${title}: item1 marge_total");
  is($item1->marge_percent,      17.4358974358974, "${title}: item1 marge_percent");
  is($item1->marge_price_factor, 1,                "${title}: item1 marge_price_factor");

  is($item2->marge_total,        5.09,             "${title}: item2 marge_total");
  is($item2->marge_percent,      43.6535162950257, "${title}: item2 marge_percent");
  is($item2->marge_price_factor, 1,                "${title}: item2 marge_price_factor");

  is($invoice->netamount,        5.85 + 11.66,     "${title}: netamount");
  if ($default_manager eq "swiss") {
    is($invoice->amount,         6.32 + 11.95,     "${title}: amount");
  } else {
    is($invoice->amount,         6.96 + 12.48,     "${title}: amount");
  }
  is($invoice->marge_total,      1.02 + 5.09,      "${title}: marge_total");
  is($invoice->marge_percent,    34.8943460879497, "${title}: marge_percent");

  is_deeply(\%data, {
    allocated                                     => {},
    amounts                                       => {
      $buchungsgruppe->income_accno_id($taxzone)  => {
        amount                                    => 5.85,
        tax_id                                    => $tax->id,
        taxkey                                    => $default_manager eq "swiss" ? 2 : 3,
      },
      $buchungsgruppe7->income_accno_id($taxzone) => {
        amount                                    => 11.66,
        tax_id                                    => $tax7->id,
        taxkey                                    => $default_manager eq "swiss" ? 3 : 2,
      },
    },
    amounts_cogs                                  => {},
    assembly_items                                => [
      [], [],
    ],
    exchangerate                                  => 1,
    taxes                                         => {
      $tax->chart_id                              => $default_manager eq "swiss" ? 0.47 : 1.11,
      $tax7->chart_id                             => $default_manager eq "swiss" ? 0.29 : 0.82,
    },
    items                                        => [
      { linetotal                                => 5.85,
        linetotal_cost                           => 4.83,
        sellprice                                => 2.34,
        tax_amount                               => $default_manager eq "swiss" ? 0.468 : 1.1115,
        taxkey_id                                => $taxkey1->id,
      },
      { linetotal                                => 11.66,
        linetotal_cost                           => 6.57,
        sellprice                                => 9.714,
        tax_amount                               => $default_manager eq "swiss" ? 0.2915 : 0.8162,
        taxkey_id                                => $taxkey2->id,
      },
    ],
  }, "${title}: calculated data");
}

sub test_default_invoice_three_items_sellprice_rounding_discount() {
  reset_state();

  my $item1   = new_item(qty => 1, sellprice => 5.55, discount => .05);
  my $item2   = new_item(qty => 1, sellprice => 5.50, discount => .05);
  my $item3   = new_item(qty => 1, sellprice => 5.00, discount => .05);
  my $invoice = new_invoice(
    taxincluded  => 0,
    invoiceitems => [ $item1, $item2, $item3 ],
  );

  my %taxkeys = map { ($_->id => $_->get_taxkey(date => DateTime->today_local, is_sales => 1, taxzone => $invoice->taxzone_id)) } uniq map { $_->part } ($item1, $item2, $item3);

  # this is how price_tax_calculator is implemented. It differs from
  # the way sales_order / invoice - forms are calculating:
  # linetotal = sellprice 5.55 * qty 1 * (1 - 0.05) = 5.2725; rounded 5.27
  # linetotal = sellprice 5.50 * qty 1 * (1 - 0.05) = 5.225 rounded 5.23
  # linetotal = sellprice 5.00 * qty 1 * (1 - 0.05) = 4.75; rounded 4.75
  # ...

  # item 1:
  # discount = sellprice 5.55 * discount (0.05) = 0.2775; rounded 0.28
  # sellprice = sellprice 5.55 - discount 0.28 = 5.27; rounded 5.27
  # linetotal = sellprice 5.27 * qty 1 = 5.27; rounded 5.27
  # 19%(5.27) = 1.0013; rounded = 1.00           # 8%(5.27) = 0.4216; rounded = 0.42
  # total rounded = 6.27                         # total rounded = 5.69

  # lastcost 1.93 * qty 1 = 1.93; rounded 1.93
  # line marge_total = 3.34
  # line marge_percent = 63.3776091081594

  # item 2:
  # discount = sellprice 5.50 * discount 0.05 = 0.275; rounded 0.28
  # sellprice = sellprice 5.50 - discount 0.28 = 5.22; rounded 5.22
  # linetotal = sellprice 5.22 * qty 1 = 5.22; rounded 5.22
  # 19%(5.22) = 0.9918; rounded = 0.99           # 8%(5.22) = 0.4176; rounded = 0.42
  # total rounded = 6.21                         # total rounded = 5.64

  # lastcost 1.93 * qty 1 = 1.93; rounded 1.93
  # line marge_total = 5.22 - 1.93 = 3.29
  # line marge_percent = 3.29/5.22 = 0.630268199233716

  # item 3:
  # discount = sellprice 5.00 * discount 0.25 = 0.25; rounded 0.25
  # sellprice = sellprice 5.00 - discount 0.25 = 4.75; rounded 4.75
  # linetotal = sellprice 4.75 * qty 1 = 4.75; rounded 4.75
  # 19%(4.75) = 0.9025; rounded = 0.90           # 8%(4.75) = 0.38; rounded = 0.38
  # total rounded = 5.65                         # total rounded = 5.13

  # lastcost 1.93 * qty 1 = 1.93; rounded 1.93
  # line marge_total = 2.82
  # line marge_percent = 59.3684210526316

  my $title = 'default invoice, three items, sellprice, rounding, discount';
  my %data  = $invoice->calculate_prices_and_taxes;

  is($item1->marge_total,        3.34,               "${title}: item1 marge_total");
  is($item1->marge_percent,      63.3776091081594,   "${title}: item1 marge_percent");
  is($item1->marge_price_factor, 1,                  "${title}: item1 marge_price_factor");

  is($item2->marge_total,        3.29,               "${title}: item2 marge_total");
  is($item2->marge_percent,      63.0268199233716,   "${title}: item2 marge_percent");
  is($item2->marge_price_factor, 1,                  "${title}: item2 marge_price_factor");

  is($item3->marge_total,        2.82,               "${title}: item3 marge_total");
  is($item3->marge_percent,      59.3684210526316,   "${title}: item3 marge_percent");
  is($item3->marge_price_factor, 1,                  "${title}: item3 marge_price_factor");

  is($invoice->netamount,        5.27 + 5.22 + 4.75, "${title}: netamount");

  # 6.27 + 6.21 + 5.65 = 18.13                         # 5.69 + 5.64 + 5.13 = 16.46
  # 1.19*(5.27 + 5.22 + 4.75) = 18.1356; rounded 18.14 # 0.08*(15.24) = 1.2192; rounded 1.22
  #is($invoice->amount,           6.27 + 6.21 + 5.65, "${title}: amount");
  if ($default_manager eq "swiss") {
    is($invoice->amount,         16.46,              "${title}: amount");
  } else {
    is($invoice->amount,         18.14,              "${title}: amount");
  }

  is($invoice->marge_total,      3.34 + 3.29 + 2.82, "${title}: marge_total");
  is($invoice->marge_percent,    62.007874015748,    "${title}: marge_percent");

  is_deeply(\%data, {
    allocated                                    => {},
    amounts                                      => {
      $buchungsgruppe->income_accno_id($taxzone) => {
        amount                                   => 15.24,
        tax_id                                   => $tax->id,
        taxkey                                   => $default_manager eq "swiss" ? 2 : 3,
      },
    },
    amounts_cogs                                 => {},
    assembly_items                               => [
      [], [], [],
    ],
    exchangerate                                 => 1,
    taxes                                        => {
      $tax->chart_id                             => $default_manager eq "swiss" ? 1.22 : 2.9,
    },
    items                                        => [
      { linetotal                                => 5.27,
        linetotal_cost                           => 1.93,
        sellprice                                => 5.27,
        tax_amount                               => $default_manager eq "swiss" ? 0.4216 : 1.0013,
        taxkey_id                                => $taxkeys{$item1->parts_id}->id,
      },
      { linetotal                                => 5.22,
        linetotal_cost                           => 1.93,
        sellprice                                => 5.22,
        tax_amount                               => $default_manager eq "swiss" ? 0.4176 : 0.9918,
        taxkey_id                                => $taxkeys{$item2->parts_id}->id,
      },
      { linetotal                                => 4.75,
        linetotal_cost                           => 1.93,
        sellprice                                => 4.75,
        tax_amount                               => $default_manager eq "swiss" ? 0.38 : 0.9025,
        taxkey_id                                => $taxkeys{$item3->parts_id}->id,
      }
    ],
  }, "${title}: calculated data");
}

Support::TestSetup::login();

test_default_invoice_one_item_19_tax_not_included();
test_default_invoice_two_items_19_7_tax_not_included();
test_default_invoice_three_items_sellprice_rounding_discount();

clear_up();
done_testing();
