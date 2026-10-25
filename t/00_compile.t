use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use_ok('Disperl::Client');
use_ok('Disperl::Config');
use_ok('Disperl::Components');
use_ok('Disperl::WebSocket');
use_ok('Disperl::Gateway');

done_testing;
