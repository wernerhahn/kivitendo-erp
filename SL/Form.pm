#========= ===========================================================
# LX-Office ERP
# Copyright (C) 2004
# Based on SQL-Ledger Version 2.1.9
# Web http://www.lx-office.org
#
#=====================================================================
# SQL-Ledger Accounting
# Copyright (C) 1998-2002
#
#  Author: Dieter Simader
#   Email: dsimader@sql-ledger.org
#     Web: http://www.sql-ledger.org
#
# Contributors: Thomas Bayen <bayen@gmx.de>
#               Antti Kaihola <akaihola@siba.fi>
#               Moritz Bunkus (tex code)
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#======================================================================
# Utilities for parsing forms
# and supporting routines for linking account numbers
# used in AR, AP and IS, IR modules
#
#======================================================================

package Form;

use Carp;
use Data::Dumper;

use Carp;
use Config;
use CGI;
use Cwd;
use Encode;
use File::Copy;
use IO::File;
use Math::BigInt;
use SL::Auth;
use SL::Auth::DB;
use SL::Auth::LDAP;
use SL::AM;
use SL::Common;
use SL::CVar;
use SL::DB;
use SL::DBConnect;
use SL::DBUtils;
use SL::DB::Customer;
use SL::DB::Default;
use SL::DB::PaymentTerm;
use SL::DB::Vendor;
use SL::DO;
use SL::IC;
use SL::IS;
use SL::Layout::Dispatcher;
use SL::Locale;
use SL::Locale::String;
use SL::Mailer;
use SL::Menu;
use SL::MoreCommon qw(uri_encode uri_decode);
use SL::OE;
use SL::PrefixedNumber;
use SL::Request;
use SL::Template;
use SL::User;
use SL::Util;
use SL::X;
use Template;
use URI;
use List::Util qw(first max min sum);
use List::MoreUtils qw(all any apply);
use SL::DB::Tax;

use strict;

my $standard_dbh;

END {
  disconnect_standard_dbh();
}

sub disconnect_standard_dbh {
  return unless $standard_dbh;

  $standard_dbh->rollback();
  undef $standard_dbh;
}

sub read_version {
  my ($self) = @_;

  open VERSION_FILE, "VERSION";                 # New but flexible code reads version from VERSION-file
  my $version =  <VERSION_FILE>;
  $version    =~ s/[^0-9A-Za-z\.\_\-]//g; # only allow numbers, letters, points, underscores and dashes. Prevents injecting of malicious code.
  close VERSION_FILE;

  return $version;
}

sub new {
  $main::lxdebug->enter_sub();

  my $type = shift;

  my $self = {};

  no warnings 'once';
  if ($LXDebug::watch_form) {
    require SL::Watchdog;
    tie %{ $self }, 'SL::Watchdog';
  }

  bless $self, $type;

  $self->{version} = $self->read_version;

  $main::lxdebug->leave_sub();

  return $self;
}

sub read_cgi_input {
  my ($self) = @_;
  SL::Request::read_cgi_input($self);
}

sub _flatten_variables_rec {
  $main::lxdebug->enter_sub(2);

  my $self   = shift;
  my $curr   = shift;
  my $prefix = shift;
  my $key    = shift;

  my @result;

  if ('' eq ref $curr->{$key}) {
    @result = ({ 'key' => $prefix . $key, 'value' => $curr->{$key} });

  } elsif ('HASH' eq ref $curr->{$key}) {
    foreach my $hash_key (sort keys %{ $curr->{$key} }) {
      push @result, $self->_flatten_variables_rec($curr->{$key}, $prefix . $key . '.', $hash_key);
    }

  } else {
    foreach my $idx (0 .. scalar @{ $curr->{$key} } - 1) {
      my $first_array_entry = 1;

      my $element = $curr->{$key}[$idx];

      if ('HASH' eq ref $element) {
        foreach my $hash_key (sort keys %{ $element }) {
          push @result, $self->_flatten_variables_rec($element, $prefix . $key . ($first_array_entry ? '[+].' : '[].'), $hash_key);
          $first_array_entry = 0;
        }
      } else {
        @result = ({ 'key' => $prefix . $key . ($first_array_entry ? '[+]' : '[]'), 'value' => $element });
      }
    }
  }

  $main::lxdebug->leave_sub(2);

  return @result;
}

sub flatten_variables {
  $main::lxdebug->enter_sub(2);

  my $self = shift;
  my @keys = @_;

  my @variables;

  foreach (@keys) {
    push @variables, $self->_flatten_variables_rec($self, '', $_);
  }

  $main::lxdebug->leave_sub(2);

  return @variables;
}

sub flatten_standard_variables {
  $main::lxdebug->enter_sub(2);

  my $self      = shift;
  my %skip_keys = map { $_ => 1 } (qw(login password header stylesheet titlebar version), @_);

  my @variables;

  foreach (grep { ! $skip_keys{$_} } keys %{ $self }) {
    push @variables, $self->_flatten_variables_rec($self, '', $_);
  }

  $main::lxdebug->leave_sub(2);

  return @variables;
}

sub debug {
  $main::lxdebug->enter_sub();

  my ($self) = @_;

  print "\n";

  map { print "$_ = $self->{$_}\n" } (sort keys %{$self});

  $main::lxdebug->leave_sub();
}

sub dumper {
  $main::lxdebug->enter_sub(2);

  my $self          = shift;
  my $password      = $self->{password};

  $self->{password} = 'X' x 8;

  local $Data::Dumper::Sortkeys = 1;
  my $output                    = Dumper($self);

  $self->{password} = $password;

  $main::lxdebug->leave_sub(2);

  return $output;
}

sub escape {
  my ($self, $str) = @_;

  return uri_encode($str);
}

sub unescape {
  my ($self, $str) = @_;

  return uri_decode($str);
}

sub quote {
  $main::lxdebug->enter_sub();
  my ($self, $str) = @_;

  if ($str && !ref($str)) {
    $str =~ s/\"/&quot;/g;
  }

  $main::lxdebug->leave_sub();

  return $str;
}

sub unquote {
  $main::lxdebug->enter_sub();
  my ($self, $str) = @_;

  if ($str && !ref($str)) {
    $str =~ s/&quot;/\"/g;
  }

  $main::lxdebug->leave_sub();

  return $str;
}

sub hide_form {
  $main::lxdebug->enter_sub();
  my $self = shift;

  if (@_) {
    map({ print($::request->{cgi}->hidden("-name" => $_, "-default" => $self->{$_}) . "\n"); } @_);
  } else {
    for (sort keys %$self) {
      next if (($_ eq "header") || (ref($self->{$_}) ne ""));
      print($::request->{cgi}->hidden("-name" => $_, "-default" => $self->{$_}) . "\n");
    }
  }
  $main::lxdebug->leave_sub();
}

sub throw_on_error {
  my ($self, $code) = @_;
  local $self->{__ERROR_HANDLER} = sub { die SL::X::FormError->new($_[0]) };
  $code->();
}

sub error {
  $main::lxdebug->enter_sub();

  $main::lxdebug->show_backtrace();

  my ($self, $msg) = @_;

  if ($self->{__ERROR_HANDLER}) {
    $self->{__ERROR_HANDLER}->($msg);

  } elsif ($ENV{HTTP_USER_AGENT}) {
    $msg =~ s/\n/<br>/g;
    $self->show_generic_error($msg);

  } else {
    confess "Error: $msg\n";
  }

  $main::lxdebug->leave_sub();
}

sub info {
  $main::lxdebug->enter_sub();

  my ($self, $msg) = @_;

  if ($ENV{HTTP_USER_AGENT}) {
    $self->header;
    print $self->parse_html_template('generic/form_info', { message => $msg });

  } elsif ($self->{info_function}) {
    &{ $self->{info_function} }($msg);
  } else {
    print "$msg\n";
  }

  $main::lxdebug->leave_sub();
}

# calculates the number of rows in a textarea based on the content and column number
# can be capped with maxrows
sub numtextrows {
  $main::lxdebug->enter_sub();
  my ($self, $str, $cols, $maxrows, $minrows) = @_;

  $minrows ||= 1;

  my $rows   = sum map { int((length() - 2) / $cols) + 1 } split /\r/, $str;
  $maxrows ||= $rows;

  $main::lxdebug->leave_sub();

  return max(min($rows, $maxrows), $minrows);
}

sub dberror {
  $main::lxdebug->enter_sub();

  my ($self, $msg) = @_;

  $self->error("$msg\n" . $DBI::errstr);

  $main::lxdebug->leave_sub();
}

sub isblank {
  $main::lxdebug->enter_sub();

  my ($self, $name, $msg) = @_;

  my $curr = $self;
  foreach my $part (split m/\./, $name) {
    if (!$curr->{$part} || ($curr->{$part} =~ /^\s*$/)) {
      $self->error($msg);
    }
    $curr = $curr->{$part};
  }

  $main::lxdebug->leave_sub();
}

sub _get_request_uri {
  my $self = shift;

  return URI->new($ENV{HTTP_REFERER})->canonical() if $ENV{HTTP_X_FORWARDED_FOR};
  return URI->new                                  if !$ENV{REQUEST_URI}; # for testing

  my $scheme =  $ENV{HTTPS} && (lc $ENV{HTTPS} eq 'on') ? 'https' : 'http';
  my $port   =  $ENV{SERVER_PORT};
  $port      =  undef if (($scheme eq 'http' ) && ($port == 80))
                      || (($scheme eq 'https') && ($port == 443));

  my $uri    =  URI->new("${scheme}://");
  $uri->scheme($scheme);
  $uri->port($port);
  $uri->host($ENV{HTTP_HOST} || $ENV{SERVER_ADDR});
  $uri->path_query($ENV{REQUEST_URI});
  $uri->query('');

  return $uri;
}

sub _add_to_request_uri {
  my $self              = shift;

  my $relative_new_path = shift;
  my $request_uri       = shift || $self->_get_request_uri;
  my $relative_new_uri  = URI->new($relative_new_path);
  my @request_segments  = $request_uri->path_segments;

  my $new_uri           = $request_uri->clone;
  $new_uri->path_segments(@request_segments[0..scalar(@request_segments) - 2], $relative_new_uri->path_segments);

  return $new_uri;
}

sub create_http_response {
  $main::lxdebug->enter_sub();

  my $self     = shift;
  my %params   = @_;

  my $cgi      = $::request->{cgi};

  my $session_cookie;
  if (defined $main::auth) {
    my $uri      = $self->_get_request_uri;
    my @segments = $uri->path_segments;
    pop @segments;
    $uri->path_segments(@segments);

    my $session_cookie_value = $main::auth->get_session_id();

    if ($session_cookie_value) {
      $session_cookie = $cgi->cookie('-name'   => $main::auth->get_session_cookie_name(),
                                     '-value'  => $session_cookie_value,
                                     '-path'   => $uri->path,
                                     '-secure' => $ENV{HTTPS});
    }
  }

  my %cgi_params = ('-type' => $params{content_type});
  $cgi_params{'-charset'} = $params{charset} if ($params{charset});
  $cgi_params{'-cookie'}  = $session_cookie  if ($session_cookie);

  map { $cgi_params{'-' . $_} = $params{$_} if exists $params{$_} } qw(content_disposition content_length);

  my $output = $cgi->header(%cgi_params);

  $main::lxdebug->leave_sub();

  return $output;
}

sub header {
  $::lxdebug->enter_sub;

  my ($self, %params) = @_;
  my @header;

  $::lxdebug->leave_sub and return if !$ENV{HTTP_USER_AGENT} || $self->{header}++;

  if ($params{no_layout}) {
    $::request->{layout} = SL::Layout::Dispatcher->new(style => 'none');
  }

  my $layout = $::request->{layout};

  # standard css for all
  # this should gradually move to the layouts that need it
  $layout->use_stylesheet("$_.css") for qw(
    common main menu list_accounts jquery.autocomplete
    jquery.multiselect2side
    ui-lightness/jquery-ui
    jquery-ui.custom
    tooltipster themes/tooltipster-light
  );

  $layout->use_javascript("$_.js") for (qw(
    jquery jquery-ui jquery.cookie jquery.checkall jquery.download
    jquery/jquery.form jquery/fixes client_js
    jquery/jquery.tooltipster.min
    common part_selection
  ), "jquery/ui/i18n/jquery.ui.datepicker-$::myconfig{countrycode}");

  $self->{favicon} ||= "favicon.ico";
  $self->{titlebar} = join ' - ', grep $_, $self->{title}, $self->{login}, $::myconfig{dbname}, $self->{version} if $self->{title} || !$self->{titlebar};

  # build includes
  if ($self->{refresh_url} || $self->{refresh_time}) {
    my $refresh_time = $self->{refresh_time} || 3;
    my $refresh_url  = $self->{refresh_url}  || $ENV{REFERER};
    push @header, "<meta http-equiv='refresh' content='$refresh_time;$refresh_url'>";
  }

  my $auto_reload_resources_param = $layout->auto_reload_resources_param;

  push @header, map { qq|<link rel="stylesheet" href="${_}${auto_reload_resources_param}" type="text/css" title="Stylesheet">| } $layout->stylesheets;
  push @header, "<style type='text/css'>\@page { size:landscape; }</style> "                     if $self->{landscape};
  push @header, "<link rel='shortcut icon' href='$self->{favicon}' type='image/x-icon'>"         if -f $self->{favicon};
  push @header, map { qq|<script type="text/javascript" src="${_}${auto_reload_resources_param}"></script>| }                    $layout->javascripts;
  push @header, $self->{javascript} if $self->{javascript};
  push @header, map { $_->show_javascript } @{ $self->{AJAX} || [] };

  my  %doctypes = (
    strict       => qq|<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">|,
    transitional => qq|<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">|,
    frameset     => qq|<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Frameset//EN" "http://www.w3.org/TR/html4/frameset.dtd">|,
    html5        => qq|<!DOCTYPE html>|,
  );

  # output
  print $self->create_http_response(content_type => 'text/html', charset => 'UTF-8');
  print $doctypes{$params{doctype} || 'transitional'}, $/;
  print <<EOT;
<html>
 <head>
  <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
  <title>$self->{titlebar}</title>
EOT
  print "  $_\n" for @header;
  print <<EOT;
  <meta name="robots" content="noindex,nofollow">
 </head>
 <body>

EOT
  print $::request->{layout}->pre_content;
  print $::request->{layout}->start_content;

  $layout->header_done;

  $::lxdebug->leave_sub;
}

sub footer {
  return unless $::request->{layout}->need_footer;

  print $::request->{layout}->end_content;
  print $::request->{layout}->post_content;

  if (my @inline_scripts = $::request->{layout}->javascripts_inline) {
    print "<script type='text/javascript'>" . join("; ", @inline_scripts) . "</script>\n";
  }

  print <<EOL
 </body>
</html>
EOL
}

sub ajax_response_header {
  $main::lxdebug->enter_sub();

  my ($self) = @_;

  my $output = $::request->{cgi}->header('-charset' => 'UTF-8');

  $main::lxdebug->leave_sub();

  return $output;
}

sub redirect_header {
  my $self     = shift;
  my $new_url  = shift;

  my $base_uri = $self->_get_request_uri;
  my $new_uri  = URI->new_abs($new_url, $base_uri);

  die "Headers already sent" if $self->{header};
  $self->{header} = 1;

  return $::request->{cgi}->redirect($new_uri);
}

