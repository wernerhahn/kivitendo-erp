package SL::ShopConnector::XTCommerce;

use strict;

use parent qw(SL::ShopConnector::Base);

use LWP::UserAgent;     
use LWP::Authen::Digest;
use Data::Dumper;

use Rose::Object::MakeMethods::Generic (
  'scalar --get_set_init' => [ qw(connector url) ],
);

sub get_order {
  my ($self, $id) = @_;
   
  my $url = $self->url;
  my $data = $self->connector->get("$url/order/$id");
  my $data_json = $data->content;
  my $import = SL::JSON::decode_json($data_json);

# need to check return here, only return well defined data

  return $import;

  # printf("loading %s:%s\n", $self->config->url, $self->config->port);
};

sub get_new_orders {
  my ($self) = @_;
   
  my $url = $self->url;
  my $data = $self->connector->get("$url/orders");
  my $data_json = $data->content;
  my $orders = SL::JSON::decode_json($data_json);

# need to check return here, only return well defined data

  return $orders;

  # printf("loading %s:%s\n", $self->config->url, $self->config->port);
};

sub update_part {
  my ($self, $part) = @_;

  my $url = $self->url;
  my $partnumber = $part->partnumber;
  my $data = $self->connector->get("$url/part/$partnumber");

};

sub init_url {
  my ($self) = @_;
  # TODO: validate url and port
  $self->url($self->config->url . ":" . $self->config->port);
};
  
sub init_connector {
  my ($self) = @_;
  my $ua = LWP::UserAgent->new;          
  $ua->credentials(                      
      $self->url,
      "XT Commerce SOAP 2.0",                
      "user" => "sdfsdfsdfsdfasdfsdf"     
      );                                     
  return $ua;                            
};

1;

__END__

=encoding utf-8

=head1 NAME

SL::ShopConnecter::XTCommerce - connector for XTCommerce with SOAP2.0 plugin

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 BUGS

None yet. :)

=head1 AUTHOR

=cut
