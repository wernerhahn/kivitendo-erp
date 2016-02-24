package SL::DefaultManager::Swiss;

use strict;
use parent qw(Rose::Object);

# client defaults
sub chart_of_accounts    { 'Switzerland-deutsch-MWST-2014' }
sub accounting_method    { 'accrual' }
sub inventory_system     { 'periodic' }
sub profit_determination { 'balance' }
sub currency             { 'CHF' }
sub precision            { 0.05 }
sub features             { ['bilanz', 'erfolgsrechnung'] }

# user defaults
sub numberformat        { "1'000.00" }
sub dateformat          { 'dd.mm.yy' }
sub timeformat          { 'hh:mm' }

# default for login/admin areas
sub country             { 'CH' }
sub language            { 'de' }

1;
