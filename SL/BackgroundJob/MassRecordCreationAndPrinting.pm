package SL::BackgroundJob::MassRecordCreationAndPrinting;

use strict;
use warnings;

use parent qw(SL::BackgroundJob::Base);

use SL::DB::DeliveryOrder;
use SL::DB::Order;  # origin order to delivery_order
use SL::DB::Invoice;
use SL::DB::Printer;
use SL::SessionFile;
use SL::Template;

use constant WAITING_FOR_EXECUTION       => 0;
use constant CONVERTING_DELIVERY_ORDERS  => 1;
use constant PRINTING_INVOICES           => 2;
use constant DONE                        => 3;
# Data format:
# my $data             = {
#   record_ids          => [ 123, 124, 127, ],
#   printer_id         => 4711,
#   num_created        => 0,
#   num_printed        => 0,
#   invoice_ids        => [ 234, 235, ],
#   conversion_errors  => [ { id => 124, number => 'A981723', message => "Stuff went boom" }, ],
#   print_errors       => [ { id => 234, number => 'L87123123', message => "Printer is out of coffee" }, ],
#   pdf_file_name      => 'qweqwe.pdf',
# };

sub create_invoices {
  my ($self)  = @_;

  my $job_obj = $self->{job_obj};
  my $db      = $job_obj->db;

  $job_obj->set_data(status => CONVERTING_DELIVERY_ORDERS())->save;

  foreach my $delivery_order_id (@{ $job_obj->data_as_hash->{record_ids} }) {
    my $number = $delivery_order_id;
    my $data   = $job_obj->data_as_hash;

    eval {
      my $invoice;
      my $sales_delivery_order = SL::DB::DeliveryOrder->new(id => $delivery_order_id)->load;
      $number                  = $sales_delivery_order->donumber;

      if (!$db->do_transaction(sub {
        $invoice = $sales_delivery_order->convert_to_invoice(item_filter => \&delivery_order_item_filter, queue_sort => 1) || die $db->error;
        # $delivery_order->post_save_sanity_check; # just a hint at e8521eee (#90 od)
        1;
      })) {
        die $db->error;
      }

      $data->{num_created}++;
      push @{ $data->{invoice_ids} }, $invoice->id;
      push @{ $self->{invoices}    }, $invoice;

      1;
    } or do {
      push @{ $data->{conversion_errors} }, { id => $delivery_order_id, number => $number, message => $@ };
    };

    $job_obj->update_attributes(data_as_hash => $data);
  }
}

sub convert_invoices_to_pdf {
  my ($self) = @_;

  return if !@{ $self->{invoices} };

  my $job_obj = $self->{job_obj};
  my $db      = $job_obj->db;

  $job_obj->set_data(status => PRINTING_INVOICES())->save;

  require SL::Controller::MassInvoiceCreatePrint;

  my $printer_id = $job_obj->data_as_hash->{printer_id};
  my $ctrl       = SL::Controller::MassInvoiceCreatePrint->new;
  my %variables  = (
    type         => 'invoice',
    formname     => 'invoice',
    format       => 'pdf',
    media        => $printer_id ? 'printer' : 'file',
  );

  my @pdf_file_names;

  foreach my $invoice (@{ $self->{invoices} }) {
    my $data = $job_obj->data_as_hash;

    eval {
      my %create_params = (
        template  => $ctrl->find_template(name => 'invoice', printer_id => $printer_id),
        variables => Form->new(''),
        return    => 'file_name',
      );

      $create_params{variables}->{$_} = $variables{$_} for keys %variables;

      $invoice->flatten_to_form($create_params{variables}, format_amounts => 1);
      $create_params{variables}->prepare_for_printing;

      push @pdf_file_names, $ctrl->create_pdf(%create_params);

      $data->{num_printed}++;

      1;

    } or do {
      push @{ $data->{print_errors} }, { id => $invoice->id, number => $invoice->invnumber, message => $@ };
    };

    $job_obj->update_attributes(data_as_hash => $data);
  }

  if (@pdf_file_names) {
    my $data = $job_obj->data_as_hash;

    eval {
      $self->{merged_pdf} = $ctrl->merge_pdfs(file_names => \@pdf_file_names);
      unlink @pdf_file_names;

      if (!$printer_id) {
        my $file_name = 'mass_invoice' . $job_obj->id . '.pdf';
        my $sfile     = SL::SessionFile->new($file_name, mode => 'w');
        $sfile->fh->print($self->{merged_pdf});
        $sfile->fh->close;

        $data->{pdf_file_name} = $file_name;
      }

      1;

    } or do {
      push @{ $data->{print_errors} }, { message => $@ };
    };

    $job_obj->update_attributes(data_as_hash => $data);
  }
}

