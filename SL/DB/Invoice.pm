package SL::DB::Invoice;

use strict;

use Carp;
use List::Util qw(first sum);

use Rose::DB::Object::Helpers qw(has_loaded_related forget_related);
use SL::DB::MetaSetup::Invoice;
use SL::DB::Manager::Invoice;
use SL::DB::Helper::Payment qw(:ALL);
use SL::DB::Helper::AttrHTML;
use SL::DB::Helper::AttrSorted;
use SL::DB::Helper::FlattenToForm;
use SL::DB::Helper::LinkedRecords;
use SL::DB::Helper::PriceTaxCalculator;
use SL::DB::Helper::PriceUpdater;
use SL::DB::Helper::TransNumberGenerator;
use SL::Locale::String qw(t8);
use SL::DB::CustomVariable;

__PACKAGE__->meta->add_relationship(
  invoiceitems => {
    type         => 'one to many',
    class        => 'SL::DB::InvoiceItem',
    column_map   => { id => 'trans_id' },
    manager_args => {
      with_objects => [ 'part' ]
    }
  },
  storno_invoices => {
    type          => 'one to many',
    class         => 'SL::DB::Invoice',
    column_map    => { id => 'storno_id' },
  },
  sepa_export_items => {
    type            => 'one to many',
    class           => 'SL::DB::SepaExportItem',
    column_map      => { id => 'ar_id' },
    manager_args    => { with_objects => [ 'sepa_export' ] }
  },
  sepa_exports      => {
    type            => 'many to many',
    map_class       => 'SL::DB::SepaExportItem',
    map_from        => 'ar',
    map_to          => 'sepa_export',
  },
  custom_shipto     => {
    type            => 'one to one',
    class           => 'SL::DB::Shipto',
    column_map      => { id => 'trans_id' },
    query_args      => [ module => 'AR' ],
  },
  transactions   => {
    type         => 'one to many',
    class        => 'SL::DB::AccTransaction',
    column_map   => { id => 'trans_id' },
    manager_args => {
      with_objects => [ 'chart' ],
      sort_by      => 'acc_trans_id ASC',
    },
  },
);

__PACKAGE__->meta->initialize;

__PACKAGE__->attr_html('notes');
__PACKAGE__->attr_sorted('items');

__PACKAGE__->before_save('_before_save_set_invnumber');

# hooks

sub _before_save_set_invnumber {
  my ($self) = @_;

  $self->create_trans_number if !$self->invnumber;

  return 1;
}

# methods

sub items { goto &invoiceitems; }
sub add_items { goto &add_invoiceitems; }
sub record_number { goto &invnumber; };

sub is_sales {
  # For compatibility with Order, DeliveryOrder
  croak 'not an accessor' if @_ > 1;
  return 1;
}

# it is assumed, that ordnumbers are unique here.
sub first_order_by_ordnumber {
  my $self = shift;

  my $orders = SL::DB::Manager::Order->get_all(
    query => [
      ordnumber => $self->ordnumber,

    ],
  );

  return first { $_->is_type('sales_order') } @{ $orders };
}

sub abschlag_percentage {
  my $self         = shift;
  my $order        = $self->first_order_by_ordnumber or return;
  my $order_amount = $order->netamount               or return;
  return $self->abschlag
    ? $self->netamount / $order_amount
    : undef;
}

sub taxamount {
  my $self = shift;
  die 'not a setter method' if @_;

  return ($self->amount || 0) - ($self->netamount || 0);
}

__PACKAGE__->meta->make_attr_helpers(taxamount => 'numeric(15,5)');

sub closed {
  my ($self) = @_;
  return $self->paid >= $self->amount;
}

sub _clone_orderitem_delivery_order_item_cvar {
  my ($cvar) = @_;

  my $cloned = $_->clone_and_reset;
  $cloned->sub_module('invoice');

  return $cloned;
}

