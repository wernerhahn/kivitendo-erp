package SL::ShopConnector::ALL;

use strict;
use SL::ShopConnector::XTCommerce;
use SL::ShopConnector::Shopware;
# use SL::ShopConnector::ideal;

my %shop_connector_by_name = (
  xtcommerce  => 'SL::ShopConnector::XTCommerce',
  shopware    => 'SL::ShopConnector::Shopware',
  ideal       => 'SL::ShopConnector::IDeal',
);

my %shop_connector_by_connector = (
  xtcommerce => 'SL::ShopConnector::XTCommerce',
  shopware   => 'SL::ShopConnector::Shopware',
  ideal      => 'SL::ShopConnector::IDeal',
);

my @shop_connector_order = qw(
  xtcommerce
  shopware
  ideal
);

sub all_enabled_shop_connectors {
  my %disabled = map { $_ => 1 } @{ $::instance_conf->get_disabled_shop_connectors || [] };

  map { $shop_connector_by_name{$_} } grep { !$disabled{$_} } @shop_connector_order;
}

sub all_shop_connectors {
  map { $shop_connector_by_name{$_} } @shop_connector_order;
}

sub shop_connector_class_by_name {
  $shop_connector_by_name{$_[1]};
}

sub shop_connector_class_by_connector {
  $shop_connector_by_connector{$_[1]};
}

1;
