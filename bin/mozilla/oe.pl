#=====================================================================
# LX-Office ERP
# Copyright (C) 2004
# Based on SQL-Ledger Version 2.1.9
# Web http://www.lx-office.org
#
#=====================================================================
# SQL-Ledger, Accounting
# Copyright (c) 1998-2003
#
#  Author: Dieter Simader
#   Email: dsimader@sql-ledger.org
#     Web: http://www.sql-ledger.org
#
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#======================================================================
#
# Order entry module
# Quotation module
#======================================================================


use Carp;
use POSIX qw(strftime);

use SL::DB::Order;
use SL::DO;
use SL::FU;
use SL::OE;
use SL::IR;
use SL::IS;
use SL::MoreCommon qw(ary_diff restore_form save_form);
use SL::PE;
use SL::ReportGenerator;
use List::MoreUtils qw(uniq any none);
use List::Util qw(min max reduce sum);
use Data::Dumper;

use SL::DB::Customer;
use SL::DB::TaxZone;

require "bin/mozilla/io.pl";
require "bin/mozilla/arap.pl";
require "bin/mozilla/reportgenerator.pl";

use strict;

our %TMPL_VAR;

1;

# end of main

# For locales.pl:
# $locale->text('Edit the purchase_order');
# $locale->text('Edit the sales_order');
# $locale->text('Edit the request_quotation');
# $locale->text('Edit the sales_quotation');

# $locale->text('Workflow purchase_order');
# $locale->text('Workflow sales_order');
# $locale->text('Workflow request_quotation');
# $locale->text('Workflow sales_quotation');

my $oe_access_map = {
  'sales_order'       => 'sales_order_edit',
  'purchase_order'    => 'purchase_order_edit',
  'request_quotation' => 'request_quotation_edit',
  'sales_quotation'   => 'sales_quotation_edit',
};

sub check_oe_access {
  my $form     = $main::form;

  my $right   = $oe_access_map->{$form->{type}};
  $right    ||= 'DOES_NOT_EXIST';

  $main::auth->assert($right);
}

sub check_oe_conversion_to_sales_invoice_allowed {
  return 1 if  $::form->{type} !~ m/^sales/;
  return 1 if ($::form->{type} =~ m/quotation/) && $::instance_conf->get_allow_sales_invoice_from_sales_quotation;
  return 1 if ($::form->{type} =~ m/order/)     && $::instance_conf->get_allow_sales_invoice_from_sales_order;

  $::form->show_generic_error($::locale->text("You do not have the permissions to access this function."));

  return 0;
}

sub set_headings {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my $locale   = $main::locale;

  check_oe_access();

  my ($action) = @_;

  if ($form->{type} eq 'purchase_order') {
    $form->{title}   = $action eq "edit" ?
      $locale->text('Edit Purchase Order') :
      $locale->text('Add Purchase Order');
    $form->{heading} = $locale->text('Purchase Order');
    $form->{vc}      = 'vendor';
  }
  if ($form->{type} eq 'sales_order') {
    $form->{title}   = $action eq "edit" ?
      $locale->text('Edit Sales Order') :
      $locale->text('Add Sales Order');
    $form->{heading} = $locale->text('Sales Order');
    $form->{vc}      = 'customer';
  }
  if ($form->{type} eq 'request_quotation') {
    $form->{title}   = $action eq "edit" ?
      $locale->text('Edit Request for Quotation') :
      $locale->text('Add Request for Quotation');
    $form->{heading} = $locale->text('Request for Quotation');
    $form->{vc}      = 'vendor';
  }
  if ($form->{type} eq 'sales_quotation') {
    $form->{title}   = $action eq "edit" ?
      $locale->text('Edit Quotation') :
      $locale->text('Add Quotation');
    $form->{heading} = $locale->text('Quotation');
    $form->{vc}      = 'customer';
  }

  $main::lxdebug->leave_sub();
}

sub add {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;

  check_oe_access();

  set_headings("add");

  $form->{callback} =
    "$form->{script}?action=add&type=$form->{type}&vc=$form->{vc}"
    unless $form->{callback};

  $form->{show_details} = $::myconfig{show_form_details};

  &order_links;
  &prepare_order;
  &display_form;

  $main::lxdebug->leave_sub();
}

sub edit {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;

  check_oe_access();

  $form->{show_details}                = $::myconfig{show_form_details};
  $form->{taxincluded_changed_by_user} = 1;

  # show history button
  $form->{javascript} = qq|<script type="text/javascript" src="js/show_history.js"></script>|;
  #/show hhistory button

  $form->{simple_save} = 0;

  set_headings("edit");

  # editing without stuff to edit? try adding it first
  if ($form->{rowcount} && !$form->{print_and_save}) {
    my $id;
    map { $id++ if $form->{"multi_id_$_"} } (1 .. $form->{rowcount});
    if (!$id) {

      # reset rowcount
      undef $form->{rowcount};
      &add;
      $main::lxdebug->leave_sub();
      return;
    }
  } elsif (!$form->{id}) {
    &add;
    $main::lxdebug->leave_sub();
    return;
  }

  my ($language_id, $printer_id);
  if ($form->{print_and_save}) {
    $form->{action}   = "dispatcher";
    $form->{action_print}   = "1";
    $form->{resubmit} = 1;
    $language_id = $form->{language_id};
    $printer_id = $form->{printer_id};
  }

  set_headings("edit");

  &order_links;

  $form->{rowcount} = 0;
  foreach my $ref (@{ $form->{form_details} }) {
    $form->{rowcount}++;
    map { $form->{"${_}_$form->{rowcount}"} = $ref->{$_} } keys %{$ref};
  }

  &prepare_order;

  if ($form->{print_and_save}) {
    $form->{language_id} = $language_id;
    $form->{printer_id} = $printer_id;
  }

  &display_form;

  $main::lxdebug->leave_sub();
}

sub order_links {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  check_oe_access();

  # get customer/vendor
  $form->all_vc(\%myconfig, $form->{vc}, ($form->{vc} eq 'customer') ? "AR" : "AP");

  # retrieve order/quotation
  my $editing = $form->{id};

  OE->retrieve(\%myconfig, \%$form);

  # if multiple rowcounts (== collective order) then check if the
  # there were more than one customer (in that case OE::retrieve removes
  # the content from the field)
  $form->error($locale->text('Collective Orders only work for orders from one customer!'))
    if          $form->{rowcount}  && $form->{type}     eq 'sales_order'
     && defined $form->{customer}  && $form->{customer} eq '';

  $form->{"$form->{vc}_id"} ||= $form->{"all_$form->{vc}"}->[0]->{id} if $form->{"all_$form->{vc}"};

  $form->backup_vars(qw(payment_id language_id taxzone_id salesman_id taxincluded cp_id intnotes shipto_id delivery_term_id currency));

  # get customer / vendor
  IR->get_vendor(\%myconfig, \%$form)   if $form->{type} =~ /(purchase_order|request_quotation)/;
  IS->get_customer(\%myconfig, \%$form) if $form->{type} =~ /sales_(order|quotation)/;

  $form->restore_vars(qw(payment_id language_id taxzone_id intnotes cp_id shipto_id delivery_term_id));
  $form->restore_vars(qw(currency))    if $form->{id};
  $form->restore_vars(qw(taxincluded)) if $form->{id};
  $form->restore_vars(qw(salesman_id)) if $editing;
  $form->{forex}       = $form->{exchangerate};
  $form->{employee}    = "$form->{employee}--$form->{employee_id}";

  # build vendor/customer drop down comatibility... don't ask
  if (@{ $form->{"all_$form->{vc}"} || [] }) {
    $form->{"select$form->{vc}"} = 1;
    $form->{$form->{vc}}         = qq|$form->{$form->{vc}}--$form->{"$form->{vc}_id"}|;
  }

  $form->{"old$form->{vc}"}  = $form->{$form->{vc}};

  if ($form->{"old$form->{vc}"} !~ m/--\d+$/ && $form->{"$form->{vc}_id"}) {
    $form->{"old$form->{vc}"} .= qq|--$form->{"$form->{vc}_id"}|
  }

  $main::lxdebug->leave_sub();
}

sub prepare_order {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  check_oe_access();

  $form->{formname} ||= $form->{type};

  # format discounts if values come from db. either as single id, or as a collective order
  my $format_discounts = $form->{id} || $form->{convert_from_oe_ids};

  for my $i (1 .. $form->{rowcount}) {
    $form->{"reqdate_$i"} ||= $form->{"deliverydate_$i"};
    $form->{"discount_$i"}  = $form->format_amount(\%myconfig, $form->{"discount_$i"} * ($format_discounts ? 100 : 1));
    $form->{"sellprice_$i"} = $form->format_amount(\%myconfig, $form->{"sellprice_$i"});
    $form->{"lastcost_$i"}  = $form->format_amount(\%myconfig, $form->{"lastcost_$i"});
    $form->{"qty_$i"}       = $form->format_amount(\%myconfig, $form->{"qty_$i"});
  }

  $main::lxdebug->leave_sub();
}