sub set_standard_title {
  $::lxdebug->enter_sub;
  my $self = shift;

  $self->{titlebar}  = "kivitendo " . $::locale->text('Version') . " $self->{version}";
  $self->{titlebar} .= "- $::myconfig{name}"   if $::myconfig{name};
  $self->{titlebar} .= "- $::myconfig{dbname}" if $::myconfig{name};

  $::lxdebug->leave_sub;
}

sub _prepare_html_template {
  $main::lxdebug->enter_sub();

  my ($self, $file, $additional_params) = @_;
  my $language;

  if (!%::myconfig || !$::myconfig{"countrycode"}) {
    $language = $::lx_office_conf{system}->{language};
  } else {
    $language = $main::myconfig{"countrycode"};
  }
  $language = "de" unless ($language);

  if (-f "templates/webpages/${file}.html") {
    $file = "templates/webpages/${file}.html";

  } elsif (ref $file eq 'SCALAR') {
    # file is a scalarref, use inline mode
  } else {
    my $info = "Web page template '${file}' not found.\n";
    $::form->header;
    print qq|<pre>$info</pre>|;
    $::dispatcher->end_request;
  }

  $additional_params->{AUTH}          = $::auth;
  $additional_params->{INSTANCE_CONF} = $::instance_conf;
  $additional_params->{LOCALE}        = $::locale;
  $additional_params->{LXCONFIG}      = \%::lx_office_conf;
  $additional_params->{LXDEBUG}       = $::lxdebug;
  $additional_params->{MYCONFIG}      = \%::myconfig;

  $main::lxdebug->leave_sub();

  return $file;
}

sub parse_html_template {
  $main::lxdebug->enter_sub();

  my ($self, $file, $additional_params) = @_;

  $additional_params ||= { };

  my $real_file = $self->_prepare_html_template($file, $additional_params);
  my $template  = $self->template || $self->init_template;

  map { $additional_params->{$_} ||= $self->{$_} } keys %{ $self };

  my $output;
  $template->process($real_file, $additional_params, \$output) || die $template->error;

  $main::lxdebug->leave_sub();

  return $output;
}

sub init_template {
  my $self = shift;

  return $self->template if $self->template;

  # Force scripts/locales.pl to pick up the exception handling template.
  # parse_html_template('generic/exception')
  return $self->template(Template->new({
     'INTERPOLATE'  => 0,
     'EVAL_PERL'    => 0,
     'ABSOLUTE'     => 1,
     'CACHE_SIZE'   => 0,
     'PLUGIN_BASE'  => 'SL::Template::Plugin',
     'INCLUDE_PATH' => '.:templates/webpages',
     'COMPILE_EXT'  => '.tcc',
     'COMPILE_DIR'  => $::lx_office_conf{paths}->{userspath} . '/templates-cache',
     'ERROR'        => 'templates/webpages/generic/exception.html',
     'ENCODING'     => 'utf8',
  })) || die;
}

sub template {
  my $self = shift;
  $self->{template_object} = shift if @_;
  return $self->{template_object};
}

sub show_generic_error {
  $main::lxdebug->enter_sub();

  my ($self, $error, %params) = @_;

  if ($self->{__ERROR_HANDLER}) {
    $self->{__ERROR_HANDLER}->($error);
    $main::lxdebug->leave_sub();
    return;
  }

  if ($::request->is_ajax) {
    SL::ClientJS->new
      ->error($error)
      ->render(SL::Controller::Base->new);
    $::dispatcher->end_request;
  }

  my $add_params = {
    'title_error' => $params{title},
    'label_error' => $error,
  };

  if ($params{action}) {
    my @vars;

    map { delete($self->{$_}); } qw(action);
    map { push @vars, { "name" => $_, "value" => $self->{$_} } if (!ref($self->{$_})); } keys %{ $self };

    $add_params->{SHOW_BUTTON}  = 1;
    $add_params->{BUTTON_LABEL} = $params{label} || $params{action};
    $add_params->{VARIABLES}    = \@vars;

  } elsif ($params{back_button}) {
    $add_params->{SHOW_BACK_BUTTON} = 1;
  }

  $self->{title} = $params{title} if $params{title};

  $self->header();
  print $self->parse_html_template("generic/error", $add_params);

  print STDERR "Error: $error\n";

  $main::lxdebug->leave_sub();

  $::dispatcher->end_request;
}

sub show_generic_information {
  $main::lxdebug->enter_sub();

  my ($self, $text, $title) = @_;

  my $add_params = {
    'title_information' => $title,
    'label_information' => $text,
  };

  $self->{title} = $title if ($title);

  $self->header();
  print $self->parse_html_template("generic/information", $add_params);

  $main::lxdebug->leave_sub();

  $::dispatcher->end_request;
}

sub _store_redirect_info_in_session {
  my ($self) = @_;

  return unless $self->{callback} =~ m:^ ( [^\?/]+ \.pl ) \? (.+) :x;

  my ($controller, $params) = ($1, $2);
  my $form                  = { map { map { $self->unescape($_) } split /=/, $_, 2 } split m/\&/, $params };
  $self->{callback}         = "${controller}?RESTORE_FORM_FROM_SESSION_ID=" . $::auth->save_form_in_session(form => $form);
}

sub redirect {
  $main::lxdebug->enter_sub();

  my ($self, $msg) = @_;

  if (!$self->{callback}) {
    $self->info($msg);

  } else {
    $self->_store_redirect_info_in_session;
    print $::form->redirect_header($self->{callback});
  }

  $::dispatcher->end_request;

  $main::lxdebug->leave_sub();
}

