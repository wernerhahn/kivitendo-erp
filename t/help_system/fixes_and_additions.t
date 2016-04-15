use Test::More;

use strict;

use lib 't';
use utf8;

use_ok 'SL::HelpSystem::MultiMarkdown';

sub untab {
  my $text = shift;
  $text    =~ s{\t}{  }g;
  return $text;
}

my $mmd = SL::HelpSystem::MultiMarkdown->new;

# Tables: put <col> into <colgroup>
is(untab($mmd->convert_content_to_html(qq{|This is|a table|
|-----|-----|
|With|content|})),
qq|<table>
<colgroup>
<col>
<col>
</colgroup>
<thead>
<tr>
  <th>This is</th>
  <th>a table</th>
</tr>
</thead>
<tbody>
<tr>
  <td>With</td>
  <td>content</td>
</tr>
</tbody>
</table>
|);

# Block comments with ``` … ```
is($mmd->convert_content_to_html(qq!```
This is a friggin' block quote.
## Even funky markup should stay just **that**.
Quote to the block.
```
!),
qq!<pre><code>This is a friggin' block quote.
## Even funky markup should stay just **that**.
Quote to the block.
</code></pre>
!);

# Attention blocks with == … ==
is($mmd->convert_content_to_html(qq{==**Attention!**

This is a public service announcement. Do not panic.
==}),
qq{<div class="attention"><p><strong>Attention!</strong></p>

<p>This is a public service announcement. Do not panic.</p></div>
});

# Intra-help system links
is($mmd->convert_content_to_html(qq{[Stay away from](help:da/voodoo#mon)}),
   qq{<p><a href="controller.pl?action=Help/show&context=da/voodoo#mon">Stay away from</a></p>\n});

# Convert line feeds to <br> tags
is($mmd->convert_content_to_html(qq{Please enforce
line breaks
here.}),
   qq{<p>Please enforce<br>\nline breaks<br>\nhere.</p>\n});

done_testing();
