package SL::Shop;

use strict;

use parent qw(Rose::Object);

# __PACKAGE__->run_before('check_auth');

use Rose::Object::MakeMethods::Generic (
  'scalar'                => [ qw(config) ],
  'scalar --get_set_init' => [ qw(connector) ],
);

sub init_connector {
  my ($self) = @_;
  # determine the connector from the connector type in the webshop config
  return SL::ShopConnector::ALL->shop_connector_class_by_name($self->config->connector)->new( config => $self->config); 

};

1;

__END__

=encoding utf8

=head1 NAME

SL::WebShop - Do stuff with WebShop instances

=head1 SYNOPSIS

  my $config = SL::DB::Manager::WebShop->get_first();
  my $shop = SL::WebShop->new( config => $config );

From the config we know which Connector class to load, save in $shop->connector
and do stuff from there:

  $shop->connector->get_new_orders;

=head1 FUNCTIONS

=head1 BUGS

Nothing here yet.

=head1 AUTHOR

G. Richardson <lt>information@kivitendo-premium.deE<gt>

=cut

