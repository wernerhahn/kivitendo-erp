#!/usr/bin/perl

use strict;

use lib 't';

use Data::Dumper;
use Test::More;

use SL::Auth;
use SL::DBConnect;
use SL::Form;
use SL::InstanceConfiguration;
use SL::LXDebug;
use SL::Layout::None;
use SL::LxOfficeConf;

our ($db_cfg, $dbh);

sub dbg {
  # diag(@_);
}

sub dbh_do {
  my ($dbh, $query, %params) = @_;

  if (ref($query)) {
    return if $query->execute(@{ $params{bind} || [] });
    BAIL_OUT($dbh->errstr);
  }

  return if $dbh->do($query, undef, @{ $params{bind} || [] });

  BAIL_OUT($params{message} . ": " . $dbh->errstr) if $params{message};
  BAIL_OUT("Query failed: " . $dbh->errstr . " ; query: $query");
}

sub verify_configuration {
  SL::LxOfficeConf->read;

  my %config = %{ $::lx_office_conf{'testing/database'} || {} };
  my @unset  = sort grep { !$config{$_} } qw(host port db user template);

  BAIL_OUT("Missing entries in configuration in section [testing/database]: " . join(' ', @unset)) if @unset;
}

sub setup {
  package main;

  $SIG{__DIE__}    = sub { Carp::confess( @_ ) } if $::lx_office_conf{debug}->{backtrace_on_die};
  $::lxdebug       = LXDebug->new(target => LXDebug::STDERR_TARGET);
  $::lxdebug->disable_sub_tracing;
  $::locale        = Locale->new($::lx_office_conf{system}->{language});
  $::form          = Form->new;
  $::auth          = SL::Auth->new(unit_tests_database => 1);
  $::locale        = Locale->new('de');
  $::instance_conf = SL::InstanceConfiguration->new;
  $db_cfg          = $::lx_office_conf{'testing/database'};
}

sub drop_and_create_database {
  my @dbi_options = (
    'dbi:Pg:dbname=' . $db_cfg->{template} . ';host=' . $db_cfg->{host} . ';port=' . $db_cfg->{port},
    $db_cfg->{user},
    $db_cfg->{password},
    SL::DBConnect->get_options,
  );

  $::auth->reset;
  my $dbh_template = SL::DBConnect->connect(@dbi_options) || BAIL_OUT("No database connection to the template database: " . $DBI::errstr);
  my $auth_dbh     = $::auth->dbconnect(1);

  if ($auth_dbh) {
    dbg("Database exists; dropping");
    $auth_dbh->disconnect;

    dbh_do($dbh_template, "DROP DATABASE \"" . $db_cfg->{db} . "\"", message => "Database could not be dropped");

    $::auth->reset;
  }

  dbg("Creating database");

  dbh_do($dbh_template, "CREATE DATABASE \"" . $db_cfg->{db} . "\" TEMPLATE \"" . $db_cfg->{template} . "\" ENCODING 'UNICODE'", message => "Database could not be created");
  $dbh_template->disconnect;
}

sub report_success {
  $dbh->disconnect;
  ok(1, "Database has been setup sucessfully.");
  done_testing();
}

sub apply_dbupgrade {
  my ($dbupdater, $control_or_file) = @_;

  my $file    = ref($control_or_file) ? ("sql/Pg-upgrade2" . ($dbupdater->{auth} ? "-auth" : "") . "/$control_or_file->{file}") : $control_or_file;
  my $control = ref($control_or_file) ? $control_or_file                                                                        : undef;

  dbg("Applying $file");

  my $error = $dbupdater->process_file($dbh, $file, $control);

  BAIL_OUT("Error applying $file: $error") if $error;
}

