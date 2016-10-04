#
# * Copyright 2016, Yahoo Inc.
# * Copyrights licensed under the New BSD License.
# * See the accompanying LICENSE file for terms.
#
# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use Fork::Worker;
use Test::More;
BEGIN { plan tests => 2 };

# first test passes if we got this far
ok(1); 

# second tess passes if new method returns expected object
my $f = Fork::Worker->new();
ok(1) if ref($f) eq 'SOSE::Fork';

__END__