sub new_from {
  my ($class, $source, %params) = @_;

  croak("Unsupported source object type '" . ref($source) . "'") unless ref($source) =~ m/^ SL::DB:: (?: Order | DeliveryOrder ) $/x;
  croak("Cannot create invoices for purchase records")           unless $source->customer_id;

  require SL::DB::Employee;

  my (@columns, @item_columns, $item_parent_id_column, $item_parent_column);

  if (ref($source) eq 'SL::DB::Order') {
    @columns      = qw(quonumber delivery_customer_id delivery_vendor_id);
    @item_columns = qw(subtotal);

    $item_parent_id_column = 'trans_id';
    $item_parent_column    = 'order';

  } else {
    @columns      = qw(donumber);

    $item_parent_id_column = 'delivery_order_id';
    $item_parent_column    = 'delivery_order';
  }

  my $terms = $source->can('payment_id') ? $source->payment_terms : undef;
  $terms = $source->customer->payment_terms if !defined $terms && $source->customer;

  my %args = ( map({ ( $_ => $source->$_ ) } qw(customer_id taxincluded shippingpoint shipvia notes intnotes salesman_id cusordnumber ordnumber department_id
                                                cp_id language_id taxzone_id globalproject_id transaction_description currency_id delivery_term_id), @columns),
               transdate   => DateTime->today_local,
               gldate      => DateTime->today_local,
               duedate     => $terms ? $terms->calc_date(reference_date => DateTime->today_local) : DateTime->today_local,
               invoice     => 1,
               type        => 'invoice',
               storno      => 0,
               paid        => 0,
               employee_id => (SL::DB::Manager::Employee->current || SL::DB::Employee->new(id => $source->employee_id))->id,
            );

  $args{payment_id} = ( $terms ? $terms->id : $source->payment_id);

  if ($source->type =~ /_order$/) {
    $args{deliverydate} = $source->reqdate;
    $args{orddate}      = $source->transdate;
  } else {
    $args{quodate}      = $source->transdate;
  }

  # Custom shipto addresses (the ones specific to the sales/purchase
  # record and not to the customer/vendor) are only linked from shipto
  # → ar. Meaning ar.shipto_id will not be filled in that
  # case.
  if (!$source->shipto_id && $source->id) {
    $args{custom_shipto} = $source->custom_shipto->clone($class) if $source->can('custom_shipto') && $source->custom_shipto;

  } else {
    $args{shipto_id} = $source->shipto_id;
  }

  my $invoice = $class->new(%args);
  $invoice->assign_attributes(%{ $params{attributes} }) if $params{attributes};
  my $items   = delete($params{items}) || $source->items_sorted;
  my %item_parents;

  my @items = map {
    my $source_item      = $_;
    my $source_item_id   = $_->$item_parent_id_column;
    my @custom_variables = map { _clone_orderitem_delivery_order_item_cvar($_) } @{ $source_item->custom_variables };

    $item_parents{$source_item_id} ||= $source_item->$item_parent_column;
    my $item_parent                  = $item_parents{$source_item_id};
    my $current_invoice_item =
      SL::DB::InvoiceItem->new(map({ ( $_ => $source_item->$_ ) }
                                   qw(parts_id description qty sellprice discount project_id serialnumber pricegroup_id transdate cusordnumber unit
                                      base_qty longdescription lastcost price_factor_id active_discount_source active_price_source), @item_columns),
                               deliverydate     => $source_item->reqdate,
                               fxsellprice      => $source_item->sellprice,
                               custom_variables => \@custom_variables,
                               ordnumber        => ref($item_parent) eq 'SL::DB::Order'         ? $item_parent->ordnumber : $source_item->ordnumber,
                               donumber         => ref($item_parent) eq 'SL::DB::DeliveryOrder' ? $item_parent->donumber  : $source_item->can('donumber') ? $source_item->donumber : '',
                             );

    $current_invoice_item->{"converted_from_orderitems_id"}           = $_->{id} if ref($item_parent) eq 'SL::DB::Order';
    $current_invoice_item->{"converted_from_delivery_order_items_id"} = $_->{id} if ref($item_parent) eq 'SL::DB::DeliveryOrder';
    $current_invoice_item;
  } @{ $items };

  @items = grep { $params{item_filter}->($_) } @items if $params{item_filter};
  @items = grep { $_->qty * 1 } @items if $params{skip_items_zero_qty};
  @items = grep { $_->qty >=0 } @items if $params{skip_items_negative_qty};

  $invoice->invoiceitems(\@items);

  return $invoice;
}

