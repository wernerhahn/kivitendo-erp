package SL::DB::AuthFeature;

use strict;

use SL::DB::MetaSetup::AuthFeature;
use SL::DB::Manager::AuthFeature;
use SL::DB::Helper::Util;

__PACKAGE__->meta->add_relationship(
  clients => {
    type      => 'many to many',
    map_class => 'SL::DB::AuthClientFeature',
    map_from  => 'feature',
    map_to    => 'client',
  },
);

__PACKAGE__->meta->initialize;

1;