sub form_header {
  $main::lxdebug->enter_sub();
  my @custom_hiddens;

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;
  my $cgi      = $::request->{cgi};

  check_oe_access();

  # Container for template variables. Unfortunately this has to be
  # visible in form_footer too, so package local level and not my here.
  %TMPL_VAR = ();
  if ($form->{id}) {
    my $obj = SL::DB::Order->new(id => $form->{id})->load;
    $TMPL_VAR{warn_save_active_periodic_invoice} =
         $obj->is_type('sales_order')
      && $obj->periodic_invoices_config
      && $obj->periodic_invoices_config->active
      && (   !$obj->periodic_invoices_config->end_date
          || ($obj->periodic_invoices_config->end_date > DateTime->today_local))
      && $obj->periodic_invoices_config->get_previous_billed_period_start_date;

    $TMPL_VAR{oe_obj} = $obj;
  }

  $form->{defaultcurrency} = $form->get_default_currency(\%myconfig);

  $form->{employee_id} = $form->{old_employee_id} if $form->{old_employee_id};
  $form->{salesman_id} = $form->{old_salesman_id} if $form->{old_salesman_id};

  # openclosed checkboxes
  my @tmp;
  push @tmp, sprintf qq|<input name="delivered" id="delivered" type="checkbox" class="checkbox" value="1" %s><label for="delivered">%s</label>|,
                        $form->{"delivered"} ? "checked" : "",  $locale->text('Delivery Order(s) for full qty created') if $form->{"type"} =~ /_order$/;
  push @tmp, sprintf qq|<input name="closed" id="closed" type="checkbox" class="checkbox" value="1" %s><label for="closed">%s</label>|,
                        $form->{"closed"}    ? "checked" : "",  $locale->text('Closed')    if $form->{id};
  $TMPL_VAR{openclosed} = sprintf qq|<tr><td colspan=%d align=center>%s</td></tr>\n|, 2 * scalar @tmp, join "\n", @tmp if @tmp;

  my $vc = $form->{vc} eq "customer" ? "customers" : "vendors";

  $form->get_lists("taxzones"      => ($form->{id} ? "ALL_TAXZONES" : "ALL_ACTIVE_TAXZONES"),
                   "payments"      => "ALL_PAYMENTS",
                   "currencies"    => "ALL_CURRENCIES",
                   "departments"   => "ALL_DEPARTMENTS",
                   $vc             => { key   => "ALL_" . uc($vc),
                                        limit => $myconfig{vclimit} + 1 },
                   "price_factors" => "ALL_PRICE_FACTORS");

  # Projects
  my @old_project_ids = uniq grep { $_ } map { $_ * 1 } ($form->{"globalproject_id"}, map { $form->{"project_id_$_"} } 1..$form->{"rowcount"});
  my @old_ids_cond    = @old_project_ids ? (id => \@old_project_ids) : ();
  my @customer_cond;
  if (($vc eq 'customers') && $::instance_conf->get_customer_projects_only_in_sales) {
    @customer_cond = (
      or => [
        customer_id          => $::form->{customer_id},
        billable_customer_id => $::form->{customer_id},
      ]);
  }
  my @conditions = (
    or => [
      and => [ active => 1, @customer_cond ],
      @old_ids_cond,
    ]);

  $TMPL_VAR{ALL_PROJECTS}          = SL::DB::Manager::Project->get_all_sorted(query => \@conditions);
  $form->{ALL_PROJECTS}            = $TMPL_VAR{ALL_PROJECTS}; # make projects available for second row drop-down in io.pl

  # label subs
  my $employee_list_query_gen      = sub { $::form->{$_[0]} ? [ or => [ id => $::form->{$_[0]}, deleted => 0 ] ] : [ deleted => 0 ] };
  $TMPL_VAR{ALL_EMPLOYEES}         = SL::DB::Manager::Employee->get_all_sorted(query => $employee_list_query_gen->('employee_id'));
  $TMPL_VAR{ALL_SALESMEN}          = SL::DB::Manager::Employee->get_all_sorted(query => $employee_list_query_gen->('salesman_id'));
  $TMPL_VAR{ALL_SHIPTO}            = SL::DB::Manager::Shipto->get_all_sorted(query => [
    or => [ trans_id  => $::form->{"$::form->{vc}_id"} * 1, and => [ shipto_id => $::form->{shipto_id} * 1, trans_id => undef ] ]
  ]);
  $TMPL_VAR{ALL_CONTACTS}          = SL::DB::Manager::Contact->get_all_sorted(query => [
    or => [
      cp_cv_id => $::form->{"$::form->{vc}_id"} * 1,
      and      => [
        cp_cv_id => undef,
        cp_id    => $::form->{cp_id} * 1
      ]
    ]
  ]);
  $TMPL_VAR{sales_employee_labels} = sub { $_[0]->{name} || $_[0]->{login} };
  $TMPL_VAR{department_labels}     = sub { "$_[0]->{description}--$_[0]->{id}" };

  # vendor/customer
  $TMPL_VAR{vc_keys} = sub { "$_[0]->{name}--$_[0]->{id}" };
  $TMPL_VAR{vclimit} = $myconfig{vclimit};
  $TMPL_VAR{vc_select} = "customer_or_vendor_selection_window('$form->{vc}', '', @{[ $form->{vc} eq 'vendor' ? 1 : 0 ]}, 0)";
  push @custom_hiddens, "$form->{vc}_id";
  push @custom_hiddens, "old$form->{vc}";
  push @custom_hiddens, "select$form->{vc}";

  # currencies and exchangerate
  my @values = map { $_ } @{ $form->{ALL_CURRENCIES} };
  my %labels = map { $_ => $_ } @{ $form->{ALL_CURRENCIES} };
  $form->{currency}            = $form->{defaultcurrency} unless $form->{currency};
  $TMPL_VAR{show_exchangerate} = $form->{currency} ne $form->{defaultcurrency};
  $TMPL_VAR{currencies}        = NTI($cgi->popup_menu('-name' => 'currency', '-default' => $form->{"currency"},
                                                      '-values' => \@values, '-labels' => \%labels,
                                                      '-onchange' => "document.getElementById('update_button').click();"
                                     )) if scalar @values;
  push @custom_hiddens, "forex";
  push @custom_hiddens, "exchangerate" if $form->{forex};

  # credit remaining
  my $creditwarning = (($form->{creditlimit} != 0) && ($form->{creditremaining} < 0) && !$form->{update}) ? 1 : 0;
  $TMPL_VAR{is_credit_remaining_negativ} = ($form->{creditremaining} =~ /-/) ? "0" : "1";

  # business
  $TMPL_VAR{business_label} = ($form->{vc} eq "customer" ? $locale->text('Customer type') : $locale->text('Vendor type'));

  push @custom_hiddens, "customer_klass" if $form->{vc} eq 'customer';

  my $credittext = $locale->text('Credit Limit exceeded!!!');

  my $follow_up_vc                =  $form->{ $form->{vc} eq 'customer' ? 'customer' : 'vendor' };
  $follow_up_vc                   =~ s/--\d*\s*$//;
  $TMPL_VAR{follow_up_trans_info} =  ($form->{type} =~ /_quotation$/ ? $form->{quonumber} : $form->{ordnumber}) . " ($follow_up_vc)";

  if ($form->{id}) {
    my $follow_ups = FU->follow_ups('trans_id' => $form->{id});

    if (scalar @{ $follow_ups }) {
      $TMPL_VAR{num_follow_ups}     = scalar                    @{ $follow_ups };
      $TMPL_VAR{num_due_follow_ups} = sum map { $_->{due} * 1 } @{ $follow_ups };
    }
  }

  my $dispatch_to_popup = '';
  if ($form->{resubmit} && ($form->{format} eq "html")) {
      $dispatch_to_popup  = "window.open('about:blank','Beleg'); document.oe.target = 'Beleg';";
      $dispatch_to_popup .= "document.do.submit();";
  } elsif ($form->{resubmit}) {
    # emulate click for resubmitting actions
    $dispatch_to_popup  = "document.oe.${_}.click(); " for grep { /^action_/ } keys %$form;
  } elsif ($creditwarning) {
    $::request->{layout}->add_javascripts_inline("alert('$credittext');");
  }

  $::request->{layout}->add_javascripts_inline("\$(function(){$dispatch_to_popup});");
  $TMPL_VAR{dateformat}          = $myconfig{dateformat};
  $TMPL_VAR{numberformat}        = $myconfig{numberformat};

  if ($form->{type} eq 'sales_order') {
    if (!$form->{periodic_invoices_config}) {
      $form->{periodic_invoices_status} = $locale->text('not configured');

    } else {
      my $config                        = YAML::Load($form->{periodic_invoices_config});
      $form->{periodic_invoices_status} = $config->{active} ? $locale->text('active') : $locale->text('inactive');
    }
  }

  $::request->{layout}->use_javascript(map { "${_}.js" } qw(kivi.SalesPurchase show_form_details show_history show_vc_details ckeditor/ckeditor ckeditor/adapters/jquery kivi.io autocomplete_customer autocomplete_part));

  $form->header;
  if ($form->{CFDD_shipto} && $form->{CFDD_shipto_id} ) {
      $form->{shipto_id} = $form->{CFDD_shipto_id};
  }

  push @custom_hiddens, map { "shiptocvar_" . $_->name } @{ SL::DB::Manager::CustomVariableConfig->get_all(where => [ module => 'ShipTo' ]) };

  $TMPL_VAR{HIDDENS} = [ map { name => $_, value => $form->{$_} },
     qw(id action type vc formname media format proforma queued printed emailed
        title creditlimit creditremaining tradediscount business
        max_dunning_level dunning_amount shiptoname shiptostreet shiptozipcode
        CFDD_shipto CFDD_shipto_id shiptocity shiptocountry shiptogln shiptocontact shiptophone shiptofax
        shiptodepartment_1 shiptodepartment_2 shiptoemail shiptocp_gender
        message email subject cc bcc taxpart taxservice taxaccounts cursor_fokus
        show_details useasnew),
        @custom_hiddens,
        map { $_.'_rate', $_.'_description', $_.'_taxnumber' } split / /, $form->{taxaccounts} ];  # deleted: discount

  %TMPL_VAR = (
     %TMPL_VAR,
     is_sales        => scalar ($form->{type} =~ /^sales_/),              # these vars are exported, so that the template
     is_order        => scalar ($form->{type} =~ /_order$/),              # may determine what to show
     is_sales_quo    => scalar ($form->{type} =~ /sales_quotation$/),
     is_req_quo      => scalar ($form->{type} =~ /request_quotation$/),
     is_sales_ord    => scalar ($form->{type} =~ /sales_order$/),
     is_pur_ord      => scalar ($form->{type} =~ /purchase_order$/),
  );

  $TMPL_VAR{ORDER_PROBABILITIES} = [ map { { title => ($_ * 10) . '%', id => $_ * 10 } } (0..10) ];

  print $form->parse_html_template("oe/form_header", { %TMPL_VAR });

  $main::lxdebug->leave_sub();
}

