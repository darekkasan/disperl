use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use_ok('Disperl::Client');
use_ok('Disperl::Config');
use_ok('Disperl::Components');
use_ok('Disperl::Permissions');
use_ok('Disperl::AuditLog');
use_ok('Disperl::AutoMod');
use_ok('Disperl::Forum');
use_ok('Disperl::Sticker');
use_ok('Disperl::Stage');
use_ok('Disperl::Commands');
use_ok('Disperl::OAuth2');
use_ok('Disperl::Guild');
use_ok('Disperl::Entitlement');
use_ok('Disperl::RoleConnection');
use_ok('Disperl::Integration');
use_ok('Disperl::WebSocket');
use_ok('Disperl::Gateway');
use_ok('Disperl::Router');

done_testing;