sub post {
  my ($self, %params) = @_;

  die "not an invoice" unless $self->invoice;

  require SL::DB::Chart;
  if (!$params{ar_id}) {
    my $chart = SL::DB::Manager::Chart->get_all(query   => [ SL::DB::Manager::Chart->link_filter('AR') ],
                                                sort_by => 'id ASC',
                                                limit   => 1)->[0];
    croak("No AR chart found and no parameter 'ar_id' given") unless $chart;
    $params{ar_id} = $chart->id;
  }

  my $worker = sub {
    my %data = $self->calculate_prices_and_taxes;

    $self->_post_create_assemblyitem_entries($data{assembly_items});
    $self->save;

    $self->_post_add_acctrans($data{amounts_cogs});
    $self->_post_add_acctrans($data{amounts});
    $self->_post_add_acctrans($data{taxes});

    $self->_post_add_acctrans({ $params{ar_id} => $self->amount * -1 });

    $self->_post_update_allocated($data{allocated});
  };

  if ($self->db->in_transaction) {
    $worker->();
  } elsif (!$self->db->do_transaction($worker)) {
    $::lxdebug->message(LXDebug->WARN(), "convert_to_invoice failed: " . join("\n", (split(/\n/, $self->db->error))[0..2]));
    return undef;
  }

  return $self;
}

sub _post_add_acctrans {
  my ($self, $entries) = @_;

  my $default_tax_id = SL::DB::Manager::Tax->find_by(taxkey => 0)->id;
  my $chart_link;

  require SL::DB::AccTransaction;
  require SL::DB::Chart;
  while (my ($chart_id, $spec) = each %{ $entries }) {
    $spec = { taxkey => 0, tax_id => $default_tax_id, amount => $spec } unless ref $spec;
    $chart_link = SL::DB::Manager::Chart->find_by(id => $chart_id)->{'link'};
    $chart_link ||= '';

    SL::DB::AccTransaction->new(trans_id   => $self->id,
                                chart_id   => $chart_id,
                                amount     => $spec->{amount},
                                tax_id     => $spec->{tax_id},
                                taxkey     => $spec->{taxkey},
                                project_id => $self->globalproject_id,
                                transdate  => $self->transdate,
                                chart_link => $chart_link)->save;
  }
}

sub add_ar_amount_row {
  my ($self, %params ) = @_;

  # only allow this method for ar invoices (Debitorenbuchung)
  die "not an ar invoice" if $self->invoice and not $self->customer_id;

  die "add_ar_amount_row needs a chart object as chart param" unless $params{chart} && $params{chart}->isa('SL::DB::Chart');
  die unless $params{chart}->link =~ /AR_amount/;

  my $acc_trans = [];

  my $roundplaces = 2;
  my ($netamount,$taxamount);

  $netamount = $params{amount} * 1;
  my $tax = SL::DB::Manager::Tax->find_by(id => $params{tax_id}) || die "Can't find tax with id " . $params{tax_id};

  if ( $tax and $tax->rate != 0 ) {
    ($netamount, $taxamount) = Form->calculate_tax($params{amount}, $tax->rate, $self->taxincluded, $roundplaces);
  };
  next unless $netamount; # netamount mustn't be zero

  my $sign = $self->customer_id ? 1 : -1;
  my $acc = SL::DB::AccTransaction->new(
    amount     => $netamount * $sign,
    chart_id   => $params{chart}->id,
    chart_link => $params{chart}->link,
    transdate  => $self->transdate,
    taxkey     => $tax->taxkey,
    tax_id     => $tax->id,
    project_id => $params{project_id},
  );

  $self->add_transactions( $acc );
  push( @$acc_trans, $acc );

  if ( $taxamount ) {
     my $acc = SL::DB::AccTransaction->new(
       amount     => $taxamount * $sign,
       chart_id   => $tax->chart_id,
       chart_link => $tax->chart->link,
       transdate  => $self->transdate,
       taxkey     => $tax->taxkey,
       tax_id     => $tax->id,
     );
     $self->add_transactions( $acc );
     push( @$acc_trans, $acc );
  };
  return $acc_trans;
};