sub create_initial_schema {
  dbg("Creating initial schema");

  my @dbi_options = (
    'dbi:Pg:dbname=' . $db_cfg->{db} . ';host=' . $db_cfg->{host} . ';port=' . $db_cfg->{port},
    $db_cfg->{user},
    $db_cfg->{password},
    SL::DBConnect->get_options(PrintError => 0, PrintWarn => 0),
  );

  $dbh           = SL::DBConnect->connect(@dbi_options) || BAIL_OUT("Database connection failed: " . $DBI::errstr);
  $::auth->{dbh} = $dbh;
  my $dbupdater  = SL::DBUpgrade2->new(form => $::form, return_on_error => 1, silent => 1);
  my $defaults   = SL::DefaultManager->new($::lx_office_conf{system}->{default_manager});
  my $coa        = $defaults->chart_of_accounts( 'Germany-DATEV-SKR03EU' );
  my $am         = $defaults->accounting_method( 'cash' );
  my $pd         = $defaults->profit_determination( 'balance' );
  my $is         = $defaults->inventory_system( 'periodic' );
  my $curr       = $defaults->currency( 'EUR' );

  apply_dbupgrade($dbupdater, "sql/lx-office.sql");
  apply_dbupgrade($dbupdater, "sql/${coa}-chart.sql");

  dbh_do($dbh, qq|UPDATE defaults SET coa = '${coa}', accounting_method = '${am}', profit_determination = '${pd}', inventory_system = '${is}', curr = '${curr}'|);
  dbh_do($dbh, qq|CREATE TABLE schema_info (tag TEXT, login TEXT, itime TIMESTAMP DEFAULT now(), PRIMARY KEY (tag))|);
}

sub create_initial_auth_schema {
  dbg("Creating initial auth schema");

  my $dbupdater = SL::DBUpgrade2->new(form => $::form, return_on_error => 1, auth => 1);
  apply_dbupgrade($dbupdater, 'sql/auth_db.sql');
}

sub apply_upgrades {
  my %params            = @_;
  my $dbupdater         = SL::DBUpgrade2->new(form => $::form, return_on_error => 1, auth => $params{auth});
  my @unapplied_scripts = $dbupdater->unapplied_upgrade_scripts($dbh);

  apply_dbupgrade($dbupdater, $_) for @unapplied_scripts;

  # some dpupgrades are hardcoded for Germany and will be recovered by the same nasty code
  if ((not defined $params{auth}) && ($::lx_office_conf{system}->{default_manager} eq "swiss")) {
    my $defaults    = SL::DefaultManager->new($::lx_office_conf{system}->{default_manager});
    my $precision   = $defaults->precision( '0.01' );
    my $countrymode = $defaults->country( 'DE' );
    dbh_do($dbh, qq|UPDATE defaults SET precision = '${precision}', country_mode = '${countrymode}'|);
    # buchungsgruppen_sortkey.sql depends release_2_4_1
    dbh_do($dbh, qq|UPDATE buchungsgruppen SET sortkey=1  WHERE description='Standard 8%'|);
    dbh_do($dbh, qq|UPDATE buchungsgruppen SET sortkey=2  WHERE description='Standard 2.5%'|);
    # steuerfilterung.pl depends release_3_0_0
    dbh_do($dbh, qq|ALTER TABLE tax ADD chart_categories TEXT|);
    dbh_do($dbh, qq|UPDATE tax SET chart_categories = 'I' WHERE (taxnumber='2200') OR (taxnumber='2201')|);
    dbh_do($dbh, qq|UPDATE tax SET chart_categories = 'E' WHERE (taxnumber='1170') OR (taxnumber='1171')|);
    dbh_do($dbh, qq|UPDATE tax SET chart_categories = 'ALQCIE' WHERE chart_categories IS NULL|);
    dbh_do($dbh, qq|ALTER TABLE tax ALTER COLUMN chart_categories SET NOT NULL|);
    # taxzone_id_in_oe_delivery_orders.sql depends release_3_1_0
    dbh_do($dbh, qq|UPDATE oe SET taxzone_id = (SELECT id FROM tax_zones WHERE description = 'Schweiz') WHERE (taxzone_id = 0) OR (taxzone_id IS NULL)|);
    dbh_do($dbh, qq|UPDATE delivery_orders SET taxzone_id = (SELECT id FROM tax_zones WHERE description = 'Schweiz') WHERE (taxzone_id = 0) OR (taxzone_id IS NULL)|);
    dbh_do($dbh, qq|UPDATE ar SET taxzone_id = (SELECT id FROM tax_zones WHERE description = 'Schweiz') WHERE (taxzone_id = 0) OR (taxzone_id IS NULL)|);
    dbh_do($dbh, qq|UPDATE ap SET taxzone_id = (SELECT id FROM tax_zones WHERE description = 'Schweiz') WHERE (taxzone_id = 0) OR (taxzone_id IS NULL)|);
    # tax_skonto_automatic.sql depends release_3_2_0
    dbh_do($dbh, qq|UPDATE tax SET skonto_purchase_chart_id = (SELECT id FROM chart WHERE accno = '4900')|);
    dbh_do($dbh, qq|UPDATE tax SET skonto_sales_chart_id = (SELECT id FROM chart WHERE accno = '3800')|);
    # not available
    dbh_do($dbh, qq|UPDATE defaults SET rndgain_accno_id = (SELECT id FROM CHART WHERE accno='6953')|);
    dbh_do($dbh, qq|UPDATE defaults SET rndloss_accno_id = (SELECT id FROM CHART WHERE accno='6943')|);
  }
}