# sort of columns removed - empty sub
sub sort_columns {
  $main::lxdebug->enter_sub();

  my ($self, @columns) = @_;

  $main::lxdebug->leave_sub();

  return @columns;
}
#
sub format_amount {
  $main::lxdebug->enter_sub(2);

  my ($self, $myconfig, $amount, $places, $dash) = @_;
  $amount ||= 0;
  $dash   ||= '';
  my $neg = $amount < 0;
  my $force_places = defined $places && $places >= 0;

  $amount = $self->round_amount($amount, abs $places) if $force_places;
  $neg    = 0 if $amount == 0; # don't show negative zero
  $amount = sprintf "%.*f", ($force_places ? $places : 10), abs $amount; # 6 is default for %fa

  # before the sprintf amount was a number, afterwards it's a string. because of the dynamic nature of perl
  # this is easy to confuse, so keep in mind: before this comment no s///, m//, concat or other strong ops on
  # $amount. after this comment no +,-,*,/,abs. it will only introduce subtle bugs.

  $amount =~ s/0*$// unless defined $places && $places == 0;             # cull trailing 0s

  my @d = map { s/\d//g; reverse split // } my $tmp = $myconfig->{numberformat}; # get delim chars
  my @p = split(/\./, $amount);                                          # split amount at decimal point

  $p[0] =~ s/\B(?=(...)*$)/$d[1]/g if $d[1];                             # add 1,000 delimiters
  $amount = $p[0];
  if ($places || $p[1]) {
    $amount .= $d[0]
            .  ( $p[1] || '' )
            .  (0 x max(abs($places || 0) - length ($p[1]||''), 0));     # pad the fraction
  }

  $amount = do {
    ($dash =~ /-/)    ? ($neg ? "($amount)"                            : "$amount" )                              :
    ($dash =~ /DRCR/) ? ($neg ? "$amount " . $main::locale->text('DR') : "$amount " . $main::locale->text('CR') ) :
                        ($neg ? "-$amount"                             : "$amount" )                              ;
  };

  $main::lxdebug->leave_sub(2);
  return $amount;
}

sub format_amount_units {
  $main::lxdebug->enter_sub();

  my $self             = shift;
  my %params           = @_;

  my $myconfig         = \%main::myconfig;
  my $amount           = $params{amount} * 1;
  my $places           = $params{places};
  my $part_unit_name   = $params{part_unit};
  my $amount_unit_name = $params{amount_unit};
  my $conv_units       = $params{conv_units};
  my $max_places       = $params{max_places};

  if (!$part_unit_name) {
    $main::lxdebug->leave_sub();
    return '';
  }

  my $all_units        = AM->retrieve_all_units;

  if (('' eq ref $conv_units) && ($conv_units =~ /convertible/)) {
    $conv_units = AM->convertible_units($all_units, $part_unit_name, $conv_units eq 'convertible_not_smaller');
  }

  if (!scalar @{ $conv_units }) {
    my $result = $self->format_amount($myconfig, $amount, $places, undef, $max_places) . " " . $part_unit_name;
    $main::lxdebug->leave_sub();
    return $result;
  }

  my $part_unit  = $all_units->{$part_unit_name};
  my $conv_unit  = ($amount_unit_name && ($amount_unit_name ne $part_unit_name)) ? $all_units->{$amount_unit_name} : $part_unit;

  $amount       *= $conv_unit->{factor};

  my @values;
  my $num;

  foreach my $unit (@$conv_units) {
    my $last = $unit->{name} eq $part_unit->{name};
    if (!$last) {
      $num     = int($amount / $unit->{factor});
      $amount -= $num * $unit->{factor};
    }

    if ($last ? $amount : $num) {
      push @values, { "unit"   => $unit->{name},
                      "amount" => $last ? $amount / $unit->{factor} : $num,
                      "places" => $last ? $places : 0 };
    }

    last if $last;
  }

  if (!@values) {
    push @values, { "unit"   => $part_unit_name,
                    "amount" => 0,
                    "places" => 0 };
  }

  my $result = join " ", map { $self->format_amount($myconfig, $_->{amount}, $_->{places}, undef, $max_places), $_->{unit} } @values;

  $main::lxdebug->leave_sub();

  return $result;
}

sub format_string {
  $main::lxdebug->enter_sub(2);

  my $self  = shift;
  my $input = shift;

  $input =~ s/(^|[^\#]) \#  (\d+)  /$1$_[$2 - 1]/gx;
  $input =~ s/(^|[^\#]) \#\{(\d+)\}/$1$_[$2 - 1]/gx;
  $input =~ s/\#\#/\#/g;

  $main::lxdebug->leave_sub(2);

  return $input;
}

#

sub parse_amount {
  $main::lxdebug->enter_sub(2);

  my ($self, $myconfig, $amount) = @_;

  if (!defined($amount) || ($amount eq '')) {
    $main::lxdebug->leave_sub(2);
    return 0;
  }

  if (   ($myconfig->{numberformat} eq '1.000,00')
      || ($myconfig->{numberformat} eq '1000,00')) {
    $amount =~ s/\.//g;
    $amount =~ s/,/\./g;
  }

  if ($myconfig->{numberformat} eq "1'000.00") {
    $amount =~ s/\'//g;
  }

  $amount =~ s/,//g;

  $main::lxdebug->leave_sub(2);

  # Make sure no code wich is not a math expression ends up in eval().
  return 0 unless $amount =~ /^ [\s \d \( \) \- \+ \* \/ \. ]* $/x;

  # Prevent numbers from being parsed as octals;
  $amount =~ s{ (?<! [\d.] ) 0+ (?= [1-9] ) }{}gx;

  return scalar(eval($amount)) * 1 ;
}

sub round_amount {
  my ($self, $amount, $places, $adjust) = @_;

  return 0 if !defined $amount;

  $places //= 0;

  if ($adjust) {
    my $precision = $::instance_conf->get_precision || 0.01;
    return $self->round_amount( $self->round_amount($amount / $precision, 0) * $precision, $places);
  }

  # We use Perl's knowledge of string representation for
  # rounding. First, convert the floating point number to a string
  # with a high number of places. Then split the string on the decimal
  # sign and use integer calculation for rounding the decimal places
  # part. If an overflow occurs then apply that overflow to the part
  # before the decimal sign as well using integer arithmetic again.

  my $int_amount = int(abs $amount);
  my $str_places = max(min(10, 16 - length("$int_amount") - $places), $places);
  my $amount_str = sprintf '%.*f', $places + $str_places, abs($amount);

  return $amount unless $amount_str =~ m{^(\d+)\.(\d+)$};

  my ($pre, $post)      = ($1, $2);
  my $decimals          = '1' . substr($post, 0, $places);

  my $propagation_limit = $Config{i32size} == 4 ? 7 : 18;
  my $add_for_rounding  = substr($post, $places, 1) >= 5 ? 1 : 0;

  if ($places > $propagation_limit) {
    $decimals = Math::BigInt->new($decimals)->badd($add_for_rounding);
    $pre      = Math::BigInt->new($decimals)->badd(1) if substr($decimals, 0, 1) eq '2';

  } else {
    $decimals += $add_for_rounding;
    $pre      += 1 if substr($decimals, 0, 1) eq '2';
  }

  $amount  = ("${pre}." . substr($decimals, 1)) * ($amount <=> 0);

  return $amount;
}

sub parse_template {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig) = @_;
  my ($out, $out_mode);

  local (*IN, *OUT);

  my $defaults  = SL::DB::Default->get;
  my $userspath = $::lx_office_conf{paths}->{userspath};

  $self->{"cwd"} = getcwd();
  $self->{"tmpdir"} = $self->{cwd} . "/${userspath}";

  my $ext_for_format;

  my $template_type;
  if ($self->{"format"} =~ /(opendocument|oasis)/i) {
    $template_type  = 'OpenDocument';
    $ext_for_format = $self->{"format"} =~ m/pdf/ ? 'pdf' : 'odt';

  } elsif ($self->{"format"} =~ /(postscript|pdf)/i) {
    $template_type    = 'LaTeX';
    $ext_for_format   = 'pdf';

  } elsif (($self->{"format"} =~ /html/i) || (!$self->{"format"} && ($self->{"IN"} =~ /html$/i))) {
    $template_type  = 'HTML';
    $ext_for_format = 'html';

  } elsif (($self->{"format"} =~ /xml/i) || (!$self->{"format"} && ($self->{"IN"} =~ /xml$/i))) {
    $template_type  = 'XML';
    $ext_for_format = 'xml';

  } elsif ( $self->{"format"} =~ /elster(?:winston|taxbird)/i ) {
    $template_type = 'XML';

  } elsif ( $self->{"format"} =~ /excel/i ) {
    $template_type  = 'Excel';
    $ext_for_format = 'xls';

  } elsif ( defined $self->{'format'}) {
    $self->error("Outputformat not defined. This may be a future feature: $self->{'format'}");

  } elsif ( $self->{'format'} eq '' ) {
    $self->error("No Outputformat given: $self->{'format'}");

  } else { #Catch the rest
    $self->error("Outputformat not defined: $self->{'format'}");
  }

  my $template = SL::Template::create(type      => $template_type,
                                      file_name => $self->{IN},
                                      form      => $self,
                                      myconfig  => $myconfig,
                                      userspath => $userspath,
                                      %{ $self->{TEMPLATE_DRIVER_OPTIONS} || {} });

  # Copy the notes from the invoice/sales order etc. back to the variable "notes" because that is where most templates expect it to be.
  $self->{"notes"} = $self->{ $self->{"formname"} . "notes" } if exists $self->{ $self->{"formname"} . "notes" };

  if (!$self->{employee_id}) {
    $self->{"employee_${_}"} = $myconfig->{$_} for qw(email tel fax name signature);
    $self->{"employee_${_}"} = $defaults->$_   for qw(address businessnumber co_ustid company duns sepa_creditor_id taxnumber);
  }

  $self->{"myconfig_${_}"} = $myconfig->{$_} for grep { $_ ne 'dbpasswd' } keys %{ $myconfig };
  $self->{$_}              = $defaults->$_   for qw(co_ustid);
  $self->{"myconfig_${_}"} = $defaults->$_   for qw(address businessnumber co_ustid company duns sepa_creditor_id taxnumber);
  $self->{AUTH}            = $::auth;
  $self->{INSTANCE_CONF}   = $::instance_conf;
  $self->{LOCALE}          = $::locale;
  $self->{LXCONFIG}        = $::lx_office_conf;
  $self->{LXDEBUG}         = $::lxdebug;
  $self->{MYCONFIG}        = \%::myconfig;

  $self->{copies} = 1 if (($self->{copies} *= 1) <= 0);

  # OUT is used for the media, screen, printer, email
  # for postscript we store a copy in a temporary file
  my ($temp_fh, $suffix);
  $suffix =  $self->{IN};
  $suffix =~ s/.*\.//;
  ($temp_fh, $self->{tmpfile}) = File::Temp::tempfile(
    'kivitendo-printXXXXXX',
    SUFFIX => '.' . ($suffix || 'tex'),
    DIR    => $userspath,
    UNLINK => ($::lx_office_conf{debug} && $::lx_office_conf{debug}->{keep_temp_files})? 0 : 1,
  );
  close $temp_fh;
  (undef, undef, $self->{template_meta}{tmpfile}) = File::Spec->splitpath( $self->{tmpfile} );

  $out              = $self->{OUT};
  $out_mode         = $self->{OUT_MODE} || '>';
  $self->{OUT}      = "$self->{tmpfile}";
  $self->{OUT_MODE} = '>';

  my $result;
  my $command_formatter = sub {
    my ($out_mode, $out) = @_;
    return $out_mode eq '|-' ? SL::Template::create(type => 'ShellCommand', form => $self)->parse($out) : $out;
  };

  if ($self->{OUT}) {
    $self->{OUT} = $command_formatter->($self->{OUT_MODE}, $self->{OUT});
    open(OUT, $self->{OUT_MODE}, $self->{OUT}) or $self->error("error on opening $self->{OUT} with mode $self->{OUT_MODE} : $!");
  } else {
    *OUT = ($::dispatcher->get_standard_filehandles)[1];
    $self->header;
  }

  if (!$template->parse(*OUT)) {
    $self->cleanup();
    $self->error("$self->{IN} : " . $template->get_error());
  }

  close OUT if $self->{OUT};
  # check only one flag (webdav_documents)
  # therefore copy to webdav, even if we do not have the webdav feature enabled (just archive)
  my $copy_to_webdav =  $::instance_conf->get_webdav_documents && !$self->{preview} && $self->{tmpdir} && $self->{tmpfile} && $self->{type};

  if ($self->{media} eq 'file') {
    copy(join('/', $self->{cwd}, $userspath, $self->{tmpfile}), $out =~ m|^/| ? $out : join('/', $self->{cwd}, $out)) if $template->uses_temp_file;
    Common::copy_file_to_webdav_folder($self)                                                                         if $copy_to_webdav;
    $self->cleanup;
    chdir("$self->{cwd}");

    $::lxdebug->leave_sub();

    return;
  }

  Common::copy_file_to_webdav_folder($self) if $copy_to_webdav;

  if ($self->{media} eq 'email') {

    my $mail = Mailer->new;

    map { $mail->{$_} = $self->{$_} }
      qw(cc bcc subject message version format);
    $mail->{to} = $self->{EMAIL_RECIPIENT} ? $self->{EMAIL_RECIPIENT} : $self->{email};
    $mail->{from}   = qq|"$myconfig->{name}" <$myconfig->{email}>|;
    $mail->{fileid} = time() . '.' . $$ . '.';
    my $full_signature     =  $self->create_email_signature();
    $full_signature        =~ s/\r//g;

    # if we send html or plain text inline
    if (($self->{format} eq 'html') && ($self->{sendmode} eq 'inline')) {
      $mail->{contenttype}    =  "text/html";
      $mail->{message}        =~ s/\r//g;
      $mail->{message}        =~ s/\n/<br>\n/g;
      $full_signature         =~ s/\n/<br>\n/g;
      $mail->{message}       .=  $full_signature;

      open(IN, "<:encoding(UTF-8)", $self->{tmpfile})
        or $self->error($self->cleanup . "$self->{tmpfile} : $!");
      $mail->{message} .= $_ while <IN>;
      close(IN);

    } else {

      if (!$self->{"do_not_attach"}) {
        my $attachment_name  =  $self->{attachment_filename} || $self->{tmpfile};
        $attachment_name     =~ s/\.(.+?)$/.${ext_for_format}/ if ($ext_for_format);
        $mail->{attachments} =  [{ "filename" => $self->{tmpfile},
                                   "name"     => $attachment_name }];
      }

      $mail->{message} .= $full_signature;
    }

    my $err = $mail->send();
    $self->error($self->cleanup . "$err") if ($err);

  } else {

    $self->{OUT}      = $out;
    $self->{OUT_MODE} = $out_mode;

    my $numbytes = (-s $self->{tmpfile});
    open(IN, "<", $self->{tmpfile})
      or $self->error($self->cleanup . "$self->{tmpfile} : $!");
    binmode IN;

    $self->{copies} = 1 unless $self->{media} eq 'printer';

    chdir("$self->{cwd}");
    #print(STDERR "Kopien $self->{copies}\n");
    #print(STDERR "OUT $self->{OUT}\n");
    for my $i (1 .. $self->{copies}) {
      if ($self->{OUT}) {
        $self->{OUT} = $command_formatter->($self->{OUT_MODE}, $self->{OUT});

        open  OUT, $self->{OUT_MODE}, $self->{OUT} or $self->error($self->cleanup . "$self->{OUT} : $!");
        print OUT $_ while <IN>;
        close OUT;
        seek  IN, 0, 0;

      } else {
        my %headers = ('-type'       => $template->get_mime_type,
                       '-connection' => 'close',
                       '-charset'    => 'UTF-8');

        $self->{attachment_filename} ||= $self->generate_attachment_filename;

        if ($self->{attachment_filename}) {
          %headers = (
            %headers,
            '-attachment'     => $self->{attachment_filename},
            '-content-length' => $numbytes,
            '-charset'        => '',
          );
        }

        print $::request->cgi->header(%headers);

        $::locale->with_raw_io(\*STDOUT, sub { print while <IN> });
      }
    }

    close(IN);
  }

  $self->cleanup;

  chdir("$self->{cwd}");
  $main::lxdebug->leave_sub();
}

sub get_formname_translation {
  $main::lxdebug->enter_sub();
  my ($self, $formname) = @_;

  $formname ||= $self->{formname};

  $self->{recipient_locale} ||=  Locale->lang_to_locale($self->{language});
  local $::locale = Locale->new($self->{recipient_locale});

  my %formname_translations = (
    bin_list                => $main::locale->text('Bin List'),
    credit_note             => $main::locale->text('Credit Note'),
    invoice                 => $main::locale->text('Invoice'),
    pick_list               => $main::locale->text('Pick List'),
    proforma                => $main::locale->text('Proforma Invoice'),
    purchase_order          => $main::locale->text('Purchase Order'),
    request_quotation       => $main::locale->text('RFQ'),
    sales_order             => $main::locale->text('Confirmation'),
    sales_quotation         => $main::locale->text('Quotation'),
    storno_invoice          => $main::locale->text('Storno Invoice'),
    sales_delivery_order    => $main::locale->text('Delivery Order'),
    purchase_delivery_order => $main::locale->text('Delivery Order'),
    dunning                 => $main::locale->text('Dunning'),
    letter                  => $main::locale->text('Letter'),
    ic_supply               => $main::locale->text('Intra-Community supply'),
  );

  $main::lxdebug->leave_sub();
  return $formname_translations{$formname};
}

sub get_number_prefix_for_type {
  $main::lxdebug->enter_sub();
  my ($self) = @_;

  my $prefix =
      (first { $self->{type} eq $_ } qw(invoice credit_note)) ? 'inv'
    : ($self->{type} =~ /_quotation$/)                        ? 'quo'
    : ($self->{type} =~ /_delivery_order$/)                   ? 'do'
    : ($self->{type} =~ /letter/)                             ? 'letter'
    :                                                           'ord';

  # better default like this?
  # : ($self->{type} =~ /(sales|purcharse)_order/           :  'ord';
  # :                                                           'prefix_undefined';

  $main::lxdebug->leave_sub();
  return $prefix;
}

sub get_extension_for_format {
  $main::lxdebug->enter_sub();
  my ($self)    = @_;

  my $extension = $self->{format} =~ /pdf/i          ? ".pdf"
                : $self->{format} =~ /postscript/i   ? ".ps"
                : $self->{format} =~ /opendocument/i ? ".odt"
                : $self->{format} =~ /excel/i        ? ".xls"
                : $self->{format} =~ /html/i         ? ".html"
                :                                      "";

  $main::lxdebug->leave_sub();
  return $extension;
}

sub generate_attachment_filename {
  $main::lxdebug->enter_sub();
  my ($self) = @_;

  $self->{recipient_locale} ||=  Locale->lang_to_locale($self->{language});
  my $recipient_locale = Locale->new($self->{recipient_locale});

  my $attachment_filename = $main::locale->unquote_special_chars('HTML', $self->get_formname_translation());
  my $prefix              = $self->get_number_prefix_for_type();

  if ($self->{preview} && (first { $self->{type} eq $_ } qw(invoice credit_note))) {
    $attachment_filename .= ' (' . $recipient_locale->text('Preview') . ')' . $self->get_extension_for_format();

  } elsif ($attachment_filename && $self->{"${prefix}number"}) {
    $attachment_filename .=  "_" . $self->{"${prefix}number"} . $self->get_extension_for_format();

  } elsif ($attachment_filename) {
    $attachment_filename .=  $self->get_extension_for_format();

  } else {
    $attachment_filename = "";
  }

  $attachment_filename =  $main::locale->quote_special_chars('filenames', $attachment_filename);
  $attachment_filename =~ s|[\s/\\]+|_|g;

  $main::lxdebug->leave_sub();
  return $attachment_filename;
}

sub generate_email_subject {
  $main::lxdebug->enter_sub();
  my ($self) = @_;

  my $subject = $main::locale->unquote_special_chars('HTML', $self->get_formname_translation());
  my $prefix  = $self->get_number_prefix_for_type();

  if ($subject && $self->{"${prefix}number"}) {
    $subject .= " " . $self->{"${prefix}number"}
  }

  $main::lxdebug->leave_sub();
  return $subject;
}

sub cleanup {
  $main::lxdebug->enter_sub();

  my ($self, $application) = @_;

  my $error_code = $?;

  chdir("$self->{tmpdir}");

  my @err = ();
  if ((-1 == $error_code) || (127 == (($error_code) >> 8))) {
    push @err, $::locale->text('The application "#1" was not found on the system.', $application || 'pdflatex') . ' ' . $::locale->text('Please contact your administrator.');

  } elsif (-f "$self->{tmpfile}.err") {
    open(FH, "<:encoding(UTF-8)", "$self->{tmpfile}.err");
    @err = <FH>;
    close(FH);
  }

  if ($self->{tmpfile} && !($::lx_office_conf{debug} && $::lx_office_conf{debug}->{keep_temp_files})) {
    $self->{tmpfile} =~ s|.*/||g;
    # strip extension
    $self->{tmpfile} =~ s/\.\w+$//g;
    my $tmpfile = $self->{tmpfile};
    unlink(<$tmpfile.*>);
  }

  chdir("$self->{cwd}");

  $main::lxdebug->leave_sub();

  return "@err";
}

sub datetonum {
  $main::lxdebug->enter_sub();

  my ($self, $date, $myconfig) = @_;
  my ($yy, $mm, $dd);

  if ($date && $date =~ /\D/) {

    if ($myconfig->{dateformat} =~ /^yy/) {
      ($yy, $mm, $dd) = split /\D/, $date;
    }
    if ($myconfig->{dateformat} =~ /^mm/) {
      ($mm, $dd, $yy) = split /\D/, $date;
    }
    if ($myconfig->{dateformat} =~ /^dd/) {
      ($dd, $mm, $yy) = split /\D/, $date;
    }

    $dd *= 1;
    $mm *= 1;
    $yy = ($yy < 70) ? $yy + 2000 : $yy;
    $yy = ($yy >= 70 && $yy <= 99) ? $yy + 1900 : $yy;

    $dd = "0$dd" if ($dd < 10);
    $mm = "0$mm" if ($mm < 10);

    $date = "$yy$mm$dd";
  }

  $main::lxdebug->leave_sub();

  return $date;
}

# Database routines used throughout

sub dbconnect {
  $main::lxdebug->enter_sub(2);

  my ($self, $myconfig) = @_;

  # connect to database
  my $dbh = SL::DBConnect->connect or $self->dberror;

  # set db options
  if ($myconfig->{dboptions}) {
    $dbh->do($myconfig->{dboptions}) || $self->dberror($myconfig->{dboptions});
  }

  $main::lxdebug->leave_sub(2);

  return $dbh;
}

sub dbconnect_noauto {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig) = @_;

  # connect to database
  my $dbh = SL::DBConnect->connect(SL::DBConnect->get_connect_args(AutoCommit => 0)) or $self->dberror;

  # set db options
  if ($myconfig->{dboptions}) {
    $dbh->do($myconfig->{dboptions}) || $self->dberror($myconfig->{dboptions});
  }

  $main::lxdebug->leave_sub();

  return $dbh;
}

sub get_standard_dbh {
  $main::lxdebug->enter_sub(2);

  my $self     = shift;
  my $myconfig = shift || \%::myconfig;

  if ($standard_dbh && !$standard_dbh->{Active}) {
    $main::lxdebug->message(LXDebug->INFO(), "get_standard_dbh: \$standard_dbh is defined but not Active anymore");
    undef $standard_dbh;
  }

  $standard_dbh ||= $self->dbconnect_noauto($myconfig);

  $main::lxdebug->leave_sub(2);

  return $standard_dbh;
}

sub set_standard_dbh {
  my ($self, $dbh) = @_;
  my $old_dbh      = $standard_dbh;
  $standard_dbh    = $dbh;

  return $old_dbh;
}

sub date_closed {
  $main::lxdebug->enter_sub();

  my ($self, $date, $myconfig) = @_;
  my $dbh = $self->get_standard_dbh;

  my $query = "SELECT 1 FROM defaults WHERE ? < closedto";
  my $sth = prepare_execute_query($self, $dbh, $query, conv_date($date));

  # Falls $date = '' - Fehlermeldung aus der Datenbank. Ich denke,
  # es ist sicher ein conv_date vorher IMMER auszuführen.
  # Testfälle ohne definiertes closedto:
  #   Leere Datumseingabe i.O.
  #     SELECT 1 FROM defaults WHERE '' < closedto
  #   normale Zahlungsbuchung über Rechnungsmaske i.O.
  #     SELECT 1 FROM defaults WHERE '10.05.2011' < closedto
  # Testfälle mit definiertem closedto (30.04.2011):
  #  Leere Datumseingabe i.O.
  #   SELECT 1 FROM defaults WHERE '' < closedto
  # normale Buchung im geschloßenem Zeitraum i.O.
  #   SELECT 1 FROM defaults WHERE '21.04.2011' < closedto
  #     Fehlermeldung: Es können keine Zahlungen für abgeschlossene Bücher gebucht werden!
  # normale Buchung in aktiver Buchungsperiode i.O.
  #   SELECT 1 FROM defaults WHERE '01.05.2011' < closedto

  my ($closed) = $sth->fetchrow_array;

  $main::lxdebug->leave_sub();

  return $closed;
}

# prevents bookings to the to far away future
sub date_max_future {
  $main::lxdebug->enter_sub();

  my ($self, $date, $myconfig) = @_;
  my $dbh = $self->get_standard_dbh;

  my $query = "SELECT 1 FROM defaults WHERE ? - current_date > max_future_booking_interval";
  my $sth = prepare_execute_query($self, $dbh, $query, conv_date($date));

  my ($max_future_booking_interval) = $sth->fetchrow_array;

  $main::lxdebug->leave_sub();

  return $max_future_booking_interval;
}


sub update_balance {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $table, $field, $where, $value, @values) = @_;

  # if we have a value, go do it
  if ($value != 0) {

    # retrieve balance from table
    my $query = "SELECT $field FROM $table WHERE $where FOR UPDATE";
    my $sth = prepare_execute_query($self, $dbh, $query, @values);
    my ($balance) = $sth->fetchrow_array;
    $sth->finish;

    $balance += $value;

    # update balance
    $query = "UPDATE $table SET $field = $balance WHERE $where";
    do_query($self, $dbh, $query, @values);
  }
  $main::lxdebug->leave_sub();
}

sub update_exchangerate {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $curr, $transdate, $buy, $sell) = @_;
  my ($query);
  # some sanity check for currency
  if ($curr eq '') {
    $main::lxdebug->leave_sub();
    return;
  }
  $query = qq|SELECT name AS curr FROM currencies WHERE id=(SELECT currency_id FROM defaults)|;

  my ($defaultcurrency) = selectrow_query($self, $dbh, $query);

  if ($curr eq $defaultcurrency) {
    $main::lxdebug->leave_sub();
    return;
  }

  $query = qq|SELECT e.currency_id FROM exchangerate e
                 WHERE e.currency_id = (SELECT cu.id FROM currencies cu WHERE cu.name=?) AND e.transdate = ?
                 FOR UPDATE|;
  my $sth = prepare_execute_query($self, $dbh, $query, $curr, $transdate);

  if ($buy == 0) {
    $buy = "";
  }
  if ($sell == 0) {
    $sell = "";
  }

  $buy = conv_i($buy, "NULL");
  $sell = conv_i($sell, "NULL");

  my $set;
  if ($buy != 0 && $sell != 0) {
    $set = "buy = $buy, sell = $sell";
  } elsif ($buy != 0) {
    $set = "buy = $buy";
  } elsif ($sell != 0) {
    $set = "sell = $sell";
  }

  if ($sth->fetchrow_array) {
    $query = qq|UPDATE exchangerate
                SET $set
                WHERE currency_id = (SELECT id FROM currencies WHERE name = ?)
                AND transdate = ?|;

  } else {
    $query = qq|INSERT INTO exchangerate (currency_id, buy, sell, transdate)
                VALUES ((SELECT id FROM currencies WHERE name = ?), $buy, $sell, ?)|;
  }
  $sth->finish;
  do_query($self, $dbh, $query, $curr, $transdate);

  $main::lxdebug->leave_sub();
}

sub save_exchangerate {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig, $currency, $transdate, $rate, $fld) = @_;

  my $dbh = $self->dbconnect($myconfig);

  my ($buy, $sell);

  $buy  = $rate if $fld eq 'buy';
  $sell = $rate if $fld eq 'sell';


  $self->update_exchangerate($dbh, $currency, $transdate, $buy, $sell);


  $dbh->disconnect;

  $main::lxdebug->leave_sub();
}