sub create_ar_row {
  my ($self, %params) = @_;
  # to be called after adding all AR_amount rows, adds an AR row

  # only allow this method for ar invoices (Debitorenbuchung)
  die if $self->invoice and not $self->customer_id;
  die "create_ar_row needs a chart object as a parameter" unless $params{chart} and ref($params{chart}) eq 'SL::DB::Chart';

  my @transactions = @{$self->transactions};
  # die "invoice has no acc_transactions" unless scalar @transactions > 0;
  return 0 unless scalar @transactions > 0;

  my $chart = $params{chart} || SL::DB::Manager::Chart->find_by(id => $::instance_conf->get_ar_chart_id);
  die "illegal chart in create_ar_row" unless $chart;

  die "receivables chart must have link 'AR'" unless $chart->link eq 'AR';

  my $acc_trans = [];

  # hardcoded entry for no tax: tax_id and taxkey should be 0
  my $tax = SL::DB::Manager::Tax->find_by(id => 0, taxkey => 0) || die "Can't find tax with id 0 and taxkey 0";

  my $sign = $self->customer_id ? -1 : 1;
  my $acc = SL::DB::AccTransaction->new(
    amount     => $self->amount * $sign,
    chart_id   => $params{chart}->id,
    chart_link => $params{chart}->link,
    transdate  => $self->transdate,
    taxkey     => $tax->taxkey,
    tax_id     => $tax->id,
  );
  $self->add_transactions( $acc );
  push( @$acc_trans, $acc );
  return $acc_trans;
};

sub validate_acc_trans {
  my ($self, %params) = @_;
  # should be able to check unsaved invoice objects with several acc_trans lines

  die "validate_acc_trans can't check invoice object with empty transactions" unless $self->transactions;

  my @transactions = @{$self->transactions};
  # die "invoice has no acc_transactions" unless scalar @transactions > 0;
  return 0 unless scalar @transactions > 0;
  return 0 unless $self->has_loaded_related('transactions');
  if ( $params{debug} ) {
    printf("starting validatation of invoice %s with trans_id %s and taxincluded %s\n", $self->invnumber, $self->id, $self->taxincluded);
    foreach my $acc ( @transactions ) {
      printf("chart: %s  amount: %s   tax_id: %s  link: %s\n", $acc->chart->accno, $acc->amount, $acc->tax_id, $acc->chart->link);
    };
  };

  my $acc_trans_sum = sum map { $_->amount } @transactions;

  unless ( $::form->round_amount($acc_trans_sum, 10) == 0 ) {
    my $string = "sum of acc_transactions isn't 0: $acc_trans_sum\n";

    if ( $params{debug} ) {
      foreach my $trans ( @transactions ) {
          $string .= sprintf("  %s %s %s\n", $trans->chart->accno, $trans->taxkey, $trans->amount);
      };
    };
    return 0;
  };

  # only use the first AR entry, so it also works for paid invoices
  my @ar_transactions = map { $_->amount } grep { $_->chart_link eq 'AR' } @transactions;
  my $ar_sum = $ar_transactions[0];
  # my $ar_sum = sum map { $_->amount } grep { $_->chart_link eq 'AR' } @transactions;

  unless ( $::form->round_amount($ar_sum * -1,2) == $::form->round_amount($self->amount,2) ) {
    if ( $params{debug} ) {
      printf("debug: (ar_sum) %s = %s (amount)\n",  $::form->round_amount($ar_sum * -1,2) , $::form->round_amount($self->amount, 2) );
      foreach my $trans ( @transactions ) {
        printf("  %s %s %s %s\n", $trans->chart->accno, $trans->taxkey, $trans->amount, $trans->chart->link);
      };
    };
    die sprintf("sum of ar (%s) isn't equal to invoice amount (%s)", $::form->round_amount($ar_sum * -1,2), $::form->round_amount($self->amount,2));
  };

  return 1;
};

sub recalculate_amounts {
  my ($self, %params) = @_;
  # calculate and set amount and netamount from acc_trans objects

  croak ("Can only recalculate amounts for ar transactions") if $self->invoice;

  return undef unless $self->has_loaded_related('transactions');

  my ($netamount, $taxamount);

  my @transactions = @{$self->transactions};

  foreach my $acc ( @transactions ) {
    $netamount += $acc->amount if $acc->chart->link =~ /AR_amount/;
    $taxamount += $acc->amount if $acc->chart->link =~ /AR_tax/;
  };

  $self->amount($netamount+$taxamount);
  $self->netamount($netamount);
};


