# This file has been auto-generated. Do not modify it; it will be overwritten
# by rose_auto_create_model.pl automatically.
package SL::DB::AuthClientFeature;

use strict;

use base qw(SL::DB::Object);

__PACKAGE__->meta->table('clients_features');
__PACKAGE__->meta->schema('auth');

__PACKAGE__->meta->columns(
  client_id  => { type => 'integer', not_null => 1 },
  feature_id => { type => 'integer', not_null => 1 },
);

__PACKAGE__->meta->primary_key_columns([ 'client_id', 'feature_id' ]);

__PACKAGE__->meta->foreign_keys(
  client => {
    class       => 'SL::DB::AuthClient',
    key_columns => { client_id => 'id' },
  },

  feature => {
    class       => 'SL::DB::AuthFeature',
    key_columns => { feature_id => 'id' },
  },
);

# __PACKAGE__->meta->initialize;

1;
;