sub form_footer {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  check_oe_access();

  $form->{invtotal} = $form->{invsubtotal};

  my $introws = max 5, $form->numtextrows($form->{intnotes}, 35, 8);

  $TMPL_VAR{notes}    = qq|<textarea name="notes" class="texteditor" wrap="soft" style="width: 350px; height: 150px">| . H($form->{notes}) . qq|</textarea>|;
  $TMPL_VAR{intnotes} = qq|<textarea name=intnotes rows="$introws" cols="35">| . H($form->{intnotes}) . qq|</textarea>|;

  if( $form->{customer_id} && !$form->{taxincluded_changed_by_user} ) {
    my $customer = SL::DB::Customer->new(id => $form->{customer_id})->load();
    $form->{taxincluded} = defined($customer->taxincluded_checked) ? $customer->taxincluded_checked : $myconfig{taxincluded_checked};
  }

  if (!$form->{taxincluded}) {

    foreach my $item (split / /, $form->{taxaccounts}) {
      if ($form->{"${item}_base"}) {
        $form->{invtotal} += $form->{"${item}_total"} = $form->round_amount( $form->{"${item}_base"} * $form->{"${item}_rate"}, 2);
        $form->{"${item}_total"} = $form->format_amount(\%myconfig, $form->{"${item}_total"}, 2);

        $TMPL_VAR{tax} .= qq|
              <tr>
                <th align=right>$form->{"${item}_description"}&nbsp;| . $form->{"${item}_rate"} * 100 .qq|%</th>
                <td align=right>$form->{"${item}_total"}</td>
              </tr> |;
      }
    }
  } else {
    foreach my $item (split / /, $form->{taxaccounts}) {
      if ($form->{"${item}_base"}) {
        $form->{"${item}_total"} = $form->round_amount( ($form->{"${item}_base"} * $form->{"${item}_rate"} / (1 + $form->{"${item}_rate"})), 2);
        $form->{"${item}_netto"} = $form->round_amount( ($form->{"${item}_base"} - $form->{"${item}_total"}), 2);
        $form->{"${item}_total"} = $form->format_amount(\%myconfig, $form->{"${item}_total"}, 2);
        $form->{"${item}_netto"} = $form->format_amount(\%myconfig, $form->{"${item}_netto"}, 2);

        $TMPL_VAR{tax} .= qq|
              <tr>
                <th align=right>Enthaltene $form->{"${item}_description"}&nbsp;| . $form->{"${item}_rate"} * 100 .qq|%</th>
                <td align=right>$form->{"${item}_total"}</td>
              </tr>
              <tr>
                <th align=right>Nettobetrag</th>
                <td align=right>$form->{"${item}_netto"}</td>
              </tr> |;
      }
    }
  }

  $form->{rounding} = $form->round_amount(
    $form->round_amount($form->{invtotal}, 2, 1) - $form->round_amount($form->{invtotal}, 2)
  );
  $form->{invtotal} = $form->round_amount( $form->{invtotal}, 2, 1);
  $form->{oldinvtotal} = $form->{invtotal};

  $TMPL_VAR{ALL_DELIVERY_TERMS} = SL::DB::Manager::DeliveryTerm->get_all_sorted();

  my $tpca_reminder;
  $tpca_reminder = check_transport_cost_reminder_article_number() if $::instance_conf->get_transport_cost_reminder_article_number_id;
  print $form->parse_html_template("oe/form_footer", {
     %TMPL_VAR,
     tpca_reminder   => $tpca_reminder,
     print_options   => print_options(inline => 1),
     label_edit      => $locale->text("Edit the $form->{type}"),
     label_workflow  => $locale->text("Workflow $form->{type}"),
     is_sales        => scalar ($form->{type} =~ /^sales_/),              # these vars are exported, so that the template
     is_order        => scalar ($form->{type} =~ /_order$/),              # may determine what to show
     is_sales_quo    => scalar ($form->{type} =~ /sales_quotation$/),
     is_req_quo      => scalar ($form->{type} =~ /request_quotation$/),
     is_sales_ord    => scalar ($form->{type} =~ /sales_order$/),
     is_pur_ord      => scalar ($form->{type} =~ /purchase_order$/),
  });

  $main::lxdebug->leave_sub();
}