sub _post_create_assemblyitem_entries {
  my ($self, $assembly_entries) = @_;

  my $items = $self->invoiceitems;
  my @new_items;

  my $item_idx = 0;
  foreach my $item (@{ $items }) {
    next if $item->assemblyitem;

    push @new_items, $item;
    $item_idx++;

    foreach my $assembly_item (@{ $assembly_entries->[$item_idx] || [ ] }) {
      push @new_items, SL::DB::InvoiceItem->new(parts_id     => $assembly_item->{part},
                                                description  => $assembly_item->{part}->description,
                                                unit         => $assembly_item->{part}->unit,
                                                qty          => $assembly_item->{qty},
                                                allocated    => $assembly_item->{allocated},
                                                sellprice    => 0,
                                                fxsellprice  => 0,
                                                assemblyitem => 't');
    }
  }

  $self->invoiceitems(\@new_items);
}

sub _post_update_allocated {
  my ($self, $allocated) = @_;

  while (my ($invoice_id, $diff) = each %{ $allocated }) {
    SL::DB::Manager::InvoiceItem->update_all(set   => { allocated => { sql => "allocated + $diff" } },
                                             where => [ id        => $invoice_id ]);
  }
}

sub invoice_type {
  my ($self) = @_;

  return 'ar_transaction'     if !$self->invoice;
  return 'credit_note'        if $self->type eq 'credit_note' && $self->amount < 0 && !$self->storno;
  return 'invoice_storno'     if $self->type ne 'credit_note' && $self->amount < 0 &&  $self->storno;
  return 'credit_note_storno' if $self->type eq 'credit_note' && $self->amount > 0 &&  $self->storno;
  return 'invoice';
}

sub displayable_state {
  my $self = shift;

  return $self->closed ? $::locale->text('closed') : $::locale->text('open');
}

sub displayable_type {
  my ($self) = @_;

  return t8('AR Transaction')                         if $self->invoice_type eq 'ar_transaction';
  return t8('Credit Note')                            if $self->invoice_type eq 'credit_note';
  return t8('Invoice') . "(" . t8('Storno') . ")"     if $self->invoice_type eq 'invoice_storno';
  return t8('Credit Note') . "(" . t8('Storno') . ")" if $self->invoice_type eq 'credit_note_storno';
  return t8('Invoice');
}

sub displayable_name {
  join ' ', grep $_, map $_[0]->$_, qw(displayable_type record_number);
};

sub abbreviation {
  my ($self) = @_;

  return t8('AR Transaction (abbreviation)')         if $self->invoice_type eq 'ar_transaction';
  return t8('Credit note (one letter abbreviation)') if $self->invoice_type eq 'credit_note';
  return t8('Invoice (one letter abbreviation)') . "(" . t8('Storno (one letter abbreviation)') . ")" if $self->invoice_type eq 'invoice_storno';
  return t8('Credit note (one letter abbreviation)') . "(" . t8('Storno (one letter abbreviation)') . ")"  if $self->invoice_type eq 'credit_note_storno';
  return t8('Invoice (one letter abbreviation)');
}

sub date {
  goto &transdate;
}

sub reqdate {
  goto &duedate;
}

sub customervendor {
  goto &customer;
}