sub get_exchangerate {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $curr, $transdate, $fld) = @_;
  my ($query);

  unless ($transdate && $curr) {
    $main::lxdebug->leave_sub();
    return 1;
  }

  $query = qq|SELECT name AS curr FROM currencies WHERE id = (SELECT currency_id FROM defaults)|;

  my ($defaultcurrency) = selectrow_query($self, $dbh, $query);

  if ($curr eq $defaultcurrency) {
    $main::lxdebug->leave_sub();
    return 1;
  }

  $query = qq|SELECT e.$fld FROM exchangerate e
                 WHERE e.currency_id = (SELECT id FROM currencies WHERE name = ?) AND e.transdate = ?|;
  my ($exchangerate) = selectrow_query($self, $dbh, $query, $curr, $transdate);



  $main::lxdebug->leave_sub();

  return $exchangerate;
}

sub check_exchangerate {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig, $currency, $transdate, $fld) = @_;

  if ($fld !~/^buy|sell$/) {
    $self->error('Fatal: check_exchangerate called with invalid buy/sell argument');
  }

  unless ($transdate) {
    $main::lxdebug->leave_sub();
    return "";
  }

  my ($defaultcurrency) = $self->get_default_currency($myconfig);

  if ($currency eq $defaultcurrency) {
    $main::lxdebug->leave_sub();
    return 1;
  }

  my $dbh   = $self->get_standard_dbh($myconfig);
  my $query = qq|SELECT e.$fld FROM exchangerate e
                 WHERE e.currency_id = (SELECT id FROM currencies WHERE name = ?) AND e.transdate = ?|;

  my ($exchangerate) = selectrow_query($self, $dbh, $query, $currency, $transdate);

  $main::lxdebug->leave_sub();

  return $exchangerate;
}

sub get_all_currencies {
  $main::lxdebug->enter_sub();

  my $self     = shift;
  my $myconfig = shift || \%::myconfig;
  my $dbh      = $self->get_standard_dbh($myconfig);

  my $query = qq|SELECT name FROM currencies|;
  my @currencies = map { $_->{name} } selectall_hashref_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();

  return @currencies;
}

sub get_default_currency {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig) = @_;
  my $dbh      = $self->get_standard_dbh($myconfig);
  my $query = qq|SELECT name AS curr FROM currencies WHERE id = (SELECT currency_id FROM defaults)|;

  my ($defaultcurrency) = selectrow_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();

  return $defaultcurrency;
}

sub set_payment_options {
  my ($self, $myconfig, $transdate) = @_;

  my $terms = $self->{payment_id} ? SL::DB::PaymentTerm->new(id => $self->{payment_id})->load : undef;
  return if !$terms;

  $transdate                  ||= $self->{invdate} || $self->{transdate};
  my $due_date                  = $self->{duedate} || $self->{reqdate};

  $self->{$_}                   = $terms->$_ for qw(terms_netto terms_skonto percent_skonto);
  $self->{payment_terms}        = $terms->description_long;
  $self->{payment_description}  = $terms->description;
  $self->{netto_date}           = $terms->calc_date(reference_date => $transdate, due_date => $due_date, terms => 'net')->to_kivitendo;
  $self->{skonto_date}          = $terms->calc_date(reference_date => $transdate, due_date => $due_date, terms => 'discount')->to_kivitendo;

  my ($invtotal, $total);
  my (%amounts, %formatted_amounts);

  if ($self->{type} =~ /_order$/) {
    $amounts{invtotal} = $self->{ordtotal};
    $amounts{total}    = $self->{ordtotal};

  } elsif ($self->{type} =~ /_quotation$/) {
    $amounts{invtotal} = $self->{quototal};
    $amounts{total}    = $self->{quototal};

  } else {
    $amounts{invtotal} = $self->{invtotal};
    $amounts{total}    = $self->{total};
  }
  map { $amounts{$_} = $self->parse_amount($myconfig, $amounts{$_}) } keys %amounts;

  $amounts{skonto_in_percent}  = 100.0 * $self->{percent_skonto};
  $amounts{skonto_amount}      = $amounts{invtotal} * $self->{percent_skonto};
  $amounts{invtotal_wo_skonto} = $amounts{invtotal} * (1 - $self->{percent_skonto});
  $amounts{total_wo_skonto}    = $amounts{total}    * (1 - $self->{percent_skonto});

  foreach (keys %amounts) {
    $amounts{$_}           = $self->round_amount($amounts{$_}, 2);
    $formatted_amounts{$_} = $self->format_amount($myconfig, $amounts{$_}, 2);
  }

  if ($self->{"language_id"}) {
    my $dbh   = $self->get_standard_dbh($myconfig);
    my $query =
      qq|SELECT t.translation, l.output_numberformat, l.output_dateformat, l.output_longdates | .
      qq|FROM generic_translations t | .
      qq|LEFT JOIN language l ON t.language_id = l.id | .
      qq|WHERE (t.language_id = ?)
           AND (t.translation_id = ?)
           AND (t.translation_type = 'SL::DB::PaymentTerm/description_long')|;
    my ($description_long, $output_numberformat, $output_dateformat,
      $output_longdates) =
      selectrow_query($self, $dbh, $query,
                      $self->{"language_id"}, $self->{"payment_id"});

    $self->{payment_terms} = $description_long if ($description_long);

    if ($output_dateformat) {
      foreach my $key (qw(netto_date skonto_date)) {
        $self->{$key} =
          $main::locale->reformat_date($myconfig, $self->{$key},
                                       $output_dateformat,
                                       $output_longdates);
      }
    }

    if ($output_numberformat &&
        ($output_numberformat ne $myconfig->{"numberformat"})) {
      my $saved_numberformat = $myconfig->{"numberformat"};
      $myconfig->{"numberformat"} = $output_numberformat;
      map { $formatted_amounts{$_} = $self->format_amount($myconfig, $amounts{$_}) } keys %amounts;
      $myconfig->{"numberformat"} = $saved_numberformat;
    }
  }

  $self->{payment_terms} =~ s/<%netto_date%>/$self->{netto_date}/g;
  $self->{payment_terms} =~ s/<%skonto_date%>/$self->{skonto_date}/g;
  $self->{payment_terms} =~ s/<%currency%>/$self->{currency}/g;
  $self->{payment_terms} =~ s/<%terms_netto%>/$self->{terms_netto}/g;
  $self->{payment_terms} =~ s/<%account_number%>/$self->{account_number}/g;
  $self->{payment_terms} =~ s/<%bank%>/$self->{bank}/g;
  $self->{payment_terms} =~ s/<%bank_code%>/$self->{bank_code}/g;
  $self->{payment_terms} =~ s/<\%bic\%>/$self->{bic}/g;
  $self->{payment_terms} =~ s/<\%iban\%>/$self->{iban}/g;
  $self->{payment_terms} =~ s/<\%mandate_date_of_signature\%>/$self->{mandate_date_of_signature}/g;
  $self->{payment_terms} =~ s/<\%mandator_id\%>/$self->{mandator_id}/g;

  map { $self->{payment_terms} =~ s/<%${_}%>/$formatted_amounts{$_}/g; } keys %formatted_amounts;

  $self->{skonto_in_percent} = $formatted_amounts{skonto_in_percent};

}

sub get_template_language {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig) = @_;

  my $template_code = "";

  if ($self->{language_id}) {
    my $dbh = $self->get_standard_dbh($myconfig);
    my $query = qq|SELECT template_code FROM language WHERE id = ?|;
    ($template_code) = selectrow_query($self, $dbh, $query, $self->{language_id});
  }

  $main::lxdebug->leave_sub();

  return $template_code;
}

sub get_printer_code {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig) = @_;

  my $template_code = "";

  if ($self->{printer_id}) {
    my $dbh = $self->get_standard_dbh($myconfig);
    my $query = qq|SELECT template_code, printer_command FROM printers WHERE id = ?|;
    ($template_code, $self->{printer_command}) = selectrow_query($self, $dbh, $query, $self->{printer_id});
  }

  $main::lxdebug->leave_sub();

  return $template_code;
}

sub get_shipto {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig) = @_;

  my $template_code = "";

  if ($self->{shipto_id}) {
    my $dbh = $self->get_standard_dbh($myconfig);
    my $query = qq|SELECT * FROM shipto WHERE shipto_id = ?|;
    my $ref = selectfirst_hashref_query($self, $dbh, $query, $self->{shipto_id});
    map({ $self->{$_} = $ref->{$_} } keys(%$ref));

    my $cvars = CVar->get_custom_variables(
      dbh      => $dbh,
      module   => 'ShipTo',
      trans_id => $self->{shipto_id},
    );
    $self->{"shiptocvar_$_->{name}"} = $_->{value} for @{ $cvars };
  }

  $main::lxdebug->leave_sub();
}

sub add_shipto {
  my ($self, $dbh, $id, $module) = @_;

  my $shipto;
  my @values;

  foreach my $item (qw(name department_1 department_2 street zipcode city country gln
                       contact cp_gender phone fax email)) {
    if ($self->{"shipto$item"}) {
      $shipto = 1 if ($self->{$item} ne $self->{"shipto$item"});
    }
    push(@values, $self->{"shipto${item}"});
  }

  return if !$shipto;

  my $shipto_id = $self->{shipto_id};

  if ($self->{shipto_id}) {
    my $query = qq|UPDATE shipto set
                     shiptoname = ?,
                     shiptodepartment_1 = ?,
                     shiptodepartment_2 = ?,
                     shiptostreet = ?,
                     shiptozipcode = ?,
                     shiptocity = ?,
                     shiptocountry = ?,
                     shiptogln = ?,
                     shiptocontact = ?,
                     shiptocp_gender = ?,
                     shiptophone = ?,
                     shiptofax = ?,
                     shiptoemail = ?
                   WHERE shipto_id = ?|;
    do_query($self, $dbh, $query, @values, $self->{shipto_id});
  } else {
    my $query = qq|SELECT * FROM shipto
                   WHERE shiptoname = ? AND
                     shiptodepartment_1 = ? AND
                     shiptodepartment_2 = ? AND
                     shiptostreet = ? AND
                     shiptozipcode = ? AND
                     shiptocity = ? AND
                     shiptocountry = ? AND
                     shiptogln = ? AND
                     shiptocontact = ? AND
                     shiptocp_gender = ? AND
                     shiptophone = ? AND
                     shiptofax = ? AND
                     shiptoemail = ? AND
                     module = ? AND
                     trans_id = ?|;
    my $insert_check = selectfirst_hashref_query($self, $dbh, $query, @values, $module, $id);
    if(!$insert_check){
      my $insert_query =
        qq|INSERT INTO shipto (trans_id, shiptoname, shiptodepartment_1, shiptodepartment_2,
                               shiptostreet, shiptozipcode, shiptocity, shiptocountry, shiptogln,
                               shiptocontact, shiptocp_gender, shiptophone, shiptofax, shiptoemail, module)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)|;
      do_query($self, $dbh, $insert_query, $id, @values, $module);

      $insert_check = selectfirst_hashref_query($self, $dbh, $query, @values, $module, $id);
    }

    $shipto_id = $insert_check->{shipto_id};
  }

  return unless $shipto_id;

  CVar->save_custom_variables(
    dbh         => $dbh,
    module      => 'ShipTo',
    trans_id    => $shipto_id,
    variables   => $self,
    name_prefix => 'shipto',
  );
}