sub print_pdfs {
  my ($self)     = @_;

  my $job_obj    = $self->{job_obj};
  my $data       = $job_obj->data_as_hash;
  my $printer_id = $data->{printer_id};

  return if !$printer_id;

  my $printer = SL::DB::Printer->new(id => $printer_id)->load;
  my $command = SL::Template::create(type => 'ShellCommand', form => Form->new(''))->parse($printer->printer_command);
  my $out;

  if (!open $out, '|-', $command) {
    push @{ $data->{print_errors} }, { message => $::locale->text('Could not execute printer command: #1', $!) };
    $job_obj->update_attributes(data_as_hash => $data);
    return;
  }

  binmode $out;
  print $out $self->{merged_pdf};
  close $out;
}

sub run {
  my ($self, $job_obj) = @_;

  $self->{job_obj}         = $job_obj;
  $self->{invoices} = [];

  $self->create_invoices;
  $self->convert_invoices_to_pdf;
  $self->print_pdfs;

  $job_obj->set_data(status => DONE())->save;

  return 1;
}

1;

__END__

=pod

=encoding utf8

=head1 NAME

SL::BackgroundJob::MassRecordCreationAndPrinting

=head1 SYNOPSIS

In controller:

use SL::BackgroundJob::MassRecordCreationAndPrinting

my $job              = SL::DB::BackgroundJob->new(
    type               => 'once',
    active             => 1,
    package_name       => 'MassRecordCreationAndPrinting',

  )->set_data(
    record_ids         => [ map { $_->id } @records[0..$num - 1] ],
    printer_id         => $::form->{printer_id},
    status             => SL::BackgroundJob::MassRecordCreationAndPrinting->WAITING_FOR_EXECUTION(),
    num_created        => 0,
    num_printed        => 0,
    invoice_ids        => [ ],
    conversion_errors  => [ ],
    print_errors       => [ ],

  )->update_next_run_at;
  SL::System::TaskServer->new->wake_up;

=head1 OVERVIEW

This background job has 4 states which are described by the four constants above.

=over 2

=item * WAITING_FOR_EXECUTION
  Background has been initialised and needs to be picked up by the task_server

=item * CONVERTING_DELIVERY_ORDERS
   Object conversion

=item * PRINTING_INVOICES
  Printing, if done via print command

=item * DONE
  To release the process and for the user information

=back

=head1 FUNCTIONS

=over 2

=item C<create_invoices>

Converts the source objects (DeliveryOrder) to destination objects (Invoice).
On success objects will be saved.

=item C<convert_invoices_to_pdf>

Takes the new destination objects and merges them via print template in one pdf.

=item C<print_pdfs>

Sent the pdf to the printer command (if checked).

=back

=head1 BUGS

Currently the calculation from the gui (form) differs from the calculation via convert (PTC).
Furthermore mass conversion with foreign currencies could lead to problems (daily rate check).

=head1 AUTHOR

Moritz Bunkus E<lt>m.bunkus@linet-services.deE<gt>

Jan Büren E<lt>jan@kivitendo-premium.deE<gt>

=cut