# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Common Module - Shared functions between Volume.pm and Snapshot.pm

package PVE::Storage::Custom::IBMFlashSystem::Common;

use strict;
use warnings;
use JSON;
use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Logger;

use Exporter 'import';
our @EXPORT_OK = qw(_get_vdisk_id _get_vdisk_uid _clear_vdisk_uid_cache);

# vdisk UID cache (60s TTL)
my %vdisk_uid_cache;

# ============================================================================
# Public API
# ============================================================================

# Get vdisk UID by name - signature: ($class, $scfg, $volname, $storeid)
sub _get_vdisk_uid {
    my ($class, $scfg, $volname, $storeid) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER _get_vdisk_uid (volname=%s, storeid=%s)", $volname, $storeid);

    # Check cache first (60s TTL)
    my $now = time;
    if (exists $vdisk_uid_cache{$volname}) {
        my $cached = $vdisk_uid_cache{$volname};
        if ($now - $cached->{timestamp} < 60) {
            return $cached->{uid};
        }
    }

    # Query specific volume by name
    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$volname", { bytes => JSON::true });

    my $vdisk_info;
    if (ref($result) eq 'ARRAY') {
        $vdisk_info = $result->[0];
    } else {
        $vdisk_info = $result;
    }

    die "Volume '$volname' not found\n" unless $vdisk_info;

    my $vdisk_uid = $vdisk_info->{vdisk_UID} or die "Volume '$volname' has no vdisk_UID\n";

    # Cache the result
    $vdisk_uid_cache{$volname} = {
        uid => $vdisk_uid,
        timestamp => $now,
    };

    return $vdisk_uid;
}

# Get vdisk ID by name - signature: ($class, $scfg, $volname, $storeid)
sub _get_vdisk_id {
    my ($class, $scfg, $volname, $storeid) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "ENTER _get_vdisk_id (volname=%s, storeid=%s)", $volname, $storeid);

    # Query specific volume by name
    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$volname", { bytes => JSON::true });

    my $vdisk_info;
    if (ref($result) eq 'ARRAY') {
        $vdisk_info = $result->[0];
    } else {
        $vdisk_info = $result;
    }

    die "Volume '$volname' not found\n" unless $vdisk_info;

    my $vdisk_id = $vdisk_info->{id} or die "Volume '$volname' has no id\n";

    return $vdisk_id;
}

# Clear vdisk UID cache (for testing)
sub _clear_vdisk_uid_cache {
    %vdisk_uid_cache = ();
}

1;
