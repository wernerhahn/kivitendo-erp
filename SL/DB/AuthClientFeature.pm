package SL::DB::AuthClientFeature;

use strict;

use SL::DB::MetaSetup::AuthClientFeature;

__PACKAGE__->meta->initialize;

__PACKAGE__->meta->make_manager_class;

1;