sub update {
  $main::lxdebug->enter_sub();

  my ($recursive_call) = @_;

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  check_oe_access();

  set_headings($form->{"id"} ? "edit" : "add");

  $form->{update} = 1;

  &check_name($form->{vc});

  if (!$form->{forex}) {        # read exchangerate from input field (not hidden)
    map { $form->{$_} = $form->parse_amount(\%myconfig, $form->{$_}) } qw(exchangerate) unless $recursive_call;
  }
  my $buysell           = 'buy';
  $buysell              = 'sell' if ($form->{vc} eq 'vendor');
  $form->{forex}        = $form->check_exchangerate(\%myconfig, $form->{currency}, $form->{transdate}, $buysell);
  $form->{exchangerate} = $form->{forex} if $form->{forex};

  my $exchangerate = $form->{exchangerate} || 1;

##################### process items ######################################
  # for pricegroups
  my $i = $form->{rowcount};
  if (   ($form->{"partnumber_$i"} eq "")
      && ($form->{"description_$i"} eq "")
      && ($form->{"partsgroup_$i"}  eq "")) {

    $form->{creditremaining} += ($form->{oldinvtotal} - $form->{oldtotalpaid});

    &check_form;
  } else {

    my $mode;
    if ($form->{type} =~ /^sales/) {
      IS->retrieve_item(\%myconfig, \%$form);
      $mode = 'IS';
    } else {
      IR->retrieve_item(\%myconfig, \%$form);
      $mode = 'IR';
    }

    my $rows = scalar @{ $form->{item_list} };

    $form->{"discount_$i"}   = $form->parse_amount(\%myconfig, $form->{"discount_$i"}) / 100.0;
    $form->{"discount_$i"} ||= $form->{"$form->{vc}_discount"};

    $form->{"lastcost_$i"} = $form->parse_amount(\%myconfig, $form->{"lastcost_$i"});

    if ($rows) {

      $form->{"qty_$i"} = $form->parse_amount(\%myconfig, $form->{"qty_$i"});
      if( !$form->{"qty_$i"} ) {
        $form->{"qty_$i"} = 1;
      }

      if ($rows > 1) {

        select_item(mode => $mode, pre_entered_qty => $form->{"qty_$i"});
        $::dispatcher->end_request;

      } else {

        my $sellprice             = $form->parse_amount(\%myconfig, $form->{"sellprice_$i"});
        # hier werden parts (Artikeleigenschaften) aus item_list (retrieve_item aus IS.pm)
        # (item wahrscheinlich synonym für parts) entsprechend in die form geschrieben ...

        # Wäre dieses Mapping nicht besser in retrieve_items aufgehoben?
        #(Eine Funktion bekommt Daten -> ARBEIT -> Rückgabe DATEN)
        #  Das quot sieht doch auch nach Überarbeitung aus ... (hmm retrieve_items gibt es in IS und IR)
        map { $form->{item_list}[$i]{$_} =~ s/\"/&quot;/g }    qw(partnumber description unit);
        map { $form->{"${_}_$i"} = $form->{item_list}[0]{$_} } keys %{ $form->{item_list}[0] };

        # ... deswegen muss die prüfung, ob es sich um einen nicht rabattierfähigen artikel handelt später erfolgen (Bug 1136)
        $form->{"discount_$i"} = 0 if $form->{"not_discountable_$i"};
        $form->{payment_id} = $form->{"part_payment_id_$i"} if $form->{"part_payment_id_$i"} ne "";

        $form->{"marge_price_factor_$i"} = $form->{item_list}->[0]->{price_factor};

        ($sellprice || $form->{"sellprice_$i"}) =~ /\.(\d+)/;
        my $dec_qty       = length $1;
        my $decimalplaces = max 2, $dec_qty;

        if ($sellprice) {
          $form->{"sellprice_$i"} = $sellprice;
        } else {
          my $record        = _make_record();
          my $price_source  = SL::PriceSource->new(record_item => $record->items->[$i-1], record => $record);
          my $best_price    = $price_source->best_price;
          my $best_discount = $price_source->best_discount;

          if ($best_price) {
            $::form->{"sellprice_$i"}           = $best_price->price;
            $::form->{"active_price_source_$i"} = $best_price->source;
          }
          if ($best_discount) {
            $::form->{"discount_$i"}               = $best_discount->discount;
            $::form->{"active_discount_source_$i"} = $best_discount->source;
          }

          $form->{"sellprice_$i"} /= $exchangerate;   # if there is an exchange rate adjust sellprice
        }

        my $amount = $form->{"sellprice_$i"} * $form->{"qty_$i"} * (1 - $form->{"discount_$i"});
        map { $form->{"${_}_base"} = 0 }                                 split / /, $form->{taxaccounts};
        map { $form->{"${_}_base"} += $amount }                          split / /, $form->{"taxaccounts_$i"};
        map { $amount += ($form->{"${_}_base"} * $form->{"${_}_rate"}) } split / /, $form->{taxaccounts} if !$form->{taxincluded};

        $form->{creditremaining} -= $amount;

        $form->{"sellprice_$i"} = $form->format_amount(\%myconfig, $form->{"sellprice_$i"}, $decimalplaces);
        $form->{"lastcost_$i"}  = $form->format_amount(\%myconfig, $form->{"lastcost_$i"}, $decimalplaces);
        $form->{"qty_$i"}       = $form->format_amount(\%myconfig, $form->{"qty_$i"}, $dec_qty);
        $form->{"discount_$i"}  = $form->format_amount(\%myconfig, $form->{"discount_$i"} * 100.0);
      }

      display_form();
    } else {

      # ok, so this is a new part
      # ask if it is a part or service item

      if (   $form->{"partsgroup_$i"}
          && ($form->{"partsnumber_$i"} eq "")
          && ($form->{"description_$i"} eq "")) {
        $form->{rowcount}--;
        $form->{"discount_$i"} = "";

        display_form();
      } else {
        $form->{"id_$i"}   = 0;
        new_item();
      }
    }
  }
##################### process items ######################################


  $main::lxdebug->leave_sub();
}

sub search {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  check_oe_access();

  if ($form->{type} eq 'purchase_order') {
    $form->{vc}        = 'vendor';
    $form->{ordnrname} = 'ordnumber';
    $form->{title}     = $locale->text('Purchase Orders');
    $form->{ordlabel}  = $locale->text('Order Number');

  } elsif ($form->{type} eq 'request_quotation') {
    $form->{vc}        = 'vendor';
    $form->{ordnrname} = 'quonumber';
    $form->{title}     = $locale->text('Request for Quotations');
    $form->{ordlabel}  = $locale->text('RFQ Number');

  } elsif ($form->{type} eq 'sales_order') {
    $form->{vc}        = 'customer';
    $form->{ordnrname} = 'ordnumber';
    $form->{title}     = $locale->text('Sales Orders');
    $form->{ordlabel}  = $locale->text('Order Number');

  } elsif ($form->{type} eq 'sales_quotation') {
    $form->{vc}        = 'customer';
    $form->{ordnrname} = 'quonumber';
    $form->{title}     = $locale->text('Quotations');
    $form->{ordlabel}  = $locale->text('Quotation Number');

  } else {
    $form->show_generic_error($locale->text('oe.pl::search called with unknown type'), back_button => 1);
  }

  # setup vendor / customer data
  $form->all_vc(\%myconfig, $form->{vc}, ($form->{vc} eq 'customer') ? "AR" : "AP");
  $form->get_lists("projects"     => { "key" => "ALL_PROJECTS", "all" => 1 },
                   "departments"  => "ALL_DEPARTMENTS",
                   "$form->{vc}s" => "ALL_VC",
                   "taxzones"     => "ALL_TAXZONES",
                   "business_types" => "ALL_BUSINESS_TYPES",);
  $form->{ALL_EMPLOYEES} = SL::DB::Manager::Employee->get_all_sorted(query => [ deleted => 0 ]);

  $form->{CT_CUSTOM_VARIABLES}                  = CVar->get_configs('module' => 'CT');
  ($form->{CT_CUSTOM_VARIABLES_FILTER_CODE},
   $form->{CT_CUSTOM_VARIABLES_INCLUSION_CODE}) = CVar->render_search_options('variables'      => $form->{CT_CUSTOM_VARIABLES},
                                                                              'include_prefix' => 'l_',
                                                                              'include_value'  => 'Y');

  # constants and subs for template
  $form->{vc_keys}         = sub { "$_[0]->{name}--$_[0]->{id}" };

  $form->{ORDER_PROBABILITIES} = [ map { { title => ($_ * 10) . '%', id => $_ * 10 } } (0..10) ];

  $form->header();

  print $form->parse_html_template('oe/search', {
    is_order => scalar($form->{type} =~ /_order/),
  });

  $main::lxdebug->leave_sub();
}

sub create_subtotal_row {
  $main::lxdebug->enter_sub();

  my ($totals, $columns, $column_alignment, $subtotal_columns, $class) = @_;

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  my $row = { map { $_ => { 'data' => '', 'class' => $class, 'align' => $column_alignment->{$_}, } } @{ $columns } };

  map { $row->{$_}->{data} = $form->format_amount(\%myconfig, $totals->{$_}, 2) } @{ $subtotal_columns };

  $row->{tax}->{data} = $form->format_amount(\%myconfig, $totals->{amount} - $totals->{netamount}, 2);

  map { $totals->{$_} = 0 } @{ $subtotal_columns };

  $main::lxdebug->leave_sub();

  return $row;
}

sub orders {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;
  my $cgi      = $::request->{cgi};

  check_oe_access();

  my $ordnumber = ($form->{type} =~ /_order$/) ? "ordnumber" : "quonumber";

  ($form->{ $form->{vc} }, $form->{"$form->{vc}_id"}) = split(/--/, $form->{ $form->{vc} });

  report_generator_set_default_sort('transdate', 1);

  OE->transactions(\%myconfig, \%$form);

  $form->{rowcount} = scalar @{ $form->{OE} };

  my @columns = (
    "transdate",               "reqdate",
    "id",                      $ordnumber,             "edit_exp",
    "cusordnumber",            "customernumber",
    "name",                    "netamount",
    "tax",                     "amount",
    "remaining_netamount",     "remaining_amount",
    "curr",                    "employee",
    "salesman",
    "shipvia",                 "globalprojectnumber",
    "transaction_description", "open",
    "delivered",               "periodic_invoices",
    "marge_total",             "marge_percent",
    "vcnumber",                "ustid",
    "country",                 "shippingpoint",
    "taxzone",                 "insertdate",
    "order_probability",       "expected_billing_date", "expected_netamount",
    "payment_terms",
  );

  # only show checkboxes if gotten here via sales_order form.
  my $allow_multiple_orders = $form->{type} eq 'sales_order';
  if ($allow_multiple_orders) {
    unshift @columns, "ids";
  }

  $form->{l_open}              = $form->{l_closed} = "Y" if ($form->{open}      && $form->{closed});
  $form->{l_delivered}         = "Y"                     if ($form->{delivered} && $form->{notdelivered});
  $form->{l_periodic_invoices} = "Y"                     if ($form->{periodic_invoices_active} && $form->{periodic_invoices_inactive});
  $form->{l_edit_exp}          = "Y"                     if (any { $form->{type} eq $_ } qw(sales_order purchase_order));
  map { $form->{"l_${_}"} = 'Y' } qw(order_probability expected_billing_date expected_netamount) if $form->{l_order_probability_expected_billing_date};

  my $attachment_basename;
  if ($form->{vc} eq 'vendor') {
    if ($form->{type} eq 'purchase_order') {
      $form->{title}       = $locale->text('Purchase Orders');
      $attachment_basename = $locale->text('purchase_order_list');
    } else {
      $form->{title}       = $locale->text('Request for Quotations');
      $attachment_basename = $locale->text('rfq_list');
    }

  } else {
    if ($form->{type} eq 'sales_order') {
      $form->{title}       = $locale->text('Sales Orders');
      $attachment_basename = $locale->text('sales_order_list');
    } else {
      $form->{title}       = $locale->text('Quotations');
      $attachment_basename = $locale->text('quotation_list');
    }
  }

  my $report = SL::ReportGenerator->new(\%myconfig, $form);

  my $ct_cvar_configs = CVar->get_configs('module' => 'CT');
  my @ct_includeable_custom_variables = grep { $_->{includeable} } @{ $ct_cvar_configs };
  my @ct_searchable_custom_variables  = grep { $_->{searchable} }  @{ $ct_cvar_configs };

  my %column_defs_cvars            = map { +"cvar_$_->{name}" => { 'text' => $_->{description} } } @ct_includeable_custom_variables;
  push @columns, map { "cvar_$_->{name}" } @ct_includeable_custom_variables;

  my @hidden_variables = map { "l_${_}" } @columns;
  push @hidden_variables, "l_subtotal", $form->{vc}, qw(l_closed l_notdelivered open closed delivered notdelivered ordnumber quonumber cusordnumber
                                                        transaction_description transdatefrom transdateto type vc employee_id salesman_id
                                                        reqdatefrom reqdateto projectnumber project_id periodic_invoices_active periodic_invoices_inactive
                                                        business_id shippingpoint taxzone_id reqdate_unset_or_old insertdatefrom insertdateto
                                                        order_probability_op order_probability_value expected_billing_date_from expected_billing_date_to
                                                        parts_partnumber parts_description);
  push @hidden_variables, map { "cvar_$_->{name}" } @ct_searchable_custom_variables;

  my   @keys_for_url = grep { $form->{$_} } @hidden_variables;
  push @keys_for_url, 'taxzone_id' if $form->{taxzone_id} ne ''; # taxzone_id could be 0

  my $href = build_std_url('action=orders', @keys_for_url);

  my %column_defs = (
    'ids'                     => { 'text' => '', },
    'transdate'               => { 'text' => $locale->text('Date'), },
    'reqdate'                 => { 'text' => $form->{type} =~ /_order/ ? $locale->text('Required by') : $locale->text('Valid until') },
    'id'                      => { 'text' => $locale->text('ID'), },
    'ordnumber'               => { 'text' => $locale->text('Order'), },
    'quonumber'               => { 'text' => $form->{type} eq "request_quotation" ? $locale->text('RFQ') : $locale->text('Quotation'), },
    'cusordnumber'            => { 'text' => $locale->text('Customer Order Number'), },
    'name'                    => { 'text' => $form->{vc} eq 'customer' ? $locale->text('Customer') : $locale->text('Vendor'), },
    'customernumber'          => { 'text' => $locale->text('Customer Number'), },
    'netamount'               => { 'text' => $locale->text('Amount'), },
    'tax'                     => { 'text' => $locale->text('Tax'), },
    'amount'                  => { 'text' => $locale->text('Total'), },
    'remaining_amount'        => { 'text' => $locale->text('Remaining Amount'), },
    'remaining_netamount'     => { 'text' => $locale->text('Remaining Net Amount'), },
    'curr'                    => { 'text' => $locale->text('Curr'), },
    'employee'                => { 'text' => $locale->text('Employee'), },
    'salesman'                => { 'text' => $locale->text('Salesman'), },
    'shipvia'                 => { 'text' => $locale->text('Ship via'), },
    'globalprojectnumber'     => { 'text' => $locale->text('Project Number'), },
    'transaction_description' => { 'text' => $locale->text('Transaction description'), },
    'open'                    => { 'text' => $locale->text('Open'), },
    'delivered'               => { 'text' => $locale->text('Delivery Order created'), },
    'marge_total'             => { 'text' => $locale->text('Ertrag'), },
    'marge_percent'           => { 'text' => $locale->text('Ertrag prozentual'), },
    'vcnumber'                => { 'text' => $form->{vc} eq 'customer' ? $locale->text('Customer Number') : $locale->text('Vendor Number'), },
    'country'                 => { 'text' => $locale->text('Country'), },
    'ustid'                   => { 'text' => $locale->text('USt-IdNr.'), },
    'periodic_invoices'       => { 'text' => $locale->text('Per. Inv.'), },
    'shippingpoint'           => { 'text' => $locale->text('Shipping Point'), },
    'taxzone'                 => { 'text' => $locale->text('Steuersatz'), },
    'insertdate'              => { 'text' => $locale->text('Insert Date'), },
    'order_probability'       => { 'text' => $locale->text('Order probability'), },
    'expected_billing_date'   => { 'text' => $locale->text('Exp. bill. date'), },
    'expected_netamount'      => { 'text' => $locale->text('Exp. netamount'), },
    'payment_terms'           => { 'text' => $locale->text('Payment Terms'), },
    'edit_exp'                => { 'text' => $locale->text('Edit (experimental)'), },
    %column_defs_cvars,
  );

  foreach my $name (qw(id transdate reqdate quonumber ordnumber cusordnumber name employee salesman shipvia transaction_description shippingpoint taxzone insertdate payment_terms)) {
    my $sortdir                 = $form->{sort} eq $name ? 1 - $form->{sortdir} : $form->{sortdir};
    $column_defs{$name}->{link} = $href . "&sort=$name&sortdir=$sortdir";
  }

  my %column_alignment = map { $_ => 'right' } qw(netamount tax amount curr remaining_amount remaining_netamount order_probability expected_billing_date expected_netamount);

  $form->{"l_type"} = "Y";
  map { $column_defs{$_}->{visible} = $form->{"l_${_}"} ? 1 : 0 } @columns;
  $column_defs{ids}->{visible} = $allow_multiple_orders ? 'HTML' : 0;

  $report->set_columns(%column_defs);
  $report->set_column_order(@columns);
  $report->set_export_options('orders', @hidden_variables, qw(sort sortdir));
  $report->set_sort_indicator($form->{sort}, $form->{sortdir});

  CVar->add_custom_variables_to_report('module'         => 'CT',
                                       'trans_id_field' => "$form->{vc}_id",
                                       'configs'        => $ct_cvar_configs,
                                       'column_defs'    => \%column_defs,
                                       'data'           => $form->{OE});

  my @options;
  my ($department) = split m/--/, $form->{department};

  push @options, $locale->text('Customer')                . " : $form->{customer}"                        if $form->{customer};
  push @options, $locale->text('Vendor')                  . " : $form->{vendor}"                          if $form->{vendor};
  push @options, $locale->text('Contact Person')          . " : $form->{cp_name}"                         if $form->{cp_name};
  push @options, $locale->text('Department')              . " : $department"                              if $form->{department};
  push @options, $locale->text('Order Number')            . " : $form->{ordnumber}"                       if $form->{ordnumber};
  push @options, $locale->text('Customer Order Number')   . " : $form->{cusordnumber}"                    if $form->{cusordnumber};
  push @options, $locale->text('Notes')                   . " : $form->{notes}"                           if $form->{notes};
  push @options, $locale->text('Transaction description') . " : $form->{transaction_description}"         if $form->{transaction_description};
  push @options, $locale->text('Quick Search')            . " : $form->{all}"                             if $form->{all};
  push @options, $locale->text('Shipping Point')          . " : $form->{shippingpoint}"                   if $form->{shippingpoint};
  push @options, $locale->text('Part Description')        . " : $form->{parts_description}"               if $form->{parts_description};
  push @options, $locale->text('Part Number')             . " : $form->{parts_partnumber}"                if $form->{parts_partnumber};
  if ( $form->{transdatefrom} or $form->{transdateto} ) {
    push @options, $locale->text('Order Date');
    push @options, $locale->text('From') . " " . $locale->date(\%myconfig, $form->{transdatefrom}, 1)     if $form->{transdatefrom};
    push @options, $locale->text('Bis')  . " " . $locale->date(\%myconfig, $form->{transdateto},   1)     if $form->{transdateto};
  };
  if ( $form->{reqdatefrom} or $form->{reqdateto} ) {
    push @options, $locale->text('Delivery Date');
    push @options, $locale->text('From') . " " . $locale->date(\%myconfig, $form->{reqdatefrom}, 1)       if $form->{reqdatefrom};
    push @options, $locale->text('Bis')  . " " . $locale->date(\%myconfig, $form->{reqdateto},   1)       if $form->{reqdateto};
  };
  if ( $form->{insertdatefrom} or $form->{insertdateto} ) {
    push @options, $locale->text('Insert Date');
    push @options, $locale->text('From') . " " . $locale->date(\%myconfig, $form->{insertdatefrom}, 1)    if $form->{insertdatefrom};
    push @options, $locale->text('Bis')  . " " . $locale->date(\%myconfig, $form->{insertdateto},   1)    if $form->{insertdateto};
  };
  push @options, $locale->text('Open')                                                                    if $form->{open};
  push @options, $locale->text('Closed')                                                                  if $form->{closed};
  push @options, $locale->text('Delivery Order created')                                                               if $form->{delivered};
  push @options, $locale->text('Not delivered')                                                           if $form->{notdelivered};
  push @options, $locale->text('Periodic invoices active')                                                if $form->{periodic_invoices_active};
  push @options, $locale->text('Reqdate not set or before current month')                                 if $form->{reqdate_unset_or_old};

  if ($form->{business_id}) {
    my $vc_type_label = $form->{vc} eq 'customer' ? $locale->text('Customer type') : $locale->text('Vendor type');
    push @options, $vc_type_label . " : " . SL::DB::Business->new(id => $form->{business_id})->load->description;
  }
  if ($form->{taxzone_id} ne '') { # taxzone_id could be 0
    push @options, $locale->text('Steuersatz') . " : " . SL::DB::TaxZone->new(id => $form->{taxzone_id})->load->description;
  }

  if (($form->{order_probability_value} || '') ne '') {
    push @options, $::locale->text('Order probability') . ' ' . ($form->{order_probability_op} eq 'le' ? '<=' : '>=') . ' ' . $form->{order_probability_value} . '%';
  }

  if ($form->{expected_billing_date_from} or $form->{expected_billing_date_to}) {
    push @options, $locale->text('Expected billing date');
    push @options, $locale->text('From') . " " . $locale->date(\%myconfig, $form->{expected_billing_date_from}, 1) if $form->{expected_billing_date_from};
    push @options, $locale->text('Bis')  . " " . $locale->date(\%myconfig, $form->{expected_billing_date_to},   1) if $form->{expected_billing_date_to};
  }

  $report->set_options('top_info_text'        => join("\n", @options),
                       'raw_top_info_text'    => $form->parse_html_template('oe/orders_top'),
                       'raw_bottom_info_text' => $form->parse_html_template('oe/orders_bottom', { 'SHOW_CONTINUE_BUTTON' => $allow_multiple_orders }),
                       'output_format'        => 'HTML',
                       'title'                => $form->{title},
                       'attachment_basename'  => $attachment_basename . strftime('_%Y%m%d', localtime time),
    );
  $report->set_options_from_form();
  $locale->set_numberformat_wo_thousands_separator(\%myconfig) if lc($report->{options}->{output_format}) eq 'csv';

  # add sort and escape callback, this one we use for the add sub
  $form->{callback} = $href .= "&sort=$form->{sort}";

  # escape callback for href
  my $callback = $form->escape($href);

  my @subtotal_columns = qw(netamount amount marge_total marge_percent remaining_amount remaining_netamount);
  push @subtotal_columns, 'expected_netamount' if $form->{l_order_probability_expected_billing_date};

  my %totals    = map { $_ => 0 } @subtotal_columns;
  my %subtotals = map { $_ => 0 } @subtotal_columns;

  my $idx = 1;

  my $edit_url = build_std_url('action=edit', 'type', 'vc');

  foreach my $oe (@{ $form->{OE} }) {
    map { $oe->{$_} *= $oe->{exchangerate} } @subtotal_columns;

    $oe->{tax}               = $oe->{amount} - $oe->{netamount};
    $oe->{open}              = $oe->{closed}            ? $locale->text('No')  : $locale->text('Yes');
    $oe->{delivered}         = $oe->{delivered}         ? $locale->text('Yes') : $locale->text('No');
    $oe->{periodic_invoices} = $oe->{periodic_invoices} ? $locale->text('On')  : $locale->text('Off');

    map { $subtotals{$_} += $oe->{$_};
          $totals{$_}    += $oe->{$_} } @subtotal_columns;

    $subtotals{marge_percent} = $subtotals{netamount} ? ($subtotals{marge_total} * 100 / $subtotals{netamount}) : 0;
    $totals{marge_percent}    = $totals{netamount}    ? ($totals{marge_total}    * 100 / $totals{netamount}   ) : 0;

    map { $oe->{$_} = $form->format_amount(\%myconfig, $oe->{$_}, 2) } qw(netamount tax amount marge_total marge_percent remaining_amount remaining_netamount expected_netamount);

    $oe->{order_probability} = ($oe->{order_probability} || 0) . '%';

    my $row = { };

    foreach my $column (@columns) {
      next if ($column eq 'ids');
      next if ($column eq 'edit_exp');
      $row->{$column} = {
        'data'  => $oe->{$column},
        'align' => $column_alignment{$column},
      };
    }

    $row->{ids} = {
      'raw_data' =>   $cgi->hidden('-name' => "trans_id_${idx}", '-value' => $oe->{id})
                    . $cgi->checkbox('-name' => "multi_id_${idx}", '-value' => 1, '-label' => ''),
      'valign'   => 'center',
      'align'    => 'center',
    };

    $row->{$ordnumber}->{link} = $edit_url . "&id=" . E($oe->{id}) . "&callback=${callback}";

    $row->{edit_exp}->{data}   = $oe->{ordnumber};
    $row->{edit_exp}->{link}   = build_std_url('script=controller.pl', 'action=Order/edit', "type=$form->{type}", 'id=' . E($oe->{id}));

    my $row_set = [ $row ];

    if (($form->{l_subtotal} eq 'Y')
        && (($idx == (scalar @{ $form->{OE} }))
            || ($oe->{ $form->{sort} } ne $form->{OE}->[$idx]->{ $form->{sort} }))) {
      push @{ $row_set }, create_subtotal_row(\%subtotals, \@columns, \%column_alignment, \@subtotal_columns, 'listsubtotal');
    }

    $report->add_data($row_set);

    $idx++;
  }

  $report->add_separator();
  $report->add_data(create_subtotal_row(\%totals, \@columns, \%column_alignment, \@subtotal_columns, 'listtotal'));

  $report->generate_with_headers();

  $main::lxdebug->leave_sub();
}

sub check_delivered_flag {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  check_oe_access();

  if (($form->{type} ne 'sales_order') && ($form->{type} ne 'purchase_order')) {
    return $main::lxdebug->leave_sub();
  }

  my $all_delivered = 0;

  foreach my $i (1 .. $form->{rowcount}) {
    next if (!$form->{"id_$i"});

    if ($form->parse_amount(\%myconfig, $form->{"qty_$i"}) == $form->parse_amount(\%myconfig, $form->{"ship_$i"})) {
      $all_delivered = 1;
      next;
    }

    $all_delivered = 0;
    last;
  }

  $form->{delivered} = 1 if $all_delivered;

  $main::lxdebug->leave_sub();
}

sub save_and_close {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  check_oe_access();
  $form->mtime_ischanged('oe');

  $form->{defaultcurrency} = $form->get_default_currency(\%myconfig);

  if ($form->{type} =~ /_order$/) {
    $form->isblank("transdate", $locale->text('Order Date missing!'));
  } else {
    $form->isblank("transdate", $locale->text('Quotation Date missing!'));
  }

  my $idx = $form->{type} =~ /_quotation$/ ? "quonumber" : "ordnumber";
  $form->{$idx} =~ s/^\s*//g;
  $form->{$idx} =~ s/\s*$//g;

  my $msg = ucfirst $form->{vc};
  $form->isblank($form->{vc}, $locale->text($msg . " missing!"));

  # $locale->text('Customer missing!');
  # $locale->text('Vendor missing!');

  $form->isblank("exchangerate", $locale->text('Exchangerate missing!'))
    if ($form->{currency} ne $form->{defaultcurrency});

  &validate_items;

  my $payment_id;
  if($form->{payment_id}) {
    $payment_id = $form->{payment_id};
  }

  # if the name changed get new values
  if (&check_name($form->{vc})) {
    if($form->{payment_id} eq "") {
      $form->{payment_id} = $payment_id;
    }
    &update;
    $::dispatcher->end_request;
  }

  $form->{id} = 0 if $form->{saveasnew};

  my ($numberfld, $ordnumber, $err);
  # this is for the internal notes section for the [email] Subject
  if ($form->{type} =~ /_order$/) {
    if ($form->{type} eq 'sales_order') {
      $form->{label} = $locale->text('Sales Order');

      $numberfld = "sonumber";
      $ordnumber = "ordnumber";
    } else {
      $form->{label} = $locale->text('Purchase Order');

      $numberfld = "ponumber";
      $ordnumber = "ordnumber";
    }

    $err = $locale->text('Cannot save order!');

    check_delivered_flag();

  } else {
    if ($form->{type} eq 'sales_quotation') {
      $form->{label} = $locale->text('Quotation');

      $numberfld = "sqnumber";
      $ordnumber = "quonumber";
    } else {
      $form->{label} = $locale->text('Request for Quotation');

      $numberfld = "rfqnumber";
      $ordnumber = "quonumber";
    }

    $err = $locale->text('Cannot save quotation!');

  }

  # get new number in sequence if saveasnew was requested
  delete $form->{$ordnumber} if $form->{saveasnew};

  relink_accounts();

  $form->error($err) if (!OE->save(\%myconfig, \%$form));

  # saving the history
  if(!exists $form->{addition}) {
    $form->{snumbers} = qq|ordnumber_| . $form->{ordnumber};
    $form->{addition} = "SAVED";
    $form->save_history;
  }
  # /saving the history

  $form->redirect($form->{label} . " $form->{$ordnumber} " .
                  $locale->text('saved!'));

  $main::lxdebug->leave_sub();
}

sub save {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  check_oe_access();

  $form->mtime_ischanged('oe');
  $form->{defaultcurrency} = $form->get_default_currency(\%myconfig);


  if ($form->{type} =~ /_order$/) {
    $form->isblank("transdate", $locale->text('Order Date missing!'));
  } else {
    $form->isblank("transdate", $locale->text('Quotation Date missing!'));
  }

  my $idx = $form->{type} =~ /_quotation$/ ? "quonumber" : "ordnumber";
  $form->{$idx} =~ s/^\s*//g;
  $form->{$idx} =~ s/\s*$//g;

  my $msg = ucfirst $form->{vc};
  $form->isblank($form->{vc}, $locale->text($msg . " missing!"));

  # $locale->text('Customer missing!');
  # $locale->text('Vendor missing!');

  $form->isblank("exchangerate", $locale->text('Exchangerate missing!'))
    if ($form->{currency} ne $form->{defaultcurrency});

  remove_emptied_rows();
  &validate_items;

  my $payment_id;
  if($form->{payment_id}) {
    $payment_id = $form->{payment_id};
  }

  # if the name changed get new values
  if (&check_name($form->{vc})) {
    if($form->{payment_id} eq "") {
      $form->{payment_id} = $payment_id;
    }
    &update;
    $::dispatcher->end_request;
  }

  $form->{id} = 0 if $form->{saveasnew};

  my ($numberfld, $ordnumber, $err);

  # this is for the internal notes section for the [email] Subject
  if ($form->{type} =~ /_order$/) {
    if ($form->{type} eq 'sales_order') {
      $form->{label} = $locale->text('Sales Order');

      $numberfld = "sonumber";
      $ordnumber = "ordnumber";
    } else {
      $form->{label} = $locale->text('Purchase Order');

      $numberfld = "ponumber";
      $ordnumber = "ordnumber";
    }

    $err = $locale->text('Cannot save order!');

    check_delivered_flag();

  } else {
    if ($form->{type} eq 'sales_quotation') {
      $form->{label} = $locale->text('Quotation');

      $numberfld = "sqnumber";
      $ordnumber = "quonumber";
    } else {
      $form->{label} = $locale->text('Request for Quotation');

      $numberfld = "rfqnumber";
      $ordnumber = "quonumber";
    }

    $err = $locale->text('Cannot save quotation!');

  }

  relink_accounts();

  OE->save(\%myconfig, \%$form);

  # saving the history
  if(!exists $form->{addition}) {
    if ( $form->{formname} eq 'sales_quotation' or  $form->{formname} eq 'request_quotation' ) {
        $form->{snumbers} = qq|quonumber_| . $form->{quonumber};
    } elsif ( $form->{formname} eq 'sales_order' or $form->{formname} eq 'purchase_order') {
        $form->{snumbers} = qq|ordnumber_| . $form->{ordnumber};
    };
    $form->{what_done} = $form->{formname};
    $form->{addition} = "SAVED";
    $form->save_history;
  }
  # /saving the history

  $form->{simple_save} = 1;
  if(!$form->{print_and_save}) {
    delete @{$form}{ary_diff([keys %{ $form }], [qw(login id script type cursor_fokus)])};
    edit();
    $::dispatcher->end_request;
  }
  $main::lxdebug->leave_sub();
}

sub delete {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  check_oe_access();

  my ($msg, $err);
  if ($form->{type} =~ /_order$/) {
    $msg = $locale->text('Order deleted!');
    $err = $locale->text('Cannot delete order!');
  } else {
    $msg = $locale->text('Quotation deleted!');
    $err = $locale->text('Cannot delete quotation!');
  }
  if (OE->delete(\%myconfig, \%$form)){
    # saving the history
    if(!exists $form->{addition}) {
      if ( $form->{formname} eq 'sales_quotation' or  $form->{formname} eq 'request_quotation' ) {
          $form->{snumbers} = qq|quonumber_| . $form->{quonumber};
      } elsif ( $form->{formname} eq 'sales_order' or $form->{formname} eq 'purchase_order') {
          $form->{snumbers} = qq|ordnumber_| . $form->{ordnumber};
      };
        $form->{what_done} = $form->{formname};
        $form->{addition} = "DELETED";
        $form->save_history;
    }
    # /saving the history
    $form->info($msg);
    $::dispatcher->end_request;
  }
  $form->error($err);

  $main::lxdebug->leave_sub();
}

sub invoice {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  check_oe_access();
  check_oe_conversion_to_sales_invoice_allowed();
  $form->mtime_ischanged('oe');

  $main::auth->assert($form->{type} eq 'purchase_order' || $form->{type} eq 'request_quotation' ? 'vendor_invoice_edit' : 'invoice_edit');

  $form->{old_salesman_id} = $form->{salesman_id};
  $form->get_employee();


  if ($form->{type} =~ /_order$/) {

    # these checks only apply if the items don't bring their own ordnumbers/transdates.
    # The if clause ensures that by searching for empty ordnumber_#/transdate_# fields.
    $form->isblank("ordnumber", $locale->text('Order Number missing!'))
      if (+{ map { $form->{"ordnumber_$_"}, 1 } (1 .. $form->{rowcount} - 1) }->{''});
    $form->isblank("transdate", $locale->text('Order Date missing!'))
      if (+{ map { $form->{"transdate_$_"}, 1 } (1 .. $form->{rowcount} - 1) }->{''});

    # also copy deliverydate from the order
    $form->{deliverydate} = $form->{reqdate} if $form->{reqdate};
    $form->{orddate}      = $form->{transdate};
  } else {
    $form->isblank("quonumber", $locale->text('Quotation Number missing!'));
    $form->isblank("transdate", $locale->text('Quotation Date missing!'));
    $form->{ordnumber}    = "";
    $form->{quodate}      = $form->{transdate};
  }

  my $payment_id;
  if ($form->{payment_id}) {
    $payment_id = $form->{payment_id};
  }

  # if the name changed get new values
  if (&check_name($form->{vc})) {
    $form->{payment_id} = $payment_id if $form->{payment_id} eq "";
    &update;
    $::dispatcher->end_request;
  }

  _oe_remove_delivered_or_billed_rows(id => $form->{id}, type => 'billed');

  $form->{cp_id} *= 1;

  for my $i (1 .. $form->{rowcount}) {
    for (qw(ship qty sellprice basefactor)) {
      $form->{"${_}_${i}"} = $form->parse_amount(\%myconfig, $form->{"${_}_${i}"}) if $form->{"${_}_${i}"};
    }
    $form->{"converted_from_orderitems_id_$i"} = delete $form->{"orderitems_id_$i"};
  }

  my ($buysell, $orddate, $exchangerate);
  if (   $form->{type} =~ /_order/
      && $form->{currency} ne $form->{defaultcurrency}) {

    # check if we need a new exchangerate
    $buysell = ($form->{type} eq 'sales_order') ? "buy" : "sell";

    $orddate      = $form->current_date(\%myconfig);
    $exchangerate = $form->check_exchangerate(\%myconfig, $form->{currency}, $orddate, $buysell);

    if (!$exchangerate) {
      $exchangerate = 0;
    }
  }

  $form->{convert_from_oe_ids} = $form->{id};
  $form->{transdate}           = $form->{invdate} = $form->current_date(\%myconfig);
  $form->{duedate}             = $form->current_date(\%myconfig, $form->{invdate}, $form->{terms} * 1);
  $form->{defaultcurrency}     = $form->get_default_currency(\%myconfig);

  delete @{$form}{qw(id closed)};
  $form->{rowcount}--;

  if ($form->{type} =~ /_order$/) {
    $form->{exchangerate} = $exchangerate;
    &create_backorder;
  }

  my ($script);
  if (   $form->{type} eq 'purchase_order'
      || $form->{type} eq 'request_quotation') {
    $form->{title}  = $locale->text('Add Vendor Invoice');
    $form->{script} = 'ir.pl';
    $script         = "ir";
    $buysell        = 'sell';
  }

  if (   $form->{type} eq 'sales_order'
      || $form->{type} eq 'sales_quotation') {
    $form->{title}  = $locale->text('Add Sales Invoice');
    $form->{script} = 'is.pl';
    $script         = "is";
    $buysell        = 'buy';
  }

  # bo creates the id, reset it
  map { delete $form->{$_} } qw(id subject message cc bcc printed emailed queued);
  $form->{ $form->{vc} } =~ s/--.*//g;
  $form->{type} = "invoice";

  # locale messages
  $main::locale = Locale->new("$myconfig{countrycode}", "$script");
  $locale = $main::locale;

  require "bin/mozilla/$form->{script}";

  map { $form->{"select$_"} = "" } ($form->{vc}, "currency");

  my $currency = $form->{currency};
  &invoice_links;

  $form->{currency}     = $currency;
  $form->{forex}        = $form->check_exchangerate( \%myconfig, $form->{currency}, $form->{invdate}, $buysell);
  $form->{exchangerate} = $form->{forex} || '';

  $form->{creditremaining} -= ($form->{oldinvtotal} - $form->{ordtotal});

  &prepare_invoice;

  # format amounts
  for my $i (1 .. $form->{rowcount}) {
    $form->{"discount_$i"} =
      $form->format_amount(\%myconfig, $form->{"discount_$i"});

    my ($dec) = ($form->{"sellprice_$i"} =~ /\.(\d+)/);
    $dec           = length $dec;
    my $decimalplaces = ($dec > 2) ? $dec : 2;

    # copy delivery date from reqdate for order -> invoice conversion
    $form->{"deliverydate_$i"} = $form->{"reqdate_$i"}
      unless $form->{"deliverydate_$i"};

    $form->{"sellprice_$i"} =
      $form->format_amount(\%myconfig, $form->{"sellprice_$i"},
                           $decimalplaces);

    (my $dec_qty) = ($form->{"qty_$i"} =~ /\.(\d+)/);
    $dec_qty = length $dec_qty;
    $form->{"qty_$i"} =
      $form->format_amount(\%myconfig, $form->{"qty_$i"}, $dec_qty);
  }

  &display_form;

  $main::lxdebug->leave_sub();
}

sub save_exchangerate {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;
  my $locale   = $main::locale;

  $form->isblank("exchangerate", $locale->text('Exchangerate missing!'));
  $form->{exchangerate} =
    $form->parse_amount(\%myconfig, $form->{exchangerate});
  $form->save_exchangerate(\%myconfig, $form->{currency},
                           $form->{exchangeratedate},
                           $form->{exchangerate}, $form->{buysell});

  &invoice;

  $main::lxdebug->leave_sub();
}

sub create_backorder {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  $form->{shipped} = 1;

  # figure out if we need to create a backorder
  # items aren't saved if qty != 0

  my ($totalqty, $totalship);
  for my $i (1 .. $form->{rowcount}) {
    my $qty  = $form->{"qty_$i"};
    my $ship = $form->{"ship_$i"};
    $totalqty  += $qty;
    $totalship += $ship;

    $form->{"qty_$i"} = $qty - $ship;
  }

  if ($totalship == 0) {
    map { $form->{"ship_$_"} = $form->{"qty_$_"} } (1 .. $form->{rowcount});
    $form->{ordtotal} = 0;
    $form->{shipped}  = 0;
    return;
  }

  if ($totalqty == $totalship) {
    map { $form->{"qty_$_"} = $form->{"ship_$_"} } (1 .. $form->{rowcount});
    $form->{ordtotal} = 0;
    return;
  }

  my @flds = (
    qw(partnumber description qty ship unit sellprice discount id inventory_accno bin income_accno expense_accno listprice assembly taxaccounts partsgroup)
  );

  for my $i (1 .. $form->{rowcount}) {
    map {
      $form->{"${_}_$i"} =
        $form->format_amount(\%myconfig, $form->{"${_}_$i"})
    } qw(sellprice discount);
  }

  relink_accounts();

  OE->save(\%myconfig, \%$form);

  # rebuild rows for invoice
  my @a     = ();
  my $count = 0;

  for my $i (1 .. $form->{rowcount}) {
    $form->{"qty_$i"} = $form->{"ship_$i"};

    if ($form->{"qty_$i"}) {
      push @a, {};
      my $j = $#a;
      map { $a[$j]->{$_} = $form->{"${_}_$i"} } @flds;
      $count++;
    }
  }

  $form->redo_rows(\@flds, \@a, $count, $form->{rowcount});
  $form->{rowcount} = $count;

  $main::lxdebug->leave_sub();
}

sub save_as_new {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;

  check_oe_access();

  $form->{saveasnew} = 1;
  map { delete $form->{$_} } qw(printed emailed queued delivered closed);
  $form->{"converted_from_orderitems_id_$_"} = delete $form->{"orderitems_id_$_"} for 1 .. $form->{"rowcount"};

  # Let kivitendo assign a new order number if the user hasn't changed the
  # previous one. If it has been changed manually then use it as-is.
  my $idx = $form->{type} =~ /_quotation$/ ? "quonumber" : "ordnumber";
  $form->{$idx} =~ s/^\s*//g;
  $form->{$idx} =~ s/\s*$//g;
  if ($form->{saved_xyznumber} &&
      ($form->{saved_xyznumber} eq $form->{$idx})) {
    delete($form->{$idx});
  }

  # clear reqdate and transdate unless changed
  if ( $form->{reqdate} && $form->{id} ) {
    my $saved_order = OE->retrieve_simple(id => $form->{id});
    if ( $saved_order && $saved_order->{reqdate} eq $form->{reqdate} && $saved_order->{transdate} eq $form->{transdate} ) {
      my $extra_days     = $form->{type} eq 'sales_quotation' ? $::instance_conf->get_reqdate_interval : 1;
      $form->{reqdate}   = DateTime->today_local->next_workday(extra_days => $extra_days)->to_kivitendo;
      $form->{transdate} = DateTime->today_local->to_kivitendo;
    }
  }

  # update employee
  $form->get_employee();

  &save;

  $main::lxdebug->leave_sub();
}

sub check_for_direct_delivery_yes {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;

  check_oe_access();

  $form->{direct_delivery_checked} = 1;
  delete @{$form}{grep /^shipto/, keys %{ $form }};
  map { s/^CFDD_//; $form->{$_} = $form->{"CFDD_${_}"} } grep /^CFDD_/, keys %{ $form };
  $form->{CFDD_shipto} = 1;
  purchase_order();
  $main::lxdebug->leave_sub();
}

sub check_for_direct_delivery_no {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;

  check_oe_access();

  $form->{direct_delivery_checked} = 1;
  delete @{$form}{grep /^shipto/, keys %{ $form }};
  $form->{CFDD_shipto} = 0;
  purchase_order();

  $main::lxdebug->leave_sub();
}

sub check_for_direct_delivery {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  check_oe_access();

  if ($form->{direct_delivery_checked}
      || (!$form->{shiptoname} && !$form->{shiptostreet} && !$form->{shipto_id})) {
    $main::lxdebug->leave_sub();
    return;
  }

  my $cvars = SL::DB::Shipto->new->cvars_by_config;

  if ($form->{shipto_id}) {
    Common->get_shipto_by_id(\%myconfig, $form, $form->{shipto_id}, "CFDD_");

  } else {
    map { $form->{"CFDD_${_}"} = $form->{$_ } } grep /^shipto/, keys %{ $form };
  }

  $_->value($::form->{"CFDD_shiptocvar_" . $_->config->name}) for @{ $cvars };

  delete $form->{action};
  $form->{VARIABLES} = [ map { { "key" => $_, "value" => $form->{$_} } } grep { ($_ ne 'login') && ($_ ne 'password') && (ref $_ eq "") } keys %{ $form } ];

  $form->header();
  print $form->parse_html_template("oe/check_for_direct_delivery", { cvars => $cvars });

  $main::lxdebug->leave_sub();

  $::dispatcher->end_request;
}

sub purchase_order {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my $locale   = $main::locale;

  check_oe_access();
  $form->mtime_ischanged('oe');

  $main::auth->assert('purchase_order_edit');

  $form->{sales_order_to_purchase_order} = 0;
  if ($form->{type} eq 'sales_order') {
    $form->{sales_order_to_purchase_order} = 1;
    check_for_direct_delivery();
  }

  if ($form->{type} =~ /^sales_/) {
    delete($form->{ordnumber});
    delete($form->{payment_id});
    delete($form->{delivery_term_id});
  }

  $form->{cp_id} *= 1;

  my $source_type = $form->{type};
  $form->{title} = $locale->text('Add Purchase Order');
  $form->{vc}    = "vendor";
  $form->{type}  = "purchase_order";

  $form->get_employee();

  poso(source_type => $form->{type});

  delete $form->{sales_order_to_purchase_order};

  $main::lxdebug->leave_sub();
}

sub sales_order {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my $locale   = $main::locale;

  check_oe_access();
  $main::auth->assert('sales_order_edit');
  $form->mtime_ischanged('oe');

  if ($form->{type} eq "purchase_order") {
    delete($form->{ordnumber});
    $form->{"lastcost_$_"} = $form->{"sellprice_$_"} for (1..$form->{rowcount});
  }

  $form->{cp_id} *= 1;

  my $source_type = $form->{type};
  $form->{title}  = $locale->text('Add Sales Order');
  $form->{vc}     = "customer";
  $form->{type}   = "sales_order";

  $form->get_employee();

  poso(source_type => $source_type);

  $main::lxdebug->leave_sub();
}

sub poso {
  $main::lxdebug->enter_sub();

  my %param    = @_;
  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  check_oe_access();
  $main::auth->assert('purchase_order_edit | sales_order_edit');

  $form->{transdate} = $form->current_date(\%myconfig);
  delete $form->{duedate};

  # "reqdate" is the validity date for a quotation and the delivery
  # date for an order. Therefore it makes no sense to keep the value
  # when converting from one into the other.
  delete $form->{reqdate} if ($param{source_type} =~ /_quotation$/) == ($form->{type} =~ /_quotation$/);

  $form->{convert_from_oe_ids} = $form->{id};
  $form->{closed}              = 0;

  $form->{old_employee_id}     = $form->{employee_id};
  $form->{old_salesman_id}     = $form->{salesman_id};

  # reset
  map { delete $form->{$_} } qw(id subject message cc bcc printed emailed queued customer vendor creditlimit creditremaining discount tradediscount oldinvtotal delivered ordnumber);
  # this converted variable is also used for sales_order to purchase order and vice versa
  $form->{"converted_from_orderitems_id_$_"} = delete $form->{"orderitems_id_$_"} for 1 .. $form->{"rowcount"};

  # if purchase_order was generated from sales_order, use  lastcost_$i as sellprice_$i
  # also reset discounts
  if ( $form->{sales_order_to_purchase_order} ) {
    for my $i (1 .. $form->{rowcount}) {
      $form->{"sellprice_${i}"} = $form->{"lastcost_${i}"};
      $form->{"discount_${i}"}  = 0;
    };
  };

  for my $i (1 .. $form->{rowcount}) {
    map { $form->{"${_}_${i}"} = $form->parse_amount(\%myconfig, $form->{"${_}_${i}"}) if ($form->{"${_}_${i}"}) } qw(ship qty sellprice basefactor discount lastcost);
  }

  my %saved_vars = map { $_ => $form->{$_} } grep { $form->{$_} } qw(currency);

  &order_links;

  map { $form->{$_} = $saved_vars{$_} } keys %saved_vars;

  # prepare_order assumes that the discount is in db-notation (0.05) and not user-notation (5)
  # and therefore multiplies the values by 100 in the case of reading from db or making an order
  # from several quotation, so we convert this back into percent-notation for the user interface by multiplying with 0.01
  # ergänzung 03.10.2010 muss vor prepare_order passieren (s.a. Svens Kommentar zu Bug 1017)
  # das parse_amount wird oben schon ausgeführt, deswegen an dieser stelle raus (wichtig: kommawerte bei discount testen)
  for my $i (1 .. $form->{rowcount}) {
    $form->{"discount_$i"} /=100;
  };

  &prepare_order;
  &update;

  $main::lxdebug->leave_sub();
}

sub delivery_order {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  $form->mtime_ischanged('oe');

  if ($form->{type} =~ /^sales/) {
    $main::auth->assert('sales_delivery_order_edit');

    $form->{vc}    = 'customer';
    $form->{type}  = 'sales_delivery_order';

  } else {
    $main::auth->assert('purchase_delivery_order_edit');

    $form->{vc}    = 'vendor';
    $form->{type}  = 'purchase_delivery_order';
  }

  $form->get_employee();

  require "bin/mozilla/do.pl";

  $form->{script}               = 'do.pl';
  $form->{cp_id}               *= 1;
  $form->{convert_from_oe_ids}  = $form->{id};
  $form->{transdate}            = $form->current_date(\%myconfig);
  delete $form->{duedate};

  $form->{old_employee_id}  = $form->{employee_id};
  $form->{old_salesman_id}  = $form->{salesman_id};

  _oe_remove_delivered_or_billed_rows(id => $form->{id}, type => 'delivered');

  # reset
  delete @{$form}{qw(id subject message cc bcc printed emailed queued creditlimit creditremaining discount tradediscount oldinvtotal closed delivered)};

  for my $i (1 .. $form->{rowcount}) {
    map { $form->{"${_}_${i}"} = $form->parse_amount(\%myconfig, $form->{"${_}_${i}"}) if ($form->{"${_}_${i}"}) } qw(ship qty sellprice lastcost basefactor discount);
    $form->{"converted_from_orderitems_id_$i"} = delete $form->{"orderitems_id_$i"};
  }

  my %old_values = map { $_ => $form->{$_} } qw(customer_id oldcustomer customer vendor_id oldvendor vendor shipto_id);

  order_links();

  prepare_order();

  map { $form->{$_} = $old_values{$_} if ($old_values{$_}) } keys %old_values;

  for my $i (1 .. $form->{rowcount}) {
    (my $dummy, $form->{"pricegroup_id_$i"}) = split /--/, $form->{"sellprice_pg_$i"};
  }
  update();

  $main::lxdebug->leave_sub();
}

sub oe_delivery_order_from_order {

  return if !$::form->{id};

  my $order = SL::DB::Order->new(id => $::form->{id})->load;
  $order->flatten_to_form($::form, format_amounts => 1);

  # fake last empty row
  $::form->{rowcount}++;

  delivery_order();
}

sub e_mail {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;

  check_oe_access();

  $form->mtime_ischanged('oe','mail');
  $form->{print_and_save} = 1;

  my $saved_form = save_form();

  save();

  restore_form($saved_form, 0, qw(id ordnumber quonumber));

  edit_e_mail();

  $main::lxdebug->leave_sub();
}

sub yes {
  call_sub($main::form->{yes_nextsub});
}

sub no {
  call_sub($main::form->{no_nextsub});
}

######################################################################################################
# IO ENTKOPPLUNG
# ###############################################################################################
sub display_form {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;
  my %myconfig = %main::myconfig;

  check_oe_access();

  retrieve_partunits() if ($form->{type} =~ /_delivery_order$/);

  $form->{"taxaccounts"} =~ s/\s*$//;
  $form->{"taxaccounts"} =~ s/^\s*//;
  foreach my $accno (split(/\s*/, $form->{"taxaccounts"})) {
    map({ delete($form->{"${accno}_${_}"}); } qw(rate description taxnumber));
  }
  $form->{"taxaccounts"} = "";

  IC->retrieve_accounts(\%myconfig, $form, map { $_ => $form->{"id_$_"} } 1 .. $form->{rowcount});

  $form->{rowcount}++;
  $form->{"project_id_$form->{rowcount}"} = $form->{globalproject_id};

  $form->language_payment(\%myconfig);

  Common::webdav_folder($form);

  &form_header;

  # create rows
  display_row($form->{rowcount}) if $form->{rowcount};

  &form_footer;

  $main::lxdebug->leave_sub();
}

sub report_for_todo_list {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;

  my $quotations = OE->transactions_for_todo_list();
  my $content;

  if (@{ $quotations }) {
    my $edit_url = build_std_url('script=oe.pl', 'action=edit');

    $content     = $form->parse_html_template('oe/report_for_todo_list', { 'QUOTATIONS' => $quotations,
                                                                           'edit_url'   => $edit_url });
  }

  $main::lxdebug->leave_sub();

  return $content;
}

sub edit_periodic_invoices_config {
  $::lxdebug->enter_sub();

  $::form->{type} = 'sales_order';

  check_oe_access();

  my $config;
  $config = YAML::Load($::form->{periodic_invoices_config}) if $::form->{periodic_invoices_config};

  if ('HASH' ne ref $config) {
    $config =  { periodicity             => 'm',
                 order_value_periodicity => 'p', # = same as periodicity
                 start_date_as_date      => $::form->{transdate} || $::form->current_date,
                 extend_automatically_by => 12,
                 active                  => 1,
               };
  }

  $config->{periodicity}             = 'm' if none { $_ eq $config->{periodicity}             }       @SL::DB::PeriodicInvoicesConfig::PERIODICITIES;
  $config->{order_value_periodicity} = 'p' if none { $_ eq $config->{order_value_periodicity} } ('p', @SL::DB::PeriodicInvoicesConfig::ORDER_VALUE_PERIODICITIES);

  $::form->get_lists(printers => "ALL_PRINTERS",
                     charts   => { key       => 'ALL_CHARTS',
                                   transdate => 'current_date' });

  $::form->{AR}    = [ grep { $_->{link} =~ m/(?:^|:)AR(?::|$)/ } @{ $::form->{ALL_CHARTS} } ];
  $::form->{title} = $::locale->text('Edit the configuration for periodic invoices');

  if ($::form->{customer_id}) {
    $::form->{ALL_CONTACTS} = SL::DB::Manager::Contact->get_all_sorted(where => [ cp_cv_id => $::form->{customer_id} ]);
  }

  $::form->header(no_layout => 1);
  print $::form->parse_html_template('oe/edit_periodic_invoices_config', $config);

  $::lxdebug->leave_sub();
}

sub save_periodic_invoices_config {
  $::lxdebug->enter_sub();

  $::form->{type} = 'sales_order';

  check_oe_access();

  $::form->isblank('start_date_as_date', $::locale->text('The start date is missing.'));

  my $config = { active                  => $::form->{active}     ? 1 : 0,
                 terminated              => $::form->{terminated} ? 1 : 0,
                 direct_debit            => $::form->{direct_debit} ? 1 : 0,
                 periodicity             => (any { $_ eq $::form->{periodicity}             }       @SL::DB::PeriodicInvoicesConfig::PERIODICITIES)              ? $::form->{periodicity}             : 'm',
                 order_value_periodicity => (any { $_ eq $::form->{order_value_periodicity} } ('p', @SL::DB::PeriodicInvoicesConfig::ORDER_VALUE_PERIODICITIES)) ? $::form->{order_value_periodicity} : 'p',
                 start_date_as_date      => $::form->{start_date_as_date},
                 end_date_as_date        => $::form->{end_date_as_date},
                 first_billing_date_as_date => $::form->{first_billing_date_as_date},
                 print                   => $::form->{print} ? 1 : 0,
                 printer_id              => $::form->{print} ? $::form->{printer_id} * 1 : undef,
                 copies                  => $::form->{copies} * 1 ? $::form->{copies} : 1,
                 extend_automatically_by => $::form->{extend_automatically_by} * 1 || undef,
                 ar_chart_id             => $::form->{ar_chart_id} * 1,
                 send_email                 => $::form->{send_email} ? 1 : 0,
                 email_recipient_contact_id => $::form->{email_recipient_contact_id} * 1 || undef,
                 email_recipient_address    => $::form->{email_recipient_address},
                 email_sender               => $::form->{email_sender},
                 email_subject              => $::form->{email_subject},
                 email_body                 => $::form->{email_body},
               };

  $::form->{periodic_invoices_config} = YAML::Dump($config);

  $::form->{title} = $::locale->text('Edit the configuration for periodic invoices');
  $::form->header;
  print $::form->parse_html_template('oe/save_periodic_invoices_config', $config);

  $::lxdebug->leave_sub();
}

sub _remove_full_delivered_rows {

  my @fields = map { s/_1$//; $_ } grep { m/_1$/ } keys %{ $::form };
  my @new_rows;

  my $removed_rows = 0;
  my $row          = 0;
  while ($row < $::form->{rowcount}) {
    $row++;
    next unless $::form->{"id_$row"};
    my $base_factor = SL::DB::Manager::Unit->find_by(name => $::form->{"unit_$row"})->base_factor;
    my $base_qty = $::form->parse_amount(\%::myconfig, $::form->{"qty_$row"}) *  $base_factor;
    my $ship_qty = $::form->parse_amount(\%::myconfig, $::form->{"ship_$row"}) *  $base_factor;
    #$main::lxdebug->message(LXDebug->DEBUG2(),"shipto=".$ship_qty." qty=".$base_qty);

    if (!$ship_qty || ($ship_qty < $base_qty)) {
      $::form->{"qty_$row"}  = $::form->format_amount(\%::myconfig, ($base_qty - $ship_qty) / $base_factor );
      $::form->{"ship_$row"} = 0;
      push @new_rows, { map { $_ => $::form->{"${_}_${row}"} } @fields };

    } else {
      $removed_rows++;
    }
  }
  $::form->redo_rows(\@fields, \@new_rows, scalar(@new_rows), $::form->{rowcount});
  $::form->{rowcount} -= $removed_rows;
}

sub _oe_remove_delivered_or_billed_rows {
  my (%params) = @_;

  return if !$params{id} || !$params{type};

  my $ord_quot = SL::DB::Order->new(id => $params{id})->load;
  return if !$ord_quot;

  # Prüfung ob itemlinks existieren, falls ja dann neue Implementierung

  if (  $params{type} eq 'delivered' ) {
      my $orderitem = SL::DB::Manager::OrderItem->get_first( where => [trans_id => $ord_quot->id]);
      if ( $orderitem) {
          my @links = $orderitem->linked_records(to => 'SL::DB::DeliveryOrderItem');
          if ( scalar(@links ) > 0 ) {
              #$main::lxdebug->message(LXDebug->DEBUG2(),"item recordlinks vorhanden");
              return _remove_full_delivered_rows();
          }
      }
  }
  my %args    = (
    direction => 'to',
    to        =>   $params{type} eq 'delivered' ? 'DeliveryOrder' : 'Invoice',
    via       => [ $params{type} eq 'delivered' ? qw(Order)       : qw(Order DeliveryOrder) ],
  );

  my %handled_base_qtys;
  foreach my $record (@{ $ord_quot->linked_records(%args) }) {
    next if $ord_quot->is_sales != $record->is_sales;
    next if $record->type eq 'invoice' && $record->storno;

    foreach my $item (@{ $record->items }) {
      my $key  = $item->parts_id;
      $key    .= ':' . $item->serialnumber if $item->serialnumber;
      $handled_base_qtys{$key} += $item->qty * $item->unit_obj->base_factor;
    }
  }

  _remove_billed_or_delivered_rows(quantities => \%handled_base_qtys);
}

# iterate all positions and match articlenumber
sub check_transport_cost_reminder_article_number {
  $main::lxdebug->enter_sub();

  my $form     = $main::form;

  check_oe_access();

  my $transport_article_id = $::instance_conf->get_transport_cost_reminder_article_number_id;
  for my $i (1 .. $form->{rowcount}) {
    return if $form->{"id_${i}"} eq $transport_article_id;
  }

  # simply return the name of the part
  return SL::DB::Part->new(id => $transport_article_id)->load()->partnumber;

  $main::lxdebug->leave_sub();
}
sub dispatcher {
  foreach my $action (qw(delete delivery_order e_mail invoice print purchase_order quotation
                         request_for_quotation sales_order save save_and_close save_as_new ship_to update)) {
    if ($::form->{"action_${action}"}) {
      call_sub($action);
      return;
    }
  }

  $::form->error($::locale->text('No action defined.'));
}
