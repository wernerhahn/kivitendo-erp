use strict;
use Test::More;

use lib 't';
use Support::TestSetup;
use Carp;
use Test::Exception;

no warnings qw(qw);

# this test tests the functions calculate_arap and calculate_tax in SL/Form.pm
# calculate_arap is used for post_invoice in AR and AP
# calculate_tax is used in calculate_arap as well as update in ar/ap/gl and post_transaction in gl

my $default_manager;
my ($ar_tax_19, $ar_tax_7,$ar_tax_0);
my $config = {};

sub reset_state {
  my %params = @_;

  $params{$_} ||= {} for qw(ar_tax_19 ar_tax_7 ar_tax_0 );

  # delete rowcount lines in form, would be better to reset form completely
  for my $hv ( 1 .. 10 ) {
      foreach my $type ( qw(amount tax tax_id tax_chart) ) {
          delete $::form{"$type\_$hv"};
      };
  };

  $default_manager = $::lx_office_conf{system}->{default_manager};
  if ($default_manager eq "swiss") {
    $ar_tax_19 = SL::DB::Manager::Tax->find_by(taxkey => 2, rate => 0.08, %{ $params{ar_tax_19} })  || croak "No 8% tax";
    $ar_tax_7  = SL::DB::Manager::Tax->find_by(taxkey => 3, rate => 0.025,  %{ $params{ar_tax_7} }) || croak "No 2.5% tax";
    $config->{numberformat} = "1'000.00";

  } else {
    $ar_tax_19 = SL::DB::Manager::Tax->find_by(taxkey => 3, rate => 0.19,  %{ $params{ar_tax_19} }) || croak "No 19% tax";
    $ar_tax_7  = SL::DB::Manager::Tax->find_by(taxkey => 2, rate => 0.07,  %{ $params{ar_tax_7} })  || croak "No 7% tax";
    $config->{numberformat} = '1.000,00';
  }
  $ar_tax_0  = SL::DB::Manager::Tax->find_by(taxkey => 0, rate => 0.00,    %{ $params{ar_tax_0} })  || croak "No 0% tax";

};

sub arap_test {
  my ($testcase) = @_;

  reset_state;

  # values from testcase
  $::form->{taxincluded}     = $testcase->{taxincluded};
  $::form->{currency}        = $testcase->{currency};
  $::form->{rowcount}        = scalar @{$testcase->{lines}};

  # parse exchangerate, because it was added in the same numberformat as the
  # other amounts in the testcases
  $testcase->{exchangerate}    = $::form->parse_amount(\%::myconfig, $testcase->{exchangerate});

  foreach my $a ( 1 .. scalar @{$testcase->{lines}} ) {
    my ($taxrate, $form_amount, $netamount, $taxamount, $totalamount) = @{ @{ $testcase->{lines} }[$a-1] };
    my $tax;
    if ( $taxrate eq ($default_manager eq "swiss" ? '8' : '19' )) {
        $tax = $ar_tax_19;
    } elsif ( $taxrate eq ($default_manager eq "swiss" ? '2,5' : '7' )) {
        $tax = $ar_tax_7;
    } elsif ( $taxrate eq '0' ) {
        $tax = $ar_tax_0;
    } else {
        croak "illegal taxrate $taxrate";
    };

    $::form->{"amount_$a"}   = $form_amount;
    $::form->{"tax_$a"}      = $taxamount;  # tax according to UI, will recalculate anyway?
    $::form->{"taxchart_$a"} = $tax->id . '--' . $tax->rate;

  };

  # calculate totals using lines in $::form
  ($::form->{netamount},$::form->{total_tax},$::form->{amount}) = $::form->calculate_arap($testcase->{'buysell'}, $::form->{taxincluded}, $testcase->{'exchangerate'});

  # create tests comparing calculated and expected values
  is($::form->format_amount(\%::myconfig , $::form->{total_tax} , 2) , $testcase->{'total_taxamount'} , "total tax   = $testcase->{'total_taxamount'}");
  is($::form->format_amount(\%::myconfig , $::form->{netamount} , 2) , $testcase->{'total_netamount'} , "netamount   = $testcase->{'total_netamount'}");
  is($::form->format_amount(\%::myconfig , $::form->{amount}    , 2) , $testcase->{'total_amount'}    , "totalamount = $testcase->{'total_amount'}");
  is($::form->{taxincluded}, $testcase->{'taxincluded'}, "taxincluded = $testcase->{'taxincluded'}");

};

