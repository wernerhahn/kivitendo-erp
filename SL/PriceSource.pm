package SL::PriceSource;

use strict;
use parent 'SL::DB::Object';
use Rose::Object::MakeMethods::Generic (
  scalar => [ qw(record_item record) ],
  'array --get_set_init' => [ qw(all_price_sources) ],
);

use List::UtilsBy qw(min_by max_by);
use SL::PriceSource::ALL;
use SL::PriceSource::Price;
use SL::Locale::String;

sub init_all_price_sources {
  my ($self) = @_;

  [ map {
    $_->new(record_item => $self->record_item, record => $self->record)
  } SL::PriceSource::ALL->all_enabled_price_sources ]
}

sub price_from_source {
  my ($self, $source) = @_;
  my ($source_name, $spec) = split m{/}, $source, 2;

  my $class = SL::PriceSource::ALL->price_source_class_by_name($source_name);

  return $class
    ? $class->new(record_item => $self->record_item, record => $self->record)->price_from_source($source, $spec)
    : empty_price();
}

sub discount_from_source {
  my ($self, $source) = @_;
  my ($source_name, $spec) = split m{/}, $source, 2;

  my $class = SL::PriceSource::ALL->price_source_class_by_name($source_name);

  return $class
    ? $class->new(record_item => $self->record_item, record => $self->record)->discount_from_source($source, $spec)
    : empty_discount();
}

sub available_prices {
  map { $_->available_prices } $_[0]->all_price_sources;
}

sub available_discounts {
  return if $_[0]->record_item->part->not_discountable;
  map { $_->available_discounts } $_[0]->all_price_sources;
}

sub best_price {
  min_by { $_->price } max_by { $_->priority } grep { $_->price > 0 } grep { $_ } map { $_->best_price } $_[0]->all_price_sources;
}

sub best_discount {
  max_by { $_->discount } max_by { $_->priority } grep { $_->discount } grep { $_ } map { $_->best_discount } $_[0]->all_price_sources;
}

sub empty_price {
  SL::PriceSource::Price->new(
    description => t8('None (PriceSource)'),
  );
}

sub empty_discount {
  SL::PriceSource::Discount->new(
    description => t8('None (PriceSource Discount)'),
  );
}

1;

__END__

=encoding utf-8

=head1 NAME

SL::PriceSource - mixin for price_sources in record items

=head1 DESCRIPTION

PriceSource is an interface that allows generic algorithms to be plugged
together to calculate available prices for a position in a record.

Each algorithm can access details of the record to realize dependencies on
part, customer, vendor, date, quantity etc, which was previously not possible.

=head1 BACKGROUND AND PHILOSOPHY

sql ledger and subsequently Lx-Office had three prices per part: sellprice,
listprice and lastcost. When adding an item to a record, the applicable price
was copied and after that it was free to be changed.

Later on additional things were added. Various types of discount, vendor pricelists
and the infamous price groups. The problem was not that those didn't work, the
problem was they had to guess too much when to change a price with the
available price from the database, and when to leave the user entered price.

The result was that the price of an item in a record seemed to change on a
whim, and the origin of the price itself being opaque.

Unrelated to that, users asked for more ways to store special prices, based on
qty (block pricing, bulk discount), based on date (special offers), based on
customers (special terms), up to full blown calculation modules.

On a third front sales personnel asked for ways to see what price options a
position in a quotation has, and wanted information available when prices
changed to make better informed choices about sales later in the workflow.

Price sources now extend the previous pricing by attaching a source to every
price in records. The information it provides are:

=over 4

=item 1.

Where did this price originate?

=item 2.

If this price would be calculated today, is it still the same as it was when
this record was created?

=item 3.

If I want to price an item in this record now, which prices are available?

=item 4.

Which one is the "best"?

=back

=head1 GUARANTEES

To ensure price source prices are comprehensible and reproducible, some
invariants are guaranteed:

=over 4

=item 1.

Price sources will never on their own change a price. They will offer options,
and it is up to the user to change a price.

=item 2.

If a price is set from a source, it is read only. A price edited manually is by
definition not a sourced price.

=item 3.

A price should be able to repeat the calculations done to arrive at the price
when it was first used. If these calculations are no longer applicable (special
offer expired) this should be signalled. If the calculations result in a
different price, this should be signalled. If the calculations fail (needed
information is no longer present) this must be signalled.

=back

The first point creates user security by never changing a price for them
without their explicit consent, eliminating all problems originating from
trying to be smart. The second and third one ensure that later on the
calculation can be repeated so that invalid prices can be caught (because for
example the special offer is no longer valid), and so that sales personnel have
information about rising or falling prices.

=head1 STRUCTURE

Price sources are managed by this package (L<SL::PriceSource>), and all
external access should be by using it's interface.

Each source is an instance of L<SL::PriceSource::Base> and the available
implementations are recorded in L<SL::PriceSource::ALL>. Prices and discounts
returned by interface methods are instances of L<SL::PriceSource::Price> and
L<SL::PriceSource::Discout>.

Returned prices and discounts should be checked for entries in C<invalid> and
C<missing>, see documentation in their classes.

=head1 INTERFACE METHODS

=over 4

=item C<new PARAMS>

C<PARAMS> must contain both C<record> and C<record_item>. C<record_item> does
not have to be registered in C<record>.

=item C<price_from_source>

Attempts to retrieve a formerly calculated price with the same conditions

=item C<discount_from_source>

Attempts to retrieve a formerly calculated discount with the same conditions

=item C<available_prices>

Returns all available prices.

=item C<available_discounts>

Returns all available discounts.

=item C<best_price>

Attempts to get the best available price. returns L<empty_price> if no price is found.

=item C<best_discount>

Attempts to get the best available discount. returns L<empty_discount> if no discount is found.

=item C<empty_price>

A special empty price, that does not change the previously entered price, and
opens the price field to manual changes.

=item C<empty_discount>

A special empty discount, that does not change the previously entered discount, and
opens the discount field to manual changes.

=back

=head1 SEE ALSO

L<SL::PriceSource::Base>,
L<SL::PriceSource::Price>,
L<SL::PriceSource::Discount>,
L<SL::PriceSource::ALL>

=head1 BUGS AND CAVEATS

=over 4

=item *

The current model of price sources requires a record and a record_item for
every price calculation. This means that price structures can never be used
when no record is available, such as calculation the worth of assembly rows.

A possible solution is to either split price sources into simple and complex
ones (where the former do not require records).

Another would be to have default values for the inpout normally taken from
records (like qty defaulting to 1).

A last one would be to provide an alternative input channel for needed
properties.

=item *

Discount sources were implemented as a copy of the prices with slightly
different semantics. Need to do a real design. A requirement is, that a sinle
source can provide both prices and discounts (needed for price_rules).

=item *

Priorities are implemented ad hoc. The semantics which are chosen by the "best"
accessors are unintuitive because they do not guarantee anything. Better
terminology might help.

=item *

It is currently not possible to link a price to the price of the generating
record_item (i.e. the price of a delivery order item to the order item it was
generated from). This is crucial to enterprises that calculate all their prices
in orders, and update those after they made delivery orders.

=item *

Currently it is only possible to provide additional prices, but not to restrict
prices. Potential scenarios include credit limit customers which do not receive
benefits from sales, or general ALLOW, DENY order calculation.

=item *

Composing price sources is disallowed for clarity, but all price sources need
to be aware of units. This is madness.

=back

=head1 AUTHOR

Sven Schoeling E<lt>s.schoeling@linet-services.deE<gt>

=cut