sub link {
  my ($self) = @_;

  my $html;
  $html   = SL::Presenter->get->sales_invoice($self, display => 'inline') if $self->invoice;
  $html   = SL::Presenter->get->ar_transaction($self, display => 'inline') if !$self->invoice;

  return $html;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

SL::DB::Invoice: Rose model for invoices (table "ar")

=head1 FUNCTIONS

=over 4

=item C<new_from $source, %params>

Creates a new C<SL::DB::Invoice> instance and copies as much
information from C<$source> as possible. At the moment only sales
orders and sales quotations are supported as sources.

The conversion copies order items into invoice items. Dates are copied
as appropriate, e.g. the C<transdate> field from an order will be
copied into the invoice's C<orddate> field.

C<%params> can include the following options:

=over 2

=item C<items>

An optional array reference of RDBO instances for the items to use. If
missing then the method C<items_sorted> will be called on
C<$source>. This option can be used to override the sorting, to
exclude certain positions or to add additional ones.

=item C<skip_items_negative_qty>

If trueish then items with a negative quantity are skipped. Items with
a quantity of 0 are not affected by this option.

=item C<skip_items_zero_qty>

If trueish then items with a quantity of 0 are skipped.

=item C<item_filter>

An optional code reference that is called for each item with the item
as its sole parameter. Items for which the code reference returns a
falsish value will be skipped.

=item C<attributes>

An optional hash reference. If it exists then it is passed to C<new>
allowing the caller to set certain attributes for the new invoice.
For example to set a different transdate (default is the current date),
call the method like this:

   my %params;
   $params{attributes}{transdate} = '28.08.2015';
   $invoice = SL::DB::Invoice->new_from($self, %params)->post || die;

=back

Amounts, prices and taxes are not
calculated. L<SL::DB::Helper::PriceTaxCalculator::calculate_prices_and_taxes>
can be used for this.

The object returned is not saved.

=item C<post %params>

Posts the invoice. Required parameters are:

=over 2

=item * C<ar_id>

The ID of the accounts receivable chart the invoice's amounts are
posted to. If it is not set then the first chart configured for
accounts receivables is used.

=back

This function implements several steps:

=over 2

=item 1. It calculates all prices, amounts and taxes by calling
L<SL::DB::Helper::PriceTaxCalculator::calculate_prices_and_taxes>.

=item 2. A new and unique invoice number is created.

=item 3. All amounts for costs of goods sold are recorded in
C<acc_trans>.

=item 4. All amounts for parts, services and assemblies are recorded
in C<acc_trans> with their respective charts. This is determined by
the part's buchungsgruppen.

=item 5. The total amount is posted to the accounts receivable chart
and recorded in C<acc_trans>.

=item 6. Items in C<invoice> are updated according to their allocation
status (regarding costs of goods sold). Will only be done if
kivitendo is not configured to use Einnahmenüberschussrechnungen.

=item 7. The invoice and its items are saved.

=back

Returns C<$self> on success and C<undef> on failure. The whole process
is run inside a transaction. If it fails then nothing is saved to or
changed in the database. A new transaction is only started if none are
active.

=item C<basic_info $field>

See L<SL::DB::Object::basic_info>.

=item C<recalculate_amounts %params>

Calculate and set amount and netamount from acc_trans objects by summing up the
values of acc_trans objects with AR_amount and AR_tax link charts.
amount and netamount are set to the calculated values.

=item C<validate_acc_trans>

Checks if the sum of all associated acc_trans objects is 0 and checks whether
the amount of the AR acc_transaction matches the AR amount. Only the first AR
line is checked, because the sum of all AR lines is 0 for paid invoices.

Returns 0 or 1.

Can be called with a debug parameter which writes debug info to STDOUT, which is
useful in console mode or while writing tests.

 my $ar = SL::DB::Manager::Invoice->get_first();
 $ar->validate_acc_trans(debug => 1);

=item C<create_ar_row %params>

Creates a new acc_trans entry for the receivable (AR) entry of an existing AR
invoice object, which already has some income and tax acc_trans entries.

The acc_trans entry is also returned inside an array ref.

Mandatory params are

=over 2

=item * chart as an RDBO object, e.g. for bank. Must be a 'paid' chart.

=back

Currently the amount of the invoice object is used for the acc_trans amount.
Use C<recalculate_amounts> before calling this mehtod if amount it isn't known
yet or you didn't set it manually.

=item C<add_ar_amount_row %params>

Add a new entry for an existing AR invoice object. Creates an acc_trans entry,
and also adds an acc_trans tax entry, if the tax has an associated tax chart.
Also all acc_trans entries that were created are returned inside an array ref.

Mandatory params are

=over 2

=item * chart as an RDBO object, should be an income chart (link = AR_amount)

=item * tax_id

=item * amount

=back

=back

=head1 TODO

 As explained in the new_from example, it is possible to set transdate to a new value.
 From a user / programm point of view transdate is more than holy and there should be
 some validity checker available for controller code. At least the same logic like in
 Form.pm from ar.pl should be available:
  # see old stuff ar.pl post
  #$form->error($locale->text('Cannot post transaction above the maximum future booking date!'))
  #  if ($form->date_max_future($transdate, \%myconfig));
  #$form->error($locale->text('Cannot post transaction for a closed period!')) if ($form->date_closed($form->{"transdate"}, \%myconfig));

=head1 AUTHOR

Moritz Bunkus E<lt>m.bunkus@linet-services.deE<gt>

=cut