sub calculate_tax_test {
  my ($amount, $rate, $taxincluded, $net, $tax, $total, $dec) = @_;
  # amount, rate and taxincluded are the values that we want to calculate with
  # net, tax and total are the values that we expect, dec is the number of decimals we round to

  my ($calculated_net,$calculated_tax) = $::form->calculate_tax($amount,$rate,$taxincluded,$dec);

  is($tax, $calculated_tax, "calculated tax for taxincluded = $taxincluded for net $amount and rate $rate is = $calculated_tax");
  is($calculated_net, $net, "calculated net for taxincluded = $taxincluded for net $amount and rate $rate is = $net");
};

my @testline1;
my @testline2;
my @testline3;
my @testline4;
my @testline5;
my @testline6;
my @testline7;
my @testline8;
my @testline9;
my @testline10;
my @testline11;
my @testline12;
my @testline13;
my @testline14;
my @testline15;
my @testline16;
my @testline17;

sub init_testlines {
  # define the various lines that can be used for the testcases
  # always use positive values for buy/sell, like in the interface
  #                   tax  input   net      tax   total  type
  $default_manager = $::lx_office_conf{system}->{default_manager};
  if ($default_manager eq "swiss") {
    @testline1  = qw(8    51,30   47,50   3,80   51,30  sell);
    @testline2  = qw(8    10,80   10,00   0,80   10,80  sell);
    @testline3  = qw(2,5  13,79   13,45   0,34   10,80  sell);
    @testline4  = qw(8   133,08  133,08  10,65  143,73  sell);
    @testline5  = qw(0   100,00   83,00   0,00   83,00  sell);  # exchangerate of 0,83
    @testline6  = qw(8    51,30   47,50   3,80   51,30   buy);
    @testline7  = qw(8   309,86  309,86  24,79  334,65   buy);
    @testline8  = qw(2,5 124,54  121,50   3,04  124,54   buy);
    @testline9  = qw(2,5 121,49  121,49   3,04  124,53   buy);
    @testline10 = qw(2,5 121,50  121,50   3,05  124,55   buy);
    @testline11 = qw(8    -2,77   -2,77  -0,22   -2,99   buy);
    @testline12 = qw(2,5  12,88   12,88   0,32   13,20   buy);
    @testline13 = qw(8    41,93   41,93   3,35   45,28   buy);
    @testline14 = qw(8    84,65   84,65   6,77   98,42   buy);
    @testline15 = qw(8     8,39    8,39   0,66    9,05   buy);
    @testline16 = qw(8    91,42   84,65   6,77   98,42   buy);
    @testline17 = qw(8     9,06    8,39   0,67    9,06   buy);
  } else {
    @testline1  = qw(19   56,53   47,50   9,03   56,53  sell);
    @testline2  = qw(19   11,90   10,00   1,90   11,90  sell);
    @testline3  = qw( 7   14,39   13,45   0,94   11,90  sell);
    @testline4  = qw(19  133,08  133,08  25,29  158,37  sell);
    @testline5  = qw( 0  100,00   83,00   0,00   83,00  sell);  # exchangerate of 0,83
    @testline6  = qw(19   56,53   47,50   9,03   56,53   buy);
    @testline7  = qw(19  309,86  309,86  58,87  368,73   buy);
    @testline8  = qw( 7  130,00  121,50   8,50  130,00   buy);
    @testline9  = qw( 7  121,49  121,49   8,50  129,99   buy);
    @testline10 = qw( 7  121,50  121,50   8,51  130,01   buy);
    @testline11 = qw(19   -2,77   -2,77  -0,53   -3,30   buy);
    @testline12 = qw( 7   12,88   12,88   0,90   13,78   buy);
    @testline13 = qw(19   41,93   41,93   7,97   49,90   buy);
    @testline14 = qw(19   84,65   84,65  16,08  107,73   buy);
    @testline15 = qw(19    8,39    8,39   1,59    9,98   buy);
    @testline16 = qw(19  100,73   84,65  16,08  107,73   buy);
    @testline17 = qw(19    9,99    8,39   1,60    9,99   buy);
  }
}