sub create_client_user_and_employee {
  dbg("Creating client, user, group and employee");

  dbh_do($dbh, qq|DELETE FROM auth.clients|);
  dbh_do($dbh, qq|INSERT INTO auth.clients (id, name, dbhost, dbport, dbname, dbuser, dbpasswd, is_default) VALUES (1, 'Unit-Tests', ?, ?, ?, ?, ?, TRUE)|,
         bind => [ @{ $db_cfg }{ qw(host port db user password) } ]);
  dbh_do($dbh, qq|INSERT INTO auth."user"         (id,        login)    VALUES (1, 'unittests')|);
  dbh_do($dbh, qq|INSERT INTO auth."group"        (id,        name)     VALUES (1, 'Vollzugriff')|);
  dbh_do($dbh, qq|INSERT INTO auth.clients_users  (client_id, user_id)  VALUES (1, 1)|);
  dbh_do($dbh, qq|INSERT INTO auth.clients_groups (client_id, group_id) VALUES (1, 1)|);
  dbh_do($dbh, qq|INSERT INTO auth.user_group     (user_id,   group_id) VALUES (1, 1)|);

  my %config                 = (
    default_printer_id       => '',
    template_format          => '',
    default_media            => '',
    email                    => 'unit@tester',
    tel                      => '',
    dateformat               => 'dd.mm.yy',
    show_form_details        => '',
    name                     => 'Unit Tester',
    signature                => '',
    hide_cvar_search_options => '',
    numberformat             => '1.000,00',
    vclimit                  => 0,
    favorites                => '',
    copies                   => '',
    menustyle                => 'v3',
    fax                      => '',
    stylesheet               => 'lx-office-erp.css',
    mandatory_departments    => 0,
    countrycode              => 'de',
  );

  my $sth = $dbh->prepare(qq|INSERT INTO auth.user_config (user_id, cfg_key, cfg_value) VALUES (1, ?, ?)|) || BAIL_OUT($dbh->errstr);
  dbh_do($dbh, $sth, bind => [ $_, $config{$_} ]) for sort keys %config;
  $sth->finish;

  $sth = $dbh->prepare(qq|INSERT INTO auth.group_rights (group_id, "right", granted) VALUES (1, ?, TRUE)|) || BAIL_OUT($dbh->errstr);
  dbh_do($dbh, $sth, bind => [ $_ ]) for sort $::auth->all_rights;
  $sth->finish;

  dbh_do($dbh, qq|INSERT INTO employee (id, login, name) VALUES (1, 'unittests', 'Unit Tester')|);

  $::auth->set_client(1) || BAIL_OUT("\$::auth->set_client(1) failed");
  %::myconfig = $::auth->read_user(login => 'unittests');
}

verify_configuration();
setup();
drop_and_create_database();
create_initial_schema();
create_initial_auth_schema();
apply_upgrades(auth => 1);
create_client_user_and_employee();
apply_upgrades();
report_success();

1;
