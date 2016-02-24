package SL::Menu;

use strict;

use SL::Auth;
use YAML ();
use File::Spec;
use SL::MoreCommon qw(uri_encode);

our $yaml_xs;
BEGIN {
   $yaml_xs =  eval { require YAML::XS };
}

our %menu_cache;

sub new {
  my ($package, $domain) = @_;

  if (!$menu_cache{$domain}) {
    my $path = File::Spec->catdir('menus', $domain);

    opendir my $dir, $path or die "can't open $path: $!";
    my @files = sort grep -f "$path/$_", grep /\.yaml$/, readdir $dir;
    close $dir;

    my $nodes = [];
    my $nodes_by_id = {};
    for my $file (@files) {
      my $data;
      if ($yaml_xs) {
        $data = YAML::XS::LoadFile(File::Spec->catfile($path, $file));
      } else {
        $data = YAML::LoadFile(File::Spec->catfile($path, $file));
      }
      _merge($nodes, $nodes_by_id, $data);
    }


    my $self = bless {
      nodes => $nodes,
      by_id => $nodes_by_id,
    }, $package;

    $self->build_tree;

    $menu_cache{$domain} = $self;
  } else {
    $menu_cache{$domain}->clear_access;
  }

  $menu_cache{$domain}->set_access;

  return $menu_cache{$domain};
}

sub _merge {
  my ($nodes, $by_id, $data) = @_;

  die 'not an array ref' unless $data && 'ARRAY' eq ref $data; # TODO check this sooner, to get better diag to user

  for my $node (@$data) {
    my $id = $node->{id};

    my $merge_to = $by_id->{$id};

    if (!$merge_to) {
      push @$nodes, $node;
      $by_id->{$id} = $node;
      next;
    }

    # TODO make this a real recursive merge
    # TODO add support for arrays

    # merge keys except params
    for my $key (keys %$node) {
      if (ref $node->{$key}) {
        if ('HASH' eq ref $node->{$key}) {
          $merge_to->{$key} = {} if !exists $merge_to->{$key} || 'HASH' ne ref $merge_to->{$key};
          for (keys %{ $node->{params} }) {
            $merge_to->{$key}{$_} = $node->{params}{$_};
          }
        } else {
          die "unsupported structure @{[ ref $node->{$key} ]}";
        }
      } else {
        $merge_to->{$key} = $node->{$key};
      }
    }
  }
}

sub build_tree {
  my ($self) = @_;

  # first, some sanity check. are all parents valid ids or empty?
  for my $node ($self->nodes) {
    next if !exists $node->{parent} || !$node->{parent} || $self->{by_id}->{$node->{id}};
    die "menu: node $node->{id} has non-existent parent $node->{parent}";
  }

  my %by_parent;
  # order them by parent
  for my $node ($self->nodes) {
    push @{ $by_parent{ $node->{parent} } //= [] }, $node;
  }

  my $tree = { };
  $self->{by_id}{''} = $tree;


  for (keys %by_parent) {
    my $parent = $self->{by_id}{$_};
    $parent->{children} =  [ sort { $a->{order} <=> $b->{order} } @{ $by_parent{$_} } ];
  }

  _set_level_rec($tree->{children}, 0);

  $self->{tree} = $tree->{children};
}

sub _set_level_rec {
  my ($ary_ref, $level) = @_;

  for (@$ary_ref) {
    $_->{level} = $level;
    _set_level_rec($_->{children}, $level + 1) if $_->{children};
  }
}

sub nodes {
  @{ $_[0]{nodes} }
}

sub tree_walk {
  my ($self, $all) = @_;

  _tree_walk_rec($self->{tree}, $all);
}

sub _tree_walk_rec {
  my ($ary_ref, $all) = @_;
  map { $_->{children} ? ($_, _tree_walk_rec($_->{children}, $all)) : ($_) } grep { $all || $_->{visible} } @$ary_ref;
}

sub parse_access_string {
  my ($self, $node) = @_;

  my @stack;
  my $cur_ary = [];

  push @stack, $cur_ary;

  my $access = $node->{access};

  while ($access =~ m/^([a-z_\/]+|\||\&|\(|\)|\s+)/) {
    my $token = $1;
    substr($access, 0, length($1)) = "";

    next if ($token =~ /\s/);

    if ($token eq "(") {
      my $new_cur_ary = [];
      push @stack, $new_cur_ary;
      push @{$cur_ary}, $new_cur_ary;
      $cur_ary = $new_cur_ary;

    } elsif ($token eq ")") {
      pop @stack;
      if (!@stack) {
        die "Error while parsing menu entry $node->{id}: missing '('";
      }
      $cur_ary = $stack[-1];

    } elsif (($token eq "|") || ($token eq "&")) {
      push @{$cur_ary}, $token;

    } else {
      if ($token =~ m{^ client / (.*) }x) {
        push @{$cur_ary}, $self->parse_instance_conf_string($1);
      } else {
        push @{$cur_ary}, $::auth->check_right($::myconfig{login}, $token, 1);
      }
    }
  }

  if ($access) {
    die "Error while parsing menu entry $node->{id}: unrecognized token at the start of '$access'\n";
  }

  if (1 < scalar @stack) {
    die "Error while parsing menu entry $node->{id}: Missing ')'\n";
  }

  return SL::Auth::evaluate_rights_ary($stack[0]);
}

sub href_for_node {
  my ($self, $node) = @_;

  return undef if !$node->{href} && !$node->{module} && !$node->{params};

  my $href = $node->{href} || $node->{module} || 'controller.pl';
  my @tokens;

  while (my ($key, $value) = each %{ $node->{params} }) {
    push @tokens, uri_encode($key, 1) . "=" . uri_encode($value, 1);
  }

  return join '?', $href, grep $_, join '&', @tokens;
}

sub name_for_node {
  $::locale->text($_[1]{name})
}

sub parse_instance_conf_string {
  my ($self, $setting) = @_;
  return $::instance_conf->data->{$setting};
}

sub clear_access {
  my ($self) = @_;
  for my $node ($self->tree_walk("all")) {
    delete $node->{visible};
    delete $node->{visible_children};
  }
}

sub set_access {
  my ($self) = @_;
  my $features = $::auth->load_features_for_client;
  # 1. evaluate access for all
  # 2. if a menu has no visible children, its not visible either

  for my $node (reverse $self->tree_walk("all")) {
    $node->{visible} = $node->{check}            ? $node->{check} ~~ $features : 1
                    && $node->{access}           ? $self->parse_access_string($node)
                     : !$node->{children}        ? 1
                     : $node->{visible_children} ? 1
                     :                             0;
    if ($node->{visible} && $node->{parent}) {
      $self->{by_id}{ $node->{parent} }{visible_children} = 1;
    }
  }
}

1;