sub get_employee {
  $main::lxdebug->enter_sub();

  my ($self, $dbh) = @_;

  $dbh ||= $self->get_standard_dbh(\%main::myconfig);

  my $query = qq|SELECT id, name FROM employee WHERE login = ?|;
  ($self->{"employee_id"}, $self->{"employee"}) = selectrow_query($self, $dbh, $query, $self->{login});
  $self->{"employee_id"} *= 1;

  $main::lxdebug->leave_sub();
}

sub get_employee_data {
  $main::lxdebug->enter_sub();

  my $self     = shift;
  my %params   = @_;
  my $defaults = SL::DB::Default->get;

  Common::check_params(\%params, qw(prefix));
  Common::check_params_x(\%params, qw(id));

  if (!$params{id}) {
    $main::lxdebug->leave_sub();
    return;
  }

  my $myconfig = \%main::myconfig;
  my $dbh      = $params{dbh} || $self->get_standard_dbh($myconfig);

  my ($login, $deleted)  = selectrow_query($self, $dbh, qq|SELECT login,deleted FROM employee WHERE id = ?|, conv_i($params{id}));

  if ($login) {
    # login already fetched and still the same client (mandant) | same for both cases (delete|!delete)
    $self->{$params{prefix} . '_login'}   = $login;
    $self->{$params{prefix} . "_${_}"}    = $defaults->$_ for qw(address businessnumber co_ustid company duns taxnumber);

    if (!$deleted) {
      # get employee data from auth.user_config
      my $user = User->new(login => $login);
      $self->{$params{prefix} . "_${_}"} = $user->{$_} for qw(email fax name signature tel);
    } else {
      # get saved employee data from employee
      my $employee = SL::DB::Manager::Employee->find_by(id => conv_i($params{id}));
      $self->{$params{prefix} . "_${_}"} = $employee->{"deleted_$_"} for qw(email fax signature tel);
      $self->{$params{prefix} . "_name"} = $employee->name;
    }
 }
  $main::lxdebug->leave_sub();
}

sub _get_contacts {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $id, $key) = @_;

  $key = "all_contacts" unless ($key);

  if (!$id) {
    $self->{$key} = [];
    $main::lxdebug->leave_sub();
    return;
  }

  my $query =
    qq|SELECT cp_id, cp_cv_id, cp_name, cp_givenname, cp_abteilung | .
    qq|FROM contacts | .
    qq|WHERE cp_cv_id = ? | .
    qq|ORDER BY lower(cp_name)|;

  $self->{$key} = selectall_hashref_query($self, $dbh, $query, $id);

  $main::lxdebug->leave_sub();
}

sub _get_projects {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $key) = @_;

  my ($all, $old_id, $where, @values);

  if (ref($key) eq "HASH") {
    my $params = $key;

    $key = "ALL_PROJECTS";

    foreach my $p (keys(%{$params})) {
      if ($p eq "all") {
        $all = $params->{$p};
      } elsif ($p eq "old_id") {
        $old_id = $params->{$p};
      } elsif ($p eq "key") {
        $key = $params->{$p};
      }
    }
  }

  if (!$all) {
    $where = "WHERE active ";
    if ($old_id) {
      if (ref($old_id) eq "ARRAY") {
        my @ids = grep({ $_ } @{$old_id});
        if (@ids) {
          $where .= " OR id IN (" . join(",", map({ "?" } @ids)) . ") ";
          push(@values, @ids);
        }
      } else {
        $where .= " OR (id = ?) ";
        push(@values, $old_id);
      }
    }
  }

  my $query =
    qq|SELECT id, projectnumber, description, active | .
    qq|FROM project | .
    $where .
    qq|ORDER BY lower(projectnumber)|;

  $self->{$key} = selectall_hashref_query($self, $dbh, $query, @values);

  $main::lxdebug->leave_sub();
}

sub _get_shipto {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $vc_id, $key) = @_;

  $key = "all_shipto" unless ($key);

  if ($vc_id) {
    # get shipping addresses
    my $query = qq|SELECT * FROM shipto WHERE trans_id = ?|;

    $self->{$key} = selectall_hashref_query($self, $dbh, $query, $vc_id);

  } else {
    $self->{$key} = [];
  }

  $main::lxdebug->leave_sub();
}

sub _get_printers {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $key) = @_;

  $key = "all_printers" unless ($key);

  my $query = qq|SELECT id, printer_description, printer_command, template_code FROM printers|;

  $self->{$key} = selectall_hashref_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();
}

sub _get_charts {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $params) = @_;
  my ($key);

  $key = $params->{key};
  $key = "all_charts" unless ($key);

  my $transdate = quote_db_date($params->{transdate});

  my $query =
    qq|SELECT c.id, c.accno, c.description, c.link, c.charttype, tk.taxkey_id, tk.tax_id | .
    qq|FROM chart c | .
    qq|LEFT JOIN taxkeys tk ON | .
    qq|(tk.id = (SELECT id FROM taxkeys | .
    qq|          WHERE taxkeys.chart_id = c.id AND startdate <= $transdate | .
    qq|          ORDER BY startdate DESC LIMIT 1)) | .
    qq|ORDER BY c.accno|;

  $self->{$key} = selectall_hashref_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();
}

sub _get_taxcharts {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $params) = @_;

  my $key = "all_taxcharts";
  my @where;

  if (ref $params eq 'HASH') {
    $key = $params->{key} if ($params->{key});
    if ($params->{module} eq 'AR') {
      push @where, 'chart_categories ~ \'[ACILQ]\'';

    } elsif ($params->{module} eq 'AP') {
      push @where, 'chart_categories ~ \'[ACELQ]\'';
    }

  } elsif ($params) {
    $key = $params;
  }

  my $where = @where ? ' WHERE ' . join(' AND ', map { "($_)" } @where) : '';

  my $query = qq|SELECT * FROM tax $where ORDER BY taxkey, rate|;

  $self->{$key} = selectall_hashref_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();
}

sub _get_taxzones {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $key) = @_;

  $key = "all_taxzones" unless ($key);
  my $tzfilter = "";
  $tzfilter = "WHERE obsolete is FALSE" if $key eq 'ALL_ACTIVE_TAXZONES';

  my $query = qq|SELECT * FROM tax_zones $tzfilter ORDER BY sortkey|;

  $self->{$key} = selectall_hashref_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();
}

sub _get_employees {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $params) = @_;

  my $deleted = 0;

  my $key;
  if (ref $params eq 'HASH') {
    $key     = $params->{key};
    $deleted = $params->{deleted};

  } else {
    $key = $params;
  }

  $key     ||= "all_employees";
  my $filter = $deleted ? '' : 'WHERE NOT COALESCE(deleted, FALSE)';
  $self->{$key} = selectall_hashref_query($self, $dbh, qq|SELECT * FROM employee $filter ORDER BY lower(name)|);

  $main::lxdebug->leave_sub();
}

sub _get_business_types {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $key) = @_;

  my $options       = ref $key eq 'HASH' ? $key : { key => $key };
  $options->{key} ||= "all_business_types";
  my $where         = '';

  if (exists $options->{salesman}) {
    $where = 'WHERE ' . ($options->{salesman} ? '' : 'NOT ') . 'COALESCE(salesman)';
  }

  $self->{ $options->{key} } = selectall_hashref_query($self, $dbh, qq|SELECT * FROM business $where ORDER BY lower(description)|);

  $main::lxdebug->leave_sub();
}

sub _get_languages {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $key) = @_;

  $key = "all_languages" unless ($key);

  my $query = qq|SELECT * FROM language ORDER BY id|;

  $self->{$key} = selectall_hashref_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();
}

sub _get_dunning_configs {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $key) = @_;

  $key = "all_dunning_configs" unless ($key);

  my $query = qq|SELECT * FROM dunning_config ORDER BY dunning_level|;

  $self->{$key} = selectall_hashref_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();
}

sub _get_currencies {
$main::lxdebug->enter_sub();

  my ($self, $dbh, $key) = @_;

  $key = "all_currencies" unless ($key);

  $self->{$key} = [$self->get_all_currencies()];

  $main::lxdebug->leave_sub();
}

sub _get_payments {
$main::lxdebug->enter_sub();

  my ($self, $dbh, $key) = @_;

  $key = "all_payments" unless ($key);

  my $query = qq|SELECT * FROM payment_terms ORDER BY sortkey|;

  $self->{$key} = selectall_hashref_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();
}

sub _get_customers {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $key) = @_;

  my $options        = ref $key eq 'HASH' ? $key : { key => $key };
  $options->{key}  ||= "all_customers";
  my $limit_clause   = $options->{limit} ? "LIMIT $options->{limit}" : '';

  my @where;
  push @where, qq|business_id IN (SELECT id FROM business WHERE salesman)| if  $options->{business_is_salesman};
  push @where, qq|NOT obsolete|                                            if !$options->{with_obsolete};
  my $where_str = @where ? "WHERE " . join(" AND ", map { "($_)" } @where) : '';

  my $query = qq|SELECT * FROM customer $where_str ORDER BY name $limit_clause|;
  $self->{ $options->{key} } = selectall_hashref_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();
}

sub _get_vendors {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $key) = @_;

  $key = "all_vendors" unless ($key);

  my $query = qq|SELECT * FROM vendor WHERE NOT obsolete ORDER BY name|;

  $self->{$key} = selectall_hashref_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();
}

sub _get_departments {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $key) = @_;

  $key = "all_departments" unless ($key);

  my $query = qq|SELECT * FROM department ORDER BY description|;

  $self->{$key} = selectall_hashref_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();
}

sub _get_warehouses {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $param) = @_;

  my ($key, $bins_key);

  if ('' eq ref $param) {
    $key = $param;

  } else {
    $key      = $param->{key};
    $bins_key = $param->{bins};
  }

  my $query = qq|SELECT w.* FROM warehouse w
                 WHERE (NOT w.invalid) AND
                   ((SELECT COUNT(b.*) FROM bin b WHERE b.warehouse_id = w.id) > 0)
                 ORDER BY w.sortkey|;

  $self->{$key} = selectall_hashref_query($self, $dbh, $query);

  if ($bins_key) {
    $query = qq|SELECT id, description FROM bin WHERE warehouse_id = ?
                ORDER BY description|;
    my $sth = prepare_query($self, $dbh, $query);

    foreach my $warehouse (@{ $self->{$key} }) {
      do_statement($self, $sth, $query, $warehouse->{id});
      $warehouse->{$bins_key} = [];

      while (my $ref = $sth->fetchrow_hashref()) {
        push @{ $warehouse->{$bins_key} }, $ref;
      }
    }
    $sth->finish();
  }

  $main::lxdebug->leave_sub();
}

sub _get_simple {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $table, $key, $sortkey) = @_;

  my $query  = qq|SELECT * FROM $table|;
  $query    .= qq| ORDER BY $sortkey| if ($sortkey);

  $self->{$key} = selectall_hashref_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();
}

#sub _get_groups {
#  $main::lxdebug->enter_sub();
#
#  my ($self, $dbh, $key) = @_;
#
#  $key ||= "all_groups";
#
#  my $groups = $main::auth->read_groups();
#
#  $self->{$key} = selectall_hashref_query($self, $dbh, $query);
#
#  $main::lxdebug->leave_sub();
#}

sub get_lists {
  $main::lxdebug->enter_sub();

  my $self = shift;
  my %params = @_;

  my $dbh = $self->get_standard_dbh(\%main::myconfig);
  my ($sth, $query, $ref);

  my ($vc, $vc_id);
  if ($params{contacts} || $params{shipto}) {
    $vc = 'customer' if $self->{"vc"} eq "customer";
    $vc = 'vendor'   if $self->{"vc"} eq "vendor";
    die "invalid use of get_lists, need 'vc'" unless $vc;
    $vc_id = $self->{"${vc}_id"};
  }

  if ($params{"contacts"}) {
    $self->_get_contacts($dbh, $vc_id, $params{"contacts"});
  }

  if ($params{"shipto"}) {
    $self->_get_shipto($dbh, $vc_id, $params{"shipto"});
  }

  if ($params{"projects"} || $params{"all_projects"}) {
    $self->_get_projects($dbh, $params{"all_projects"} ?
                         $params{"all_projects"} : $params{"projects"},
                         $params{"all_projects"} ? 1 : 0);
  }

  if ($params{"printers"}) {
    $self->_get_printers($dbh, $params{"printers"});
  }

  if ($params{"languages"}) {
    $self->_get_languages($dbh, $params{"languages"});
  }

  if ($params{"charts"}) {
    $self->_get_charts($dbh, $params{"charts"});
  }

  if ($params{"taxcharts"}) {
    $self->_get_taxcharts($dbh, $params{"taxcharts"});
  }

  if ($params{"taxzones"}) {
    $self->_get_taxzones($dbh, $params{"taxzones"});
  }

  if ($params{"employees"}) {
    $self->_get_employees($dbh, $params{"employees"});
  }

  if ($params{"salesmen"}) {
    $self->_get_employees($dbh, $params{"salesmen"});
  }

  if ($params{"business_types"}) {
    $self->_get_business_types($dbh, $params{"business_types"});
  }

  if ($params{"dunning_configs"}) {
    $self->_get_dunning_configs($dbh, $params{"dunning_configs"});
  }

  if($params{"currencies"}) {
    $self->_get_currencies($dbh, $params{"currencies"});
  }

  if($params{"customers"}) {
    $self->_get_customers($dbh, $params{"customers"});
  }

  if($params{"vendors"}) {
    if (ref $params{"vendors"} eq 'HASH') {
      $self->_get_vendors($dbh, $params{"vendors"}{key}, $params{"vendors"}{limit});
    } else {
      $self->_get_vendors($dbh, $params{"vendors"});
    }
  }

  if($params{"payments"}) {
    $self->_get_payments($dbh, $params{"payments"});
  }

  if($params{"departments"}) {
    $self->_get_departments($dbh, $params{"departments"});
  }

  if ($params{price_factors}) {
    $self->_get_simple($dbh, 'price_factors', $params{price_factors}, 'sortkey');
  }

  if ($params{warehouses}) {
    $self->_get_warehouses($dbh, $params{warehouses});
  }

#  if ($params{groups}) {
#    $self->_get_groups($dbh, $params{groups});
#  }

  if ($params{partsgroup}) {
    $self->get_partsgroup(\%main::myconfig, { all => 1, target => $params{partsgroup} });
  }

  $main::lxdebug->leave_sub();
}

# this sub gets the id and name from $table
sub get_name {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig, $table) = @_;

  # connect to database
  my $dbh = $self->get_standard_dbh($myconfig);

  $table = $table eq "customer" ? "customer" : "vendor";
  my $arap = $self->{arap} eq "ar" ? "ar" : "ap";

  my ($query, @values);

  if (!$self->{openinvoices}) {
    my $where;
    if ($self->{customernumber} ne "") {
      $where = qq|(vc.customernumber ILIKE ?)|;
      push(@values, like($self->{customernumber}));
    } else {
      $where = qq|(vc.name ILIKE ?)|;
      push(@values, like($self->{$table}));
    }

    $query =
      qq~SELECT vc.id, vc.name,
           vc.street || ' ' || vc.zipcode || ' ' || vc.city || ' ' || vc.country AS address
         FROM $table vc
         WHERE $where AND (NOT vc.obsolete)
         ORDER BY vc.name~;
  } else {
    $query =
      qq~SELECT DISTINCT vc.id, vc.name,
           vc.street || ' ' || vc.zipcode || ' ' || vc.city || ' ' || vc.country AS address
         FROM $arap a
         JOIN $table vc ON (a.${table}_id = vc.id)
         WHERE NOT (a.amount = a.paid) AND (vc.name ILIKE ?)
         ORDER BY vc.name~;
    push(@values, like($self->{$table}));
  }

  $self->{name_list} = selectall_hashref_query($self, $dbh, $query, @values);

  $main::lxdebug->leave_sub();

  return scalar(@{ $self->{name_list} });
}

