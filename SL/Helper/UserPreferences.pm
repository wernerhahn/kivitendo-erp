package SL::Helper::UserPreferences;

use strict;

1;

__END__

=encoding utf-8

=head1 NAME

SL::Helper::UserPreferences - user based preferences store

=head1

  use SL::Helper::UserPreferences;
  my $user_pref = SL::Helper::UserPreferences->new(
    login             => $login,        # defaults to current user
    namespace         => $namespace,    # defaults to current package
    upgrade_callbacks => $upgrade_callbacks,
    current_version   => $version,      # defaults to __PACKAGE__->VERSION
    auto_store_back   => 0,             # default 1 
  );
  # OR
  my $user_pref = $::auth->current_user->user_preferences(
    namespace         => $namespace,
    upgrade_callbacks => $upgrade_callbacks,
    current_version   => $version,      # defaults to __PACKAGE__->VERSION
    auto_store_back   => 0, # default 1 
  );

  $user_pref->store($key, $value);
  my $val  = $user_pref->get($key);
  my $vals = $user_pref->get_all;
  my $keys = $user_pref->get_keys;
  $user_pref->delete($key);
  $user_pref->delete_all;

=head1 DESCRIPTION


=head1 BEHAVIOUR

* If a (namepace, key) tuple exists, a store will overwrite the last version

* If the value retrieved from the database is newer than the code version, an
  error must be thrown.

* get will check the version against the current version and apply all upgrade
  steps.

* if the final step is not the current version, behaviour is undefined

*  

=head1 VERSIONING

Every entry in the user prefs must have a version to be compatible in case of code upgrades.

Code reading user prefs must check if the version is the expected one, and must have upgrade code to upgrade out of date preferences to the current version.

Code SHOULD write the upgraded version back to the store at the earliest time to keep preferences up to date. This should be able to be disabled to have developer versions not overwrite preferences with unsupported versions.

Example:

Initial code dealing with prefs:

  our $VERSION = 1;

  $user_prefs->store("selected tab", $::form->{selected_tab});

And the someone edits the code and removes the tab "Webdav". To ensure favorites with webdav selected are upgraded:

  our $VERSION = 2;

  my $upgrade_callbacks = {
    2 => sub { $_[0] eq 'WebDav' ? 'MasterData' : $_[0]; },
  };

  my $val = $user_prefs->get("selected tab");

=head1 FUNCTIONS

=head1 SPECIAL CASES

* get must work in both scalar and list context

* version might be integer or version object

* not defined if it should be possible to retrieve the version of a tuple



=head1 BUGS

None yet :)

=head1 AUTHOR



=cut