Support::TestSetup::login();

init_testlines;

# create testcases, made up of one or more lines, with expected values

my $testcase1 = {
    lines           => [ \@testline1 ], # lines to be used in testcase
    total_amount    => $default_manager eq "swiss" ? '51,30' : '56,53',  # expected result
    total_netamount => '47,50',  # expected result
    total_taxamount => $default_manager eq "swiss" ? '3,80' : '9,03',  # expected result
    # invoice parameters:
    taxincluded     => 1,
    exchangerate    => 1,
    currency        => 'EUR',
    buysell         => 'sell',
};

my $testcase2 = {
    lines           => [ \@testline1, \@testline2, \@testline3 ],
    total_amount    => $default_manager eq "swiss" ? '75,89' : '82,82',
    total_netamount => '70,95',
    total_taxamount => $default_manager eq "swiss" ? '4,94' : '11,87',
    taxincluded     => 1,
    exchangerate    => 1,
    currency        => 'EUR',
    buysell         => 'sell',
};

my $testcase3 = {
    lines           => [ \@testline4 ],
    total_amount    => $default_manager eq "swiss" ? '143,73' : '158,37',
    total_netamount => '133,08',
    total_taxamount => $default_manager eq "swiss" ? '10,65' : '25,29',
    taxincluded     => 0,
    exchangerate    => 1,
    currency        => 'EUR',
    buysell         => 'sell',
};

my $testcase4 = {
    lines           => [ \@testline5 ],
    total_amount    => '83,00',
    total_netamount => '83,00',
    total_taxamount => '0,00',
    taxincluded     => 0,
    exchangerate    => '0,83',
    currency        => 'USD',
    buysell         => 'sell',
};

my $testcase6 = {
    lines           => [ \@testline6 ],
    total_amount    => $default_manager eq "swiss" ? '51,30' : '56,53',
    total_netamount => '47,50',
    total_taxamount => $default_manager eq "swiss" ? '3,80' : '9,03',
    taxincluded     => 1,
    exchangerate    => 1,
    currency        => 'EUR',
    buysell         => 'buy',
};

my $testcase7 = {
    lines           => [ \@testline7 ],
    total_netamount => '309,86',
    total_taxamount => $default_manager eq "swiss" ? '24,79' : '58,87',
    total_amount    => $default_manager eq "swiss" ? '334,65' : '368,73',
    taxincluded     => 0,
    exchangerate    => 1,
    currency        => 'EUR',
    buysell         => 'buy',
};

my $testcase8 = {
    lines           => [ \@testline8 ],
    total_netamount => '121,50',
    total_taxamount => $default_manager eq "swiss" ? '3,04' : '8,50',
    total_amount    => $default_manager eq "swiss" ? '124,54' : '130,00',
    taxincluded     => 1,
    exchangerate    => 1,
    currency        => 'EUR',
    buysell         => 'buy',
};

my $testcase9 = {
    lines           => [ \@testline9 ],
    total_netamount => '121,49',
    total_taxamount => $default_manager eq "swiss" ? '3,04' : '8,50',
    total_amount    => $default_manager eq "swiss" ? '124,53' : '129,99',
    taxincluded     => 0,
    exchangerate    => 1,
    currency        => 'EUR',
    buysell         => 'buy',
};

my $testcase10 = {
    lines           => [ \@testline10 ],
    total_netamount => '121,50',
    total_taxamount => $default_manager eq "swiss" ? '3,04' : '8,51',
    total_amount    => $default_manager eq "swiss" ? '124,54' : '130,01',
    taxincluded     => 0,
    exchangerate    => 1,
    currency        => 'EUR',
    buysell         => 'buy',
};

