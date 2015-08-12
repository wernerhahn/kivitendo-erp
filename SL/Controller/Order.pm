package SL::Controller::Order;

use strict;
use parent qw(SL::Controller::Base);

use SL::Helper::Flash;
use SL::ClientJS;
use SL::Presenter;

use SL::DB::Order;
use SL::DB::Customer;
use SL::DB::Vendor;
use SL::DB::TaxZone;
use SL::DB::Employee;
use SL::DB::Project;
use SL::DB::Default;
use SL::DB::Unit;

use SL::Helper::DateTime;

use List::Util qw(max first);
use List::MoreUtils qw(none pairwise);

use Rose::Object::MakeMethods::Generic
(
 'scalar --get_set_init' => [ qw(order valid_types type cv js p) ],
);


# safety
__PACKAGE__->run_before('_check_auth');

__PACKAGE__->run_before('_setup',
                        only => [ qw(edit update save) ]);


#
# actions
#

sub action_add {
  my ($self) = @_;

  $self->order->transdate(DateTime->now_local());

  $self->_pre_render();
  $self->render(
    'order/form',
    title => $self->type eq _sales_order_type()    ? $::locale->text('Add Sales Order')
           : $self->type eq _purchase_order_type() ? $::locale->text('Add Purchase Order')
           : '',
    %{$self->{template_args}}
  );
}

sub action_edit {
  my ($self) = @_;

  $self->_pre_render();
  $self->render(
    'order/form',
    title => $self->type eq _sales_order_type()    ? $::locale->text('Edit Sales Order')
           : $self->type eq _purchase_order_type() ? $::locale->text('Edit Purchase Order')
           : '',
    %{$self->{template_args}}
  );
}

sub action_update {
  my ($self) = @_;

  $self->_pre_render();
  $self->render(
    'order/form',
    title => $self->type eq _sales_order_type()    ? $::locale->text('Edit Sales Order')
           : $self->type eq _purchase_order_type() ? $::locale->text('Edit Purchase Order')
           : '',
    %{$self->{template_args}}
  );
}

sub action_save {
  my ($self) = @_;

  $self->_save();

  my @redirect_params = (
    action => 'edit',
    type   => $self->type,
    id     => $self->order->id,
  );

  $self->redirect_to(@redirect_params);
}

sub action_customer_vendor_changed {
  my ($self) = @_;

  if ($self->cv eq 'customer') {
    $self->order->customer(SL::DB::Manager::Customer->find_by_or_create(id => $::form->{cv_id}));

  } elsif ($self->cv eq 'vendor') {
    $self->order->vendor(SL::DB::Manager::Vendor->find_by_or_create(id => $::form->{cv_id}));
  }

  if ($self->order->{$self->cv}->contacts && scalar @{ $self->order->{$self->cv}->contacts } > 0) {
    $self->js->show('#cp_row');
  } else {
    $self->js->hide('#cp_row');
  }

  if ($self->order->{$self->cv}->shipto && scalar @{ $self->order->{$self->cv}->shipto } > 0) {
    $self->js->show('#shipto_row');
  } else {
    $self->js->hide('#shipto_row');
  }

  $self->js
    ->replaceWith('#order_cp_id',     $self->build_contact_select)
    ->replaceWith('#order_shipto_id', $self->build_shipto_select)
    ->val('#order_taxzone_id', $self->order->{$self->cv}->taxzone_id)
    ->focus('#order_' . $self->cv . ' _id')
    ->render($self);
}

sub action_add_item {
  my ($self) = @_;

  my $form_attr = $::form->{add_item};
  my $item      = SL::DB::OrderItem->new;
  $item->assign_attributes(%$form_attr);

  my $part        = SL::DB::Part->new(id => $form_attr->{parts_id})->load;
  my $cv_class    = "SL::DB::" . ucfirst($self->cv);
  my $cv_discount = $::form->{$self->cv . '_id'}? $cv_class->new(id => $::form->{$self->cv . '_id'})->load->discount :0.0;

  my %new_attr;
  $new_attr{id}        = join('_', 'new', Time::HiRes::gettimeofday(), int rand 1000000000000);
  $new_attr{part}      = $part;
  $new_attr{qty}       = 1.0               if ! $item->{qty};
  $new_attr{unit}      = $part->unit;
  $new_attr{sellprice} = $part->sellprice  if ! $item->{sellprice};
  $new_attr{discount}  = $cv_discount      if ! $item->{discount};
  $item->assign_attributes(%new_attr);

  $self->order->add_items($item);

  $self->_setup();

  my $row_as_html = $self->p->render('order/tabs/_row', ITEM => $item);

  $self->js
    ->append('#row_table_id tbody', $row_as_html)
    ->focus('#row_table_id tr:last [id$="parts_id_name"]')
    ->off('[id^="order_orderitems"][id$="parts_id"]', 'change', 'set_item_values')
    ->on('[id^="order_orderitems"][id$="parts_id"]', 'change', 'set_item_values')
    ->html('#netamount_id', $::form->format_amount(\%::myconfig, $self->order->netamount, -2))
    ->html('#amount_id',    $::form->format_amount(\%::myconfig, $self->order->amount,    -2))
    ->remove('.tax_row')
    ->insertBefore($self->build_tax_rows, '#amount_row_id')
    ->render($self);
}

