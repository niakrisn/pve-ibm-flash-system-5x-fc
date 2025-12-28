#!/usr/bin/env perl
# FC Test Helpers - check for FC connectivity and skip tests if not available

package FCHelpers;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(has_fc_connectivity skip_without_fc);

# Check if FC connectivity is available
sub has_fc_connectivity {
    return -d '/sys/class/fc_host';
}

# Skip tests if FC connectivity is not available
sub skip_without_fc {
    my ($reason) = @_;
    $reason ||= 'FC connectivity not available (/sys/class/fc_host missing)';

    unless (has_fc_connectivity()) {
        print "1..0 # SKIP $reason\n";
        exit 0;
    }
}

1;
