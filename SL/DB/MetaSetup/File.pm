# This file has been auto-generated. Do not modify it; it will be overwritten
# by rose_auto_create_model.pl automatically.
package SL::DB::File;

use strict;

use parent qw(SL::DB::Object);

__PACKAGE__->meta->table('files');

__PACKAGE__->meta->columns(
  description                => { type => 'text' },
  file_content               => { type => 'bytea' },
  file_content_type          => { type => 'text' },
  filename                   => { type => 'text', not_null => 1 },
  files_img_height           => { type => 'integer' },
  files_img_width            => { type => 'integer' },
  files_mtime                => { type => 'timestamp', default => 'now()' },
  id                         => { type => 'serial', not_null => 1 },
  itime                      => { type => 'timestamp', default => 'now()' },
  location                   => { type => 'text' },
  modul                      => { type => 'text', not_null => 1 },
  mtime                      => { type => 'timestamp' },
  position                   => { type => 'integer' },
  thumbnail_img_content      => { type => 'bytea' },
  thumbnail_img_content_type => { type => 'text' },
  thumbnail_img_height       => { type => 'integer' },
  thumbnail_img_width        => { type => 'integer' },
  title                      => { type => 'varchar', length => 45 },
  trans_id                   => { type => 'integer', not_null => 1 },
);

__PACKAGE__->meta->primary_key_columns([ 'id' ]);

__PACKAGE__->meta->allow_inline_column_values(1);

1;
;
