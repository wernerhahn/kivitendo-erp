use strict;
use lib 't';
use Support::Files;
use Test::More;

if (eval { require PPI; 1 }) {
  plan tests => scalar(@Support::Files::testitems);
} else {
  plan skip_all => "PPI not installed";
}

my $fh;
{
    local $^W = 0;  # Don't complain about non-existent filehandles
    if (-e \*Test::More::TESTOUT) {
        $fh = \*Test::More::TESTOUT;
    } elsif (-e \*Test::Builder::TESTOUT) {
        $fh = \*Test::Builder::TESTOUT;
    } else {
        $fh = \*STDOUT;
    }
}

my @testitems = @Support::Files::testitems;

foreach my $file (@testitems) {
  next unless -f $file;
  my $clean = 1;
  my $doc = PPI::Document->new($file) or do {
    ok 0, "PPI error for file $file: " . PPI::Document::errstr();
    next;
  };
  my $stmts = $doc->find('Statement::Variable');

  for my $var (@{ $stmts || [] }) {
    # local can have valid uses like this, and our is extremely uncommon
    next unless $var->type eq 'my';

    # no if? alright
    next unless $var->find(sub { $_[1]->content eq 'if' });

    # token "if" is not in the top level struvture - no problem
    # most likely an anonymous sub or a complicated map/grep/reduce
    next unless grep { $_->content eq 'if'  } $var->schildren;

    $clean = 0;
    print $fh "?: $var \n";
  }

  ok $clean, $file;
}