sub action_set_item_values {
  my ($self) = @_;

  my $is_new  = $::form->{item_id} =~ m{^new_};
  my $item_id = $::form->{item_id};

  my $item      = first {$_->id   eq $::form->{item_id}} @{$self->order->items};
  my $form_attr = first {$_->{id} eq $::form->{item_id}} @{ $::form->{order}->{orderitems} };

  delete $form_attr->{id};

  my $part = SL::DB::Part->new(id => $form_attr->{parts_id})->load;

  my $cv_class    = "SL::DB::" . ucfirst($self->cv);
  my $cv_discount = $::form->{cv_id}? $cv_class->new(id => $::form->{$self->cv . '_id'})->load->discount :0.0;


  my %new_attr;
  $new_attr{sellprice} = $part->sellprice  if ! $form_attr->{sellprice_as_number};
  $new_attr{discount}  = $cv_discount      if ! $form_attr->{discount_as_percent};
  $new_attr{unit}      = $part->unit       if ! $form_attr->{unit};
  $new_attr{qty}       = 1.0               if ! $form_attr->{qty_as_number};

  $item->assign_attributes(%new_attr);


  $self->_setup();

  $self->js
    ->val( '#' . $::form->{qty_dom_id},       $item->qty_as_number)
    ->val( '#' . $::form->{unit_dom_id},      $item->unit)
    ->val( '#' . $::form->{sellprice_dom_id}, $item->sellprice_as_number)
    ->val( '#' . $::form->{discount_dom_id},  $item->discount_as_percent)
    ->run('display_linetotal', $::form->{item_id}, $::form->format_amount(\%::myconfig, $item->{linetotal}, -2))
    ->html('#netamount_id', $::form->format_amount(\%::myconfig, $self->order->netamount, -2))
    ->html('#amount_id',    $::form->format_amount(\%::myconfig, $self->order->amount,    -2))
    ->remove('.tax_row')
    ->insertBefore($self->build_tax_rows, '#amount_row_id')
    ->render($self);
}


#
# helpers
#

sub init_valid_types {
  [ _sales_order_type(), _purchase_order_type() ];
}

sub init_type {
  my ($self) = @_;

  if (none { $::form->{type} eq $_ } @{$self->valid_types}) {
    die "Not a valid type for order";
  }

  $self->type($::form->{type});
}

sub init_cv {
  my ($self) = @_;

  my $cv = $self->type eq _sales_order_type()    ? 'customer'
         : $self->type eq _purchase_order_type() ? 'vendor'
         : die "Not a valid type for order";

  return $cv;
}

sub init_js {
  SL::ClientJS->new;
}

sub init_p {
  SL::Presenter->get;
}

sub init_order {
  _make_order();
}

sub _check_auth {
  my ($self) = @_;

  my $right_for = { map { $_ => $_.'_edit' } @{$self->valid_types} };

  my $right   = $right_for->{ $self->type };
  $right    ||= 'DOES_NOT_EXIST';

  $::auth->assert($right);
}

sub build_contact_select {
  my ($self) = @_;

  $self->p->select_tag('order.cp_id', [ $self->order->{$self->cv}->contacts ],
                       value_key  => 'cp_id',
                       title_key  => 'full_name_dep',
                       default    => $self->order->cp_id,
                       with_empty => 1,
                       style      => 'width: 300px',
  );
}

sub build_shipto_select {
  my ($self) = @_;

  $self->p->select_tag('order.shipto_id', [ $self->order->{$self->cv}->shipto ],
                       value_key  => 'shipto_id',
                       title_key  => 'displayable_id',
                       default    => $self->order->shipto_id,
                       with_empty => 1,
                       style      => 'width: 300px',
  );
}

sub build_tax_rows {
  my ($self) = @_;

  my $rows_as_html;
  foreach my $tax (@{ $self->{taxes} }) {
    $rows_as_html .= $self->p->render('order/tabs/_tax_row', TAX => $tax);
  }
  return $rows_as_html;
}


sub _make_order {
  my ($self) = @_;

  # add_items adds items to an order with no items for saving, but they cannot
  # be retrieved via items until the order is saved. Adding empty items to new
  # order here solves this problem.
  my $order;
  $order   = SL::DB::Manager::Order->find_by(id => $::form->{id}) if $::form->{id};
  $order ||= SL::DB::Order->new(orderitems => []);

  $order->assign_attributes(%{$::form->{order}});

  return $order;
}


sub _setup {
  my ($self) = @_;

  # bb: todo: currency later
  $self->order->currency_id($::instance_conf->get_currency_id());

  my %pat = $self->order->calculate_prices_and_taxes();

  foreach my $tax_chart_id (keys %{ $pat{taxes} }) {
    my $tax = SL::DB::Manager::Tax->find_by(chart_id => $tax_chart_id);
    push(@{ $self->{taxes} }, { amount => $pat{taxes}->{$tax_chart_id},
                                tax    => $tax });
  }

  pairwise { $a->{linetotal} = $b->{linetotal} } @{$self->order->items}, @{$pat{items}};
}

sub _save {
  my ($self) = @_;

  my $db = $self->order->db;

  $db->do_transaction(
    sub {
      $self->order->save();
  }) || die($db->error);
}


sub _pre_render {
  my ($self) = @_;

  $self->{all_taxzones}  = SL::DB::Manager::TaxZone->get_all_sorted();
  $self->{all_employees} = SL::DB::Manager::Employee->get_all(where => [ or => [ id => $self->order->employee_id,
                                                                                 deleted => 0 ] ],
                                                              sort_by => 'name');
  $self->{all_projects}  = SL::DB::Manager::Project->get_all(where => [ or => [ id => $self->order->globalproject_id,
                                                                                active => 1 ] ],
                                                             sort_by => 'projectnumber');

  $self->{current_employee_id} = SL::DB::Manager::Employee->current->id;
}

sub _sales_order_type {
  'sales_order';
}

sub _purchase_order_type {
  'purchase_order';
}

1;