my $testcase11 = {
    # mixed invoices, -2,77€ net with 19% as credit note, 12,88€ net with 7%
    lines           => [ \@testline11 , \@testline12 ],
    total_netamount => '10,11',
    total_taxamount => $default_manager eq "swiss" ? '0,10' : '0,37',
    total_amount    => $default_manager eq "swiss" ? '10,21' : '10,48',
    taxincluded     => 0,
    exchangerate    => 1,
    currency        => 'EUR',
    buysell         => 'buy',
};

my $testcase12 = {
    # ap transaction, example from bug 2435
    lines           => [ \@testline13 ],
    total_netamount => '41,93',
    total_taxamount => $default_manager eq "swiss" ? '3,35' : '7,97',
    total_amount    => $default_manager eq "swiss" ? '45,28' : '49,90',
    taxincluded     => 0,
    exchangerate    => 1,
    currency        => 'EUR',
    buysell         => 'buy',
};

my $testcase13 = {
    # ap transaction, example from bug 2094, tax not included
    lines           => [ \@testline14 , \@testline15 ],
    total_netamount => '93,04',
    total_taxamount => $default_manager eq "swiss" ? '7,44' : '17,67',
    total_amount    => $default_manager eq "swiss" ? '100,48' : '110,71',
    taxincluded     => 0,
    exchangerate    => 1,
    currency        => 'EUR',
    buysell         => 'buy',
};

my $testcase14 = {
    # ap transaction, example from bug 2094, tax included
    lines           => [ \@testline16 , \@testline17 ],
    total_netamount => '93,04',
    total_taxamount => $default_manager eq "swiss" ? '7,44' : '17,68',
    total_amount    => $default_manager eq "swiss" ? '100,48' : '110,72',
    taxincluded     => 1,
    exchangerate    => 1,
    currency        => 'EUR',
    buysell         => 'buy',
};

# run tests
arap_test($testcase1);
arap_test($testcase2);
arap_test($testcase3);
arap_test($testcase4);
arap_test($testcase6);
arap_test($testcase7);
arap_test($testcase8);
arap_test($testcase9);
arap_test($testcase10);
arap_test($testcase11);
arap_test($testcase12);
arap_test($testcase13);
arap_test($testcase14);

# tests for calculate_tax:

# tests for 1 Cent, calculated tax should be 0
calculate_tax_test(0.01,0.07,1,0.01,0.00,0.01,2);
calculate_tax_test(0.01,0.19,1,0.01,0.00,0.01,2);

# tax for rate 7% taxincluded flips at 0.08
calculate_tax_test(0.07,0.07,1,0.07,0.00,0.07,2);
calculate_tax_test(0.08,0.07,1,0.07,0.01,0.08,2);

# tax for rate 7% taxexcluded flips at 0.08
calculate_tax_test(0.07,0.07,0,0.07,0.00,0.07,2);
calculate_tax_test(0.08,0.07,0,0.08,0.01,0.09,2);

# tax for rate 19% taxexcluded flips at 0.03
calculate_tax_test(0.02,0.19,0,0.02,0.00,0.02,2);
calculate_tax_test(0.03,0.19,0,0.03,0.01,0.04,2);

# tax for rate 19% taxincluded flips at 0.04
calculate_tax_test(0.03,0.19,1,0.03,0.00,0.03,2);
calculate_tax_test(0.04,0.19,1,0.03,0.01,0.04,2);

calculate_tax_test(8.39,0.19,0,8.39,1.59,9.98,2);
calculate_tax_test(9.99,0.19,1,8.39,1.60,9.99,2);

calculate_tax_test(11.21,0.07,0,11.21,0.78,11.99,2);
calculate_tax_test(11.22,0.07,0,11.22,0.79,12.01,2);
calculate_tax_test(12.00,0.07,1,11.21,0.79,12.00,2);

done_testing(82);

1;