# the selection sub is used in the AR, AP, IS, IR, DO and OE module
#
sub all_vc {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig, $table, $module) = @_;

  my $ref;
  my $dbh = $self->get_standard_dbh;

  $table = $table eq "customer" ? "customer" : "vendor";

  # build selection list
  # Hotfix für Bug 1837 - Besser wäre es alte Buchungsbelege
  # OHNE Auswahlliste (reines Textfeld) zu laden. Hilft aber auch
  # nicht für veränderbare Belege (oe, do, ...)
  my $obsolete = $self->{id} ? '' : "WHERE NOT obsolete";
  my $query = qq|SELECT count(*) FROM $table $obsolete|;
  my ($count) = selectrow_query($self, $dbh, $query);

  if ($count <= $myconfig->{vclimit}) {
    $query = qq|SELECT id, name, salesman_id
                FROM $table $obsolete
                ORDER BY name|;
    $self->{"all_$table"} = selectall_hashref_query($self, $dbh, $query);
  }

  # get self
  $self->get_employee($dbh);

  # setup sales contacts
  $query = qq|SELECT e.id, e.name
              FROM employee e
              WHERE (e.sales = '1') AND (NOT e.id = ?)
              ORDER BY name|;
  $self->{all_employees} = selectall_hashref_query($self, $dbh, $query, $self->{employee_id});

  # this is for self
  push(@{ $self->{all_employees} },
       { id   => $self->{employee_id},
         name => $self->{employee} });

    # prepare query for departments
    $query = qq|SELECT id, description
                FROM department
                ORDER BY description|;

  $self->{all_departments} = selectall_hashref_query($self, $dbh, $query);

  # get languages
  $query = qq|SELECT id, description
              FROM language
              ORDER BY id|;

  $self->{languages} = selectall_hashref_query($self, $dbh, $query);

  # get printer
  $query = qq|SELECT printer_description, id
              FROM printers
              ORDER BY printer_description|;

  $self->{printers} = selectall_hashref_query($self, $dbh, $query);

  # get payment terms
  $query = qq|SELECT id, description
              FROM payment_terms
              ORDER BY sortkey|;

  $self->{payment_terms} = selectall_hashref_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();
}

sub new_lastmtime {
  my ($self, $table, $option) = @_;

  return                                       unless $self->{id};
  croak ("wrong call, no valid table defined") unless $table =~ /^(oe|ar|ap|delivery_orders|parts)$/;

  my $query       = "SELECT mtime, itime FROM " . $table . " WHERE id = ?";
  my $ref         = selectfirst_hashref_query($self, $self->get_standard_dbh, $query, $self->{id});
  $ref->{mtime} ||= $ref->{itime};
  $self->{lastmtime} = $ref->{mtime};
  $main::lxdebug->message(LXDebug->DEBUG2(),"new lastmtime=".$self->{lastmtime});
}

sub mtime_ischanged {
  my ($self, $table, $option) = @_;

  return                                       unless $self->{id};
  croak ("wrong call, no valid table defined") unless $table =~ /^(oe|ar|ap|delivery_orders|parts)$/;

  my $query       = "SELECT mtime, itime FROM " . $table . " WHERE id = ?";
  my $ref         = selectfirst_hashref_query($self, $self->get_standard_dbh, $query, $self->{id});
  $ref->{mtime} ||= $ref->{itime};

  if ($self->{lastmtime} && $self->{lastmtime} ne $ref->{mtime} ) {
      $self->error(($option eq 'mail') ?
        t8("The document has been changed by another user. No mail was sent. Please reopen it in another window and copy the changes to the new window") :
        t8("The document has been changed by another user. Please reopen it in another window and copy the changes to the new window")
      );
    $::dispatcher->end_request;
  }
}

sub language_payment {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig) = @_;

  my $dbh = $self->get_standard_dbh($myconfig);
  # get languages
  my $query = qq|SELECT id, description
                 FROM language
                 ORDER BY id|;

  $self->{languages} = selectall_hashref_query($self, $dbh, $query);

  # get printer
  $query = qq|SELECT printer_description, id
              FROM printers
              ORDER BY printer_description|;

  $self->{printers} = selectall_hashref_query($self, $dbh, $query);

  # get payment terms
  $query = qq|SELECT id, description
              FROM payment_terms
              ORDER BY sortkey|;

  $self->{payment_terms} = selectall_hashref_query($self, $dbh, $query);

  # get buchungsgruppen
  $query = qq|SELECT id, description
              FROM buchungsgruppen|;

  $self->{BUCHUNGSGRUPPEN} = selectall_hashref_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();
}

# this is only used for reports
sub all_departments {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig, $table) = @_;

  my $dbh = $self->get_standard_dbh($myconfig);

  my $query = qq|SELECT id, description
                 FROM department
                 ORDER BY description|;
  $self->{all_departments} = selectall_hashref_query($self, $dbh, $query);

  delete($self->{all_departments}) unless (@{ $self->{all_departments} || [] });

  $main::lxdebug->leave_sub();
}

sub create_links {
  $main::lxdebug->enter_sub();

  my ($self, $module, $myconfig, $table, $provided_dbh) = @_;

  my ($fld, $arap);
  if ($table eq "customer") {
    $fld = "buy";
    $arap = "ar";
  } else {
    $table = "vendor";
    $fld = "sell";
    $arap = "ap";
  }

  $self->all_vc($myconfig, $table, $module);

  # get last customers or vendors
  my ($query, $sth, $ref);

  my $dbh = $provided_dbh ? $provided_dbh : $self->get_standard_dbh($myconfig);
  my %xkeyref = ();

  if (!$self->{id}) {

    my $transdate = "current_date";
    if ($self->{transdate}) {
      $transdate = $dbh->quote($self->{transdate});
    }

    # now get the account numbers
#    $query = qq|SELECT c.accno, c.description, c.link, c.taxkey_id, tk.tax_id
#                FROM chart c, taxkeys tk
#                WHERE (c.link LIKE ?) AND (c.id = tk.chart_id) AND tk.id =
#                  (SELECT id FROM taxkeys WHERE (taxkeys.chart_id = c.id) AND (startdate <= $transdate) ORDER BY startdate DESC LIMIT 1)
#                ORDER BY c.accno|;

#  same query as above, but without expensive subquery for each row. about 80% faster
    $query = qq|
      SELECT c.accno, c.description, c.link, c.taxkey_id, tk2.tax_id
        FROM chart c
        -- find newest entries in taxkeys
        INNER JOIN (
          SELECT chart_id, MAX(startdate) AS startdate
          FROM taxkeys
          WHERE (startdate <= $transdate)
          GROUP BY chart_id
        ) tk ON (c.id = tk.chart_id)
        -- and load all of those entries
        INNER JOIN taxkeys tk2
           ON (tk.chart_id = tk2.chart_id AND tk.startdate = tk2.startdate)
       WHERE (c.link LIKE ?)
      ORDER BY c.accno|;

    $sth = $dbh->prepare($query);

    do_statement($self, $sth, $query, like($module));

    $self->{accounts} = "";
    while ($ref = $sth->fetchrow_hashref("NAME_lc")) {

      foreach my $key (split(/:/, $ref->{link})) {
        if ($key =~ /\Q$module\E/) {

          # cross reference for keys
          $xkeyref{ $ref->{accno} } = $key;

          push @{ $self->{"${module}_links"}{$key} },
            { accno       => $ref->{accno},
              description => $ref->{description},
              taxkey      => $ref->{taxkey_id},
              tax_id      => $ref->{tax_id} };

          $self->{accounts} .= "$ref->{accno} " unless $key =~ /tax/;
        }
      }
    }
  }

  # get taxkeys and description
  $query = qq|SELECT id, taxkey, taxdescription FROM tax|;
  $self->{TAXKEY} = selectall_hashref_query($self, $dbh, $query);

  if (($module eq "AP") || ($module eq "AR")) {
    # get tax rates and description
    $query = qq|SELECT * FROM tax|;
    $self->{TAX} = selectall_hashref_query($self, $dbh, $query);
  }

  my $extra_columns = '';
  $extra_columns   .= 'a.direct_debit, ' if ($module eq 'AR') || ($module eq 'AP');

  if ($self->{id}) {
    $query =
      qq|SELECT
           a.cp_id, a.invnumber, a.transdate, a.${table}_id, a.datepaid,
           a.duedate, a.ordnumber, a.taxincluded, (SELECT cu.name FROM currencies cu WHERE cu.id=a.currency_id) AS currency, a.notes,
           a.mtime, a.itime,
           a.intnotes, a.department_id, a.amount AS oldinvtotal,
           a.paid AS oldtotalpaid, a.employee_id, a.gldate, a.type,
           a.globalproject_id, ${extra_columns}
           c.name AS $table,
           d.description AS department,
           e.name AS employee
         FROM $arap a
         JOIN $table c ON (a.${table}_id = c.id)
         LEFT JOIN employee e ON (e.id = a.employee_id)
         LEFT JOIN department d ON (d.id = a.department_id)
         WHERE a.id = ?|;
    $ref = selectfirst_hashref_query($self, $dbh, $query, $self->{id});

    foreach my $key (keys %$ref) {
      $self->{$key} = $ref->{$key};
    }
    $self->{mtime}   ||= $self->{itime};
    $self->{lastmtime} = $self->{mtime};
    my $transdate = "current_date";
    if ($self->{transdate}) {
      $transdate = $dbh->quote($self->{transdate});
    }

    # now get the account numbers
    $query = qq|SELECT c.accno, c.description, c.link, c.taxkey_id, tk.tax_id
                FROM chart c
                LEFT JOIN taxkeys tk ON (tk.chart_id = c.id)
                WHERE c.link LIKE ?
                  AND (tk.id = (SELECT id FROM taxkeys WHERE taxkeys.chart_id = c.id AND startdate <= $transdate ORDER BY startdate DESC LIMIT 1)
                    OR c.link LIKE '%_tax%' OR c.taxkey_id IS NULL)
                ORDER BY c.accno|;

    $sth = $dbh->prepare($query);
    do_statement($self, $sth, $query, like($module));

    $self->{accounts} = "";
    while ($ref = $sth->fetchrow_hashref("NAME_lc")) {

      foreach my $key (split(/:/, $ref->{link})) {
        if ($key =~ /\Q$module\E/) {

          # cross reference for keys
          $xkeyref{ $ref->{accno} } = $key;

          push @{ $self->{"${module}_links"}{$key} },
            { accno       => $ref->{accno},
              description => $ref->{description},
              taxkey      => $ref->{taxkey_id},
              tax_id      => $ref->{tax_id} };

          $self->{accounts} .= "$ref->{accno} " unless $key =~ /tax/;
        }
      }
    }


    # get amounts from individual entries
    $query =
      qq|SELECT
           c.accno, c.description,
           a.acc_trans_id, a.source, a.amount, a.memo, a.transdate, a.gldate, a.cleared, a.project_id, a.taxkey,
           p.projectnumber,
           t.rate, t.id
         FROM acc_trans a
         LEFT JOIN chart c ON (c.id = a.chart_id)
         LEFT JOIN project p ON (p.id = a.project_id)
         LEFT JOIN tax t ON (t.id= a.tax_id)
         WHERE a.trans_id = ?
         AND a.fx_transaction = '0'
         ORDER BY a.acc_trans_id, a.transdate|;
    $sth = $dbh->prepare($query);
    do_statement($self, $sth, $query, $self->{id});

    # get exchangerate for currency
    $self->{exchangerate} =
      $self->get_exchangerate($dbh, $self->{currency}, $self->{transdate}, $fld);
    my $index = 0;

    # store amounts in {acc_trans}{$key} for multiple accounts
    while (my $ref = $sth->fetchrow_hashref("NAME_lc")) {
      $ref->{exchangerate} =
        $self->get_exchangerate($dbh, $self->{currency}, $ref->{transdate}, $fld);
      if (!($xkeyref{ $ref->{accno} } =~ /tax/)) {
        $index++;
      }
      if (($xkeyref{ $ref->{accno} } =~ /paid/) && ($self->{type} eq "credit_note")) {
        $ref->{amount} *= -1;
      }
      $ref->{index} = $index;

      push @{ $self->{acc_trans}{ $xkeyref{ $ref->{accno} } } }, $ref;
    }

    $sth->finish;
    #check das:
    $query =
      qq|SELECT
           d.closedto, d.revtrans,
           (SELECT cu.name FROM currencies cu WHERE cu.id=d.currency_id) AS defaultcurrency,
           (SELECT c.accno FROM chart c WHERE d.fxgain_accno_id = c.id) AS fxgain_accno,
           (SELECT c.accno FROM chart c WHERE d.fxloss_accno_id = c.id) AS fxloss_accno,
           (SELECT c.accno FROM chart c WHERE d.rndgain_accno_id = c.id) AS rndgain_accno,
           (SELECT c.accno FROM chart c WHERE d.rndloss_accno_id = c.id) AS rndloss_accno
         FROM defaults d|;
    $ref = selectfirst_hashref_query($self, $dbh, $query);
    map { $self->{$_} = $ref->{$_} } keys %$ref;

  } else {

    # get date
    $query =
       qq|SELECT
            current_date AS transdate, d.closedto, d.revtrans,
            (SELECT cu.name FROM currencies cu WHERE cu.id=d.currency_id) AS defaultcurrency,
            (SELECT c.accno FROM chart c WHERE d.fxgain_accno_id = c.id) AS fxgain_accno,
            (SELECT c.accno FROM chart c WHERE d.fxloss_accno_id = c.id) AS fxloss_accno,
            (SELECT c.accno FROM chart c WHERE d.rndgain_accno_id = c.id) AS rndgain_accno,
            (SELECT c.accno FROM chart c WHERE d.rndloss_accno_id = c.id) AS rndloss_accno
          FROM defaults d|;
    $ref = selectfirst_hashref_query($self, $dbh, $query);
    map { $self->{$_} = $ref->{$_} } keys %$ref;

    if ($self->{"$self->{vc}_id"}) {

      # only setup currency
      ($self->{currency}) = $self->{defaultcurrency} if !$self->{currency};

    } else {

      $self->lastname_used($dbh, $myconfig, $table, $module);

      # get exchangerate for currency
      $self->{exchangerate} =
        $self->get_exchangerate($dbh, $self->{currency}, $self->{transdate}, $fld);

    }

  }

  $main::lxdebug->leave_sub();
}

sub lastname_used {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $myconfig, $table, $module) = @_;

  my ($arap, $where);

  $table         = $table eq "customer" ? "customer" : "vendor";
  my %column_map = ("a.${table}_id"           => "${table}_id",
                    "a.department_id"         => "department_id",
                    "d.description"           => "department",
                    "ct.name"                 => $table,
                    "cu.name"                 => "currency",
    );

  if ($self->{type} =~ /delivery_order/) {
    $arap  = 'delivery_orders';
    delete $column_map{"cu.currency"};

  } elsif ($self->{type} =~ /_order/) {
    $arap  = 'oe';
    $where = "quotation = '0'";

  } elsif ($self->{type} =~ /_quotation/) {
    $arap  = 'oe';
    $where = "quotation = '1'";

  } elsif ($table eq 'customer') {
    $arap  = 'ar';

  } else {
    $arap  = 'ap';

  }

  $where           = "($where) AND" if ($where);
  my $query        = qq|SELECT MAX(id) FROM $arap
                        WHERE $where ${table}_id > 0|;
  my ($trans_id)   = selectrow_query($self, $dbh, $query);
  $trans_id       *= 1;

  my $column_spec  = join(', ', map { "${_} AS $column_map{$_}" } keys %column_map);
  $query           = qq|SELECT $column_spec
                        FROM $arap a
                        LEFT JOIN $table     ct ON (a.${table}_id = ct.id)
                        LEFT JOIN department d  ON (a.department_id = d.id)
                        LEFT JOIN currencies cu ON (cu.id=ct.currency_id)
                        WHERE a.id = ?|;
  my $ref          = selectfirst_hashref_query($self, $dbh, $query, $trans_id);

  map { $self->{$_} = $ref->{$_} } values %column_map;

  $main::lxdebug->leave_sub();
}

sub current_date {
  $main::lxdebug->enter_sub();

  my $self     = shift;
  my $myconfig = shift || \%::myconfig;
  my ($thisdate, $days) = @_;

  my $dbh = $self->get_standard_dbh($myconfig);
  my $query;

  $days *= 1;
  if ($thisdate) {
    my $dateformat = $myconfig->{dateformat};
    $dateformat .= "yy" if $myconfig->{dateformat} !~ /^y/;
    $thisdate = $dbh->quote($thisdate);
    $query = qq|SELECT to_date($thisdate, '$dateformat') + $days AS thisdate|;
  } else {
    $query = qq|SELECT current_date AS thisdate|;
  }

  ($thisdate) = selectrow_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();

  return $thisdate;
}

sub redo_rows {
  $main::lxdebug->enter_sub();

  my ($self, $flds, $new, $count, $numrows) = @_;

  my @ndx = ();

  map { push @ndx, { num => $new->[$_ - 1]->{runningnumber}, ndx => $_ } } 1 .. $count;

  my $i = 0;

  # fill rows
  foreach my $item (sort { $a->{num} <=> $b->{num} } @ndx) {
    $i++;
    my $j = $item->{ndx} - 1;
    map { $self->{"${_}_$i"} = $new->[$j]->{$_} } @{$flds};
  }

  # delete empty rows
  for $i ($count + 1 .. $numrows) {
    map { delete $self->{"${_}_$i"} } @{$flds};
  }

  $main::lxdebug->leave_sub();
}

sub update_status {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig) = @_;

  my ($i, $id);

  my $dbh = $self->dbconnect_noauto($myconfig);

  my $query = qq|DELETE FROM status
                 WHERE (formname = ?) AND (trans_id = ?)|;
  my $sth = prepare_query($self, $dbh, $query);

  if ($self->{formname} =~ /(check|receipt)/) {
    for $i (1 .. $self->{rowcount}) {
      do_statement($self, $sth, $query, $self->{formname}, $self->{"id_$i"} * 1);
    }
  } else {
    do_statement($self, $sth, $query, $self->{formname}, $self->{id});
  }
  $sth->finish();

  my $printed = ($self->{printed} =~ /\Q$self->{formname}\E/) ? "1" : "0";
  my $emailed = ($self->{emailed} =~ /\Q$self->{formname}\E/) ? "1" : "0";

  my %queued = split / /, $self->{queued};
  my @values;

  if ($self->{formname} =~ /(check|receipt)/) {

    # this is a check or receipt, add one entry for each lineitem
    my ($accno) = split /--/, $self->{account};
    $query = qq|INSERT INTO status (trans_id, printed, spoolfile, formname, chart_id)
                VALUES (?, ?, ?, ?, (SELECT c.id FROM chart c WHERE c.accno = ?))|;
    @values = ($printed, $queued{$self->{formname}}, $self->{prinform}, $accno);
    $sth = prepare_query($self, $dbh, $query);

    for $i (1 .. $self->{rowcount}) {
      if ($self->{"checked_$i"}) {
        do_statement($self, $sth, $query, $self->{"id_$i"}, @values);
      }
    }
    $sth->finish();

  } else {
    $query = qq|INSERT INTO status (trans_id, printed, emailed, spoolfile, formname)
                VALUES (?, ?, ?, ?, ?)|;
    do_query($self, $dbh, $query, $self->{id}, $printed, $emailed,
             $queued{$self->{formname}}, $self->{formname});
  }

  $dbh->commit;
  $dbh->disconnect;

  $main::lxdebug->leave_sub();
}

sub save_status {
  $main::lxdebug->enter_sub();

  my ($self, $dbh) = @_;

  my ($query, $printed, $emailed);

  my $formnames  = $self->{printed};
  my $emailforms = $self->{emailed};

  $query = qq|DELETE FROM status
                 WHERE (formname = ?) AND (trans_id = ?)|;
  do_query($self, $dbh, $query, $self->{formname}, $self->{id});

  # this only applies to the forms
  # checks and receipts are posted when printed or queued

  if ($self->{queued}) {
    my %queued = split / /, $self->{queued};

    foreach my $formname (keys %queued) {
      $printed = ($self->{printed} =~ /\Q$self->{formname}\E/) ? "1" : "0";
      $emailed = ($self->{emailed} =~ /\Q$self->{formname}\E/) ? "1" : "0";

      $query = qq|INSERT INTO status (trans_id, printed, emailed, spoolfile, formname)
                  VALUES (?, ?, ?, ?, ?)|;
      do_query($self, $dbh, $query, $self->{id}, $printed, $emailed, $queued{$formname}, $formname);

      $formnames  =~ s/\Q$self->{formname}\E//;
      $emailforms =~ s/\Q$self->{formname}\E//;

    }
  }

  # save printed, emailed info
  $formnames  =~ s/^ +//g;
  $emailforms =~ s/^ +//g;

  my %status = ();
  map { $status{$_}{printed} = 1 } split / +/, $formnames;
  map { $status{$_}{emailed} = 1 } split / +/, $emailforms;

  foreach my $formname (keys %status) {
    $printed = ($formnames  =~ /\Q$self->{formname}\E/) ? "1" : "0";
    $emailed = ($emailforms =~ /\Q$self->{formname}\E/) ? "1" : "0";

    $query = qq|INSERT INTO status (trans_id, printed, emailed, formname)
                VALUES (?, ?, ?, ?)|;
    do_query($self, $dbh, $query, $self->{id}, $printed, $emailed, $formname);
  }

  $main::lxdebug->leave_sub();
}

#--- 4 locale ---#
# $main::locale->text('SAVED')
# $main::locale->text('DELETED')
# $main::locale->text('ADDED')
# $main::locale->text('PAYMENT POSTED')
# $main::locale->text('POSTED')
# $main::locale->text('POSTED AS NEW')
# $main::locale->text('ELSE')
# $main::locale->text('SAVED FOR DUNNING')
# $main::locale->text('DUNNING STARTED')
# $main::locale->text('PRINTED')
# $main::locale->text('MAILED')
# $main::locale->text('SCREENED')
# $main::locale->text('CANCELED')
# $main::locale->text('invoice')
# $main::locale->text('proforma')
# $main::locale->text('sales_order')
# $main::locale->text('pick_list')
# $main::locale->text('purchase_order')
# $main::locale->text('bin_list')
# $main::locale->text('sales_quotation')
# $main::locale->text('request_quotation')

sub save_history {
  $main::lxdebug->enter_sub();

  my $self = shift;
  my $dbh  = shift || $self->get_standard_dbh;

  if(!exists $self->{employee_id}) {
    &get_employee($self, $dbh);
  }

  my $query =
   qq|INSERT INTO history_erp (trans_id, employee_id, addition, what_done, snumbers) | .
   qq|VALUES (?, (SELECT id FROM employee WHERE login = ?), ?, ?, ?)|;
  my @values = (conv_i($self->{id}), $self->{login},
                $self->{addition}, $self->{what_done}, "$self->{snumbers}");
  do_query($self, $dbh, $query, @values);

  $dbh->commit;

  $main::lxdebug->leave_sub();
}

sub get_history {
  $main::lxdebug->enter_sub();

  my ($self, $dbh, $trans_id, $restriction, $order) = @_;
  my ($orderBy, $desc) = split(/\-\-/, $order);
  $order = " ORDER BY " . ($order eq "" ? " h.itime " : ($desc == 1 ? $orderBy . " DESC " : $orderBy . " "));
  my @tempArray;
  my $i = 0;
  if ($trans_id ne "") {
    my $query =
      qq|SELECT h.employee_id, h.itime::timestamp(0) AS itime, h.addition, h.what_done, emp.name, h.snumbers, h.trans_id AS id | .
      qq|FROM history_erp h | .
      qq|LEFT JOIN employee emp ON (emp.id = h.employee_id) | .
      qq|WHERE (trans_id = | . $trans_id . qq|) $restriction | .
      $order;

    my $sth = $dbh->prepare($query) || $self->dberror($query);

    $sth->execute() || $self->dberror("$query");

    while(my $hash_ref = $sth->fetchrow_hashref()) {
      $hash_ref->{addition} = $main::locale->text($hash_ref->{addition});
      $hash_ref->{what_done} = $main::locale->text($hash_ref->{what_done});
      $hash_ref->{snumbers} =~ s/^.+_(.*)$/$1/g;
      $tempArray[$i++] = $hash_ref;
    }
    $main::lxdebug->leave_sub() and return \@tempArray
      if ($i > 0 && $tempArray[0] ne "");
  }
  $main::lxdebug->leave_sub();
  return 0;
}

sub get_partsgroup {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig, $p) = @_;
  my $target = $p->{target} || 'all_partsgroup';

  my $dbh = $self->get_standard_dbh($myconfig);

  my $query = qq|SELECT DISTINCT pg.id, pg.partsgroup
                 FROM partsgroup pg
                 JOIN parts p ON (p.partsgroup_id = pg.id) |;
  my @values;

  if ($p->{searchitems} eq 'part') {
    $query .= qq|WHERE p.inventory_accno_id > 0|;
  }
  if ($p->{searchitems} eq 'service') {
    $query .= qq|WHERE p.inventory_accno_id IS NULL|;
  }
  if ($p->{searchitems} eq 'assembly') {
    $query .= qq|WHERE p.assembly = '1'|;
  }
  if ($p->{searchitems} eq 'labor') {
    $query .= qq|WHERE (p.inventory_accno_id > 0) AND (p.income_accno_id IS NULL)|;
  }

  $query .= qq|ORDER BY partsgroup|;

  if ($p->{all}) {
    $query = qq|SELECT id, partsgroup FROM partsgroup
                ORDER BY partsgroup|;
  }

  if ($p->{language_code}) {
    $query = qq|SELECT DISTINCT pg.id, pg.partsgroup,
                  t.description AS translation
                FROM partsgroup pg
                JOIN parts p ON (p.partsgroup_id = pg.id)
                LEFT JOIN translation t ON ((t.trans_id = pg.id) AND (t.language_code = ?))
                ORDER BY translation|;
    @values = ($p->{language_code});
  }

  $self->{$target} = selectall_hashref_query($self, $dbh, $query, @values);

  $main::lxdebug->leave_sub();
}

sub get_pricegroup {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig, $p) = @_;

  my $dbh = $self->get_standard_dbh($myconfig);

  my $query = qq|SELECT p.id, p.pricegroup
                 FROM pricegroup p|;

  $query .= qq| ORDER BY pricegroup|;

  if ($p->{all}) {
    $query = qq|SELECT id, pricegroup FROM pricegroup
                ORDER BY pricegroup|;
  }

  $self->{all_pricegroup} = selectall_hashref_query($self, $dbh, $query);

  $main::lxdebug->leave_sub();
}

sub all_years {
# usage $form->all_years($myconfig, [$dbh])
# return list of all years where bookings found
# (@all_years)

  $main::lxdebug->enter_sub();

  my ($self, $myconfig, $dbh) = @_;

  $dbh ||= $self->get_standard_dbh($myconfig);

  # get years
  my $query = qq|SELECT (SELECT MIN(transdate) FROM acc_trans),
                   (SELECT MAX(transdate) FROM acc_trans)|;
  my ($startdate, $enddate) = selectrow_query($self, $dbh, $query);

  if ($myconfig->{dateformat} =~ /^yy/) {
    ($startdate) = split /\W/, $startdate;
    ($enddate) = split /\W/, $enddate;
  } else {
    (@_) = split /\W/, $startdate;
    $startdate = $_[2];
    (@_) = split /\W/, $enddate;
    $enddate = $_[2];
  }

  my @all_years;
  $startdate = substr($startdate,0,4);
  $enddate = substr($enddate,0,4);

  while ($enddate >= $startdate) {
    push @all_years, $enddate--;
  }

  return @all_years;

  $main::lxdebug->leave_sub();
}

sub backup_vars {
  $main::lxdebug->enter_sub();
  my $self = shift;
  my @vars = @_;

  map { $self->{_VAR_BACKUP}->{$_} = $self->{$_} if exists $self->{$_} } @vars;

  $main::lxdebug->leave_sub();
}

sub restore_vars {
  $main::lxdebug->enter_sub();

  my $self = shift;
  my @vars = @_;

  map { $self->{$_} = $self->{_VAR_BACKUP}->{$_} if exists $self->{_VAR_BACKUP}->{$_} } @vars;

  $main::lxdebug->leave_sub();
}

sub prepare_for_printing {
  my ($self) = @_;

  my $defaults         = SL::DB::Default->get;

  $self->{templates} ||= $defaults->templates;
  $self->{formname}  ||= $self->{type};
  $self->{media}     ||= 'email';

  die "'media' other than 'email', 'file', 'printer' is not supported yet" unless $self->{media} =~ m/^(?:email|file|printer)$/;

  # Several fields that used to reside in %::myconfig (stored in
  # auth.user_config) are now stored in defaults. Copy them over for
  # compatibility.
  $self->{$_} = $defaults->$_ for qw(company address taxnumber co_ustid duns sepa_creditor_id);

  $self->{"myconfig_${_}"} = $::myconfig{$_} for grep { $_ ne 'dbpasswd' } keys %::myconfig;

  if (!$self->{employee_id}) {
    $self->{"employee_${_}"} = $::myconfig{$_} for qw(email tel fax name signature);
    $self->{"employee_${_}"} = $defaults->$_   for qw(address businessnumber co_ustid company duns sepa_creditor_id taxnumber);
  }

  # Load shipping address from database. If shipto_id is set then it's
  # one from the customer's/vendor's master data. Otherwise look an a
  # customized address linking back to the current record.
  my $shipto_module = $self->{type} =~ /_delivery_order$/                                             ? 'DO'
                    : $self->{type} =~ /sales_order|sales_quotation|request_quotation|purchase_order/ ? 'OE'
                    :                                                                                   'AR';
  my $shipto        = $self->{shipto_id} ? SL::DB::Shipto->new(shipto_id => $self->{shipto_id})->load
                    :                      SL::DB::Manager::Shipto->get_first(where => [ module => $shipto_module, trans_id => $self->{id} ]);
  if ($shipto) {
    $self->{$_} = $shipto->$_ for grep { m{^shipto} } map { $_->name } @{ $shipto->meta->columns };
    $self->{"shiptocvar_" . $_->config->name} = $_->value_as_text for @{ $shipto->cvars_by_config };
  }

  my $language = $self->{language} ? '_' . $self->{language} : '';

  my ($language_tc, $output_numberformat, $output_dateformat, $output_longdates);
  if ($self->{language_id}) {
    ($language_tc, $output_numberformat, $output_dateformat, $output_longdates) = AM->get_language_details(\%::myconfig, $self, $self->{language_id});
  }

  $output_dateformat   ||= $::myconfig{dateformat};
  $output_numberformat ||= $::myconfig{numberformat};
  $output_longdates    //= 1;

  $self->{myconfig_output_dateformat}   = $output_dateformat   // $::myconfig{dateformat};
  $self->{myconfig_output_longdates}    = $output_longdates    // 1;
  $self->{myconfig_output_numberformat} = $output_numberformat // $::myconfig{numberformat};

  # Retrieve accounts for tax calculation.
  IC->retrieve_accounts(\%::myconfig, $self, map { $_ => $self->{"id_$_"} } 1 .. $self->{rowcount});

  if ($self->{type} =~ /_delivery_order$/) {
    DO->order_details(\%::myconfig, $self);
  } elsif ($self->{type} =~ /sales_order|sales_quotation|request_quotation|purchase_order/) {
    OE->order_details(\%::myconfig, $self);
  } else {
    IS->invoice_details(\%::myconfig, $self, $::locale);
  }

  # Chose extension & set source file name
  my $extension = 'html';
  if ($self->{format} eq 'postscript') {
    $self->{postscript}   = 1;
    $extension            = 'tex';
  } elsif ($self->{"format"} =~ /pdf/) {
    $self->{pdf}          = 1;
    $extension            = $self->{'format'} =~ m/opendocument/i ? 'odt' : 'tex';
  } elsif ($self->{"format"} =~ /opendocument/) {
    $self->{opendocument} = 1;
    $extension            = 'odt';
  } elsif ($self->{"format"} =~ /excel/) {
    $self->{excel}        = 1;
    $extension            = 'xls';
  }

  my $printer_code    = $self->{printer_code} ? '_' . $self->{printer_code} : '';
  my $email_extension = $self->{media} eq 'email' && -f ($defaults->templates . "/$self->{formname}_email${language}.${extension}") ? '_email' : '';
  $self->{IN}         = "$self->{formname}${email_extension}${language}${printer_code}.${extension}";

  # Format dates.
  $self->format_dates($output_dateformat, $output_longdates,
                      qw(invdate orddate quodate pldate duedate reqdate transdate shippingdate deliverydate validitydate paymentdate datepaid
                         transdate_oe deliverydate_oe employee_startdate employee_enddate),
                      grep({ /^(?:datepaid|transdate_oe|reqdate|deliverydate|deliverydate_oe|transdate)_\d+$/ } keys(%{$self})));

  $self->reformat_numbers($output_numberformat, 2,
                          qw(invtotal ordtotal quototal subtotal linetotal listprice sellprice netprice discount tax taxbase total paid),
                          grep({ /^(?:linetotal|listprice|sellprice|netprice|taxbase|discount|paid|subtotal|total|tax)_\d+$/ } keys(%{$self})));

  $self->reformat_numbers($output_numberformat, undef, qw(qty price_factor), grep({ /^qty_\d+$/} keys(%{$self})));

  my ($cvar_date_fields, $cvar_number_fields) = CVar->get_field_format_list('module' => 'CT', 'prefix' => 'vc_');

  if (scalar @{ $cvar_date_fields }) {
    $self->format_dates($output_dateformat, $output_longdates, @{ $cvar_date_fields });
  }

  while (my ($precision, $field_list) = each %{ $cvar_number_fields }) {
    $self->reformat_numbers($output_numberformat, $precision, @{ $field_list });
  }

  $self->{template_meta} = {
    formname  => $self->{formname},
    language  => SL::DB::Manager::Language->find_by_or_create(id => $self->{language_id} || undef),
    format    => $self->{format},
    media     => $self->{media},
    extension => $extension,
    printer   => SL::DB::Manager::Printer->find_by_or_create(id => $self->{printer_id} || undef),
    today     => DateTime->today,
  };

  return $self;
}

sub calculate_arap {
  my ($self,$buysell,$taxincluded,$exchangerate,$roundplaces) = @_;

  # this function is used to calculate netamount, total_tax and amount for AP and
  # AR transactions (Kreditoren-/Debitorenbuchungen) by going over all lines
  # (1..$rowcount)
  # Thus it needs a fully prepared $form to work on.
  # calculate_arap assumes $form->{amount_$i} entries still need to be parsed

  # The calculated total values are all rounded (default is to 2 places) and
  # returned as parameters rather than directly modifying form.  The aim is to
  # make the calculation of AP and AR behave identically.  There is a test-case
  # for this function in t/form/arap.t

  # While calculating the totals $form->{amount_$i} and $form->{tax_$i} are
  # modified and formatted and receive the correct sign for writing straight to
  # acc_trans, depending on whether they are ar or ap.

  # check parameters
  die "taxincluded needed in Form->calculate_arap" unless defined $taxincluded;
  die "exchangerate needed in Form->calculate_arap" unless defined $exchangerate;
  die 'illegal buysell parameter, has to be \"buy\" or \"sell\" in Form->calculate_arap\n' unless $buysell =~ /^(buy|sell)$/;
  $roundplaces = 2 unless $roundplaces;

  my $sign = 1;  # adjust final results for writing amount to acc_trans
  $sign = -1 if $buysell eq 'buy';

  my ($netamount,$total_tax,$amount);

  my $tax;

  # parse and round amounts, setting correct sign for writing to acc_trans
  for my $i (1 .. $self->{rowcount}) {
    $self->{"amount_$i"} = $self->round_amount($self->parse_amount(\%::myconfig, $self->{"amount_$i"}) * $exchangerate * $sign, $roundplaces);

    $amount += $self->{"amount_$i"} * $sign;
  }

  for my $i (1 .. $self->{rowcount}) {
    next unless $self->{"amount_$i"};
    ($self->{"tax_id_$i"}) = split /--/, $self->{"taxchart_$i"};
    my $tax_id = $self->{"tax_id_$i"};

    my $selected_tax = SL::DB::Manager::Tax->find_by(id => "$tax_id");

    if ( $selected_tax ) {

      if ( $buysell eq 'sell' ) {
        $self->{AR_amounts}{"tax_$i"} = $selected_tax->chart->accno if defined $selected_tax->chart;
      } else {
        $self->{AP_amounts}{"tax_$i"} = $selected_tax->chart->accno if defined $selected_tax->chart;
      };

      $self->{"taxkey_$i"} = $selected_tax->taxkey;
      $self->{"taxrate_$i"} = $selected_tax->rate;
    };

    ($self->{"amount_$i"}, $self->{"tax_$i"}) = $self->calculate_tax($self->{"amount_$i"},$self->{"taxrate_$i"},$taxincluded,$roundplaces);

    $netamount  += $self->{"amount_$i"};
    $total_tax  += $self->{"tax_$i"};

  }
  $amount = $netamount + $total_tax;

  # due to $sign amount_$i und tax_$i already have the right sign for acc_trans
  # but reverse sign of totals for writing amounts to ar
  if ( $buysell eq 'buy' ) {
    $netamount *= -1;
    $amount    *= -1;
    $total_tax *= -1;
  };

  return($netamount,$total_tax,$amount);
}

sub format_dates {
  my ($self, $dateformat, $longformat, @indices) = @_;

  $dateformat ||= $::myconfig{dateformat};

  foreach my $idx (@indices) {
    if ($self->{TEMPLATE_ARRAYS} && (ref($self->{TEMPLATE_ARRAYS}->{$idx}) eq "ARRAY")) {
      for (my $i = 0; $i < scalar(@{ $self->{TEMPLATE_ARRAYS}->{$idx} }); $i++) {
        $self->{TEMPLATE_ARRAYS}->{$idx}->[$i] = $::locale->reformat_date(\%::myconfig, $self->{TEMPLATE_ARRAYS}->{$idx}->[$i], $dateformat, $longformat);
      }
    }

    next unless defined $self->{$idx};

    if (!ref($self->{$idx})) {
      $self->{$idx} = $::locale->reformat_date(\%::myconfig, $self->{$idx}, $dateformat, $longformat);

    } elsif (ref($self->{$idx}) eq "ARRAY") {
      for (my $i = 0; $i < scalar(@{ $self->{$idx} }); $i++) {
        $self->{$idx}->[$i] = $::locale->reformat_date(\%::myconfig, $self->{$idx}->[$i], $dateformat, $longformat);
      }
    }
  }
}

sub reformat_numbers {
  my ($self, $numberformat, $places, @indices) = @_;

  return if !$numberformat || ($numberformat eq $::myconfig{numberformat});

  foreach my $idx (@indices) {
    if ($self->{TEMPLATE_ARRAYS} && (ref($self->{TEMPLATE_ARRAYS}->{$idx}) eq "ARRAY")) {
      for (my $i = 0; $i < scalar(@{ $self->{TEMPLATE_ARRAYS}->{$idx} }); $i++) {
        $self->{TEMPLATE_ARRAYS}->{$idx}->[$i] = $self->parse_amount(\%::myconfig, $self->{TEMPLATE_ARRAYS}->{$idx}->[$i]);
      }
    }

    next unless defined $self->{$idx};

    if (!ref($self->{$idx})) {
      $self->{$idx} = $self->parse_amount(\%::myconfig, $self->{$idx});

    } elsif (ref($self->{$idx}) eq "ARRAY") {
      for (my $i = 0; $i < scalar(@{ $self->{$idx} }); $i++) {
        $self->{$idx}->[$i] = $self->parse_amount(\%::myconfig, $self->{$idx}->[$i]);
      }
    }
  }

  my $saved_numberformat    = $::myconfig{numberformat};
  $::myconfig{numberformat} = $numberformat;

  foreach my $idx (@indices) {
    if ($self->{TEMPLATE_ARRAYS} && (ref($self->{TEMPLATE_ARRAYS}->{$idx}) eq "ARRAY")) {
      for (my $i = 0; $i < scalar(@{ $self->{TEMPLATE_ARRAYS}->{$idx} }); $i++) {
        $self->{TEMPLATE_ARRAYS}->{$idx}->[$i] = $self->format_amount(\%::myconfig, $self->{TEMPLATE_ARRAYS}->{$idx}->[$i], $places);
      }
    }

    next unless defined $self->{$idx};

    if (!ref($self->{$idx})) {
      $self->{$idx} = $self->format_amount(\%::myconfig, $self->{$idx}, $places);

    } elsif (ref($self->{$idx}) eq "ARRAY") {
      for (my $i = 0; $i < scalar(@{ $self->{$idx} }); $i++) {
        $self->{$idx}->[$i] = $self->format_amount(\%::myconfig, $self->{$idx}->[$i], $places);
      }
    }
  }

  $::myconfig{numberformat} = $saved_numberformat;
}

sub create_email_signature {

  my $client_signature = $::instance_conf->get_signature;
  my $user_signature   = $::myconfig{signature};

  my $signature = '';
  if ( $client_signature or $user_signature ) {
    $signature  = "\n\n-- \n";
    $signature .= $user_signature   . "\n" if $user_signature;
    $signature .= $client_signature . "\n" if $client_signature;
  };
  return $signature;

};

sub layout {
  my ($self) = @_;
  $::lxdebug->enter_sub;

  my %style_to_script_map = (
    v3  => 'v3',
    neu => 'new',
  );

  my $menu_script = $style_to_script_map{$::myconfig{menustyle}} || '';

  package main;
  require "bin/mozilla/menu$menu_script.pl";
  package Form;
  require SL::Controller::FrameHeader;


  my $layout = SL::Controller::FrameHeader->new->action_header . ::render();

  $::lxdebug->leave_sub;
  return $layout;
}

sub calculate_tax {
  # this function calculates the net amount and tax for the lines in ar, ap and
  # gl and is used for update as well as post. When used with update the return
  # value of amount isn't needed

  # calculate_tax should always work with positive values, or rather as the user inputs them
  # calculate_tax uses db/perl numberformat, i.e. parsed numbers
  # convert to negative numbers (when necessary) only when writing to acc_trans
  # the amount from $form for ap/ar/gl is currently always rounded to 2 decimals before it reaches here
  # for post_transaction amount already contains exchangerate and correct sign and is rounded
  # calculate_tax doesn't (need to) know anything about exchangerate

  my ($self,$amount,$taxrate,$taxincluded,$roundplaces) = @_;

  $roundplaces //= 2;
  $taxincluded //= 0;

  my $tax;

  if ($taxincluded) {
    # calculate tax (unrounded), subtract from amount, round amount and round tax
    $tax       = $amount - ($amount / ($taxrate + 1)); # equivalent to: taxrate * amount / (taxrate + 1)
    $amount    = $self->round_amount($amount - $tax, $roundplaces);
    $tax       = $self->round_amount($tax, $roundplaces);
  } else {
    $tax       = $amount * $taxrate;
    $tax       = $self->round_amount($tax, $roundplaces);
  }

  $tax = 0 unless $tax;

  return ($amount,$tax);
};

1;

__END__

=head1 NAME

SL::Form.pm - main data object.

=head1 SYNOPSIS

This is the main data object of kivitendo.
Unfortunately it also acts as a god object for certain data retrieval procedures used in the entry points.
Points of interest for a beginner are:

 - $form->error            - renders a generic error in html. accepts an error message
 - $form->get_standard_dbh - returns a database connection for the

=head1 SPECIAL FUNCTIONS

=head2 C<redirect_header> $url

Generates a HTTP redirection header for the new C<$url>. Constructs an
absolute URL including scheme, host name and port. If C<$url> is a
relative URL then it is considered relative to kivitendo base URL.

This function C<die>s if headers have already been created with
C<$::form-E<gt>header>.

Examples:

  print $::form->redirect_header('oe.pl?action=edit&id=1234');
  print $::form->redirect_header('http://www.lx-office.org/');

=head2 C<header>

Generates a general purpose http/html header and includes most of the scripts
and stylesheets needed. Stylesheets can be added with L<use_stylesheet>.

Only one header will be generated. If the method was already called in this
request it will not output anything and return undef. Also if no
HTTP_USER_AGENT is found, no header is generated.

Although header does not accept parameters itself, it will honor special
hashkeys of its Form instance:

=over 4

=item refresh_time

=item refresh_url

If one of these is set, a http-equiv refresh is generated. Missing parameters
default to 3 seconds and the refering url.

=item stylesheet

Either a scalar or an array ref. Will be inlined into the header. Add
stylesheets with the L<use_stylesheet> function.

=item landscape

If true, a css snippet will be generated that sets the page in landscape mode.

=item favicon

Used to override the default favicon.

=item title

A html page title will be generated from this

=item mtime_ischanged

Tries to avoid concurrent write operations to records by checking the database mtime with a fetched one.

Can be used / called with any table, that has itime and mtime attributes.
Valid C<table> names are: oe, ar, ap, delivery_orders, parts.
Can be called wit C<option> mail to generate a different error message.

Returns undef if no save operation has been done yet ($self->{id} not present).
Returns undef if no concurrent write process is detected otherwise a error message.

=back

=cut
