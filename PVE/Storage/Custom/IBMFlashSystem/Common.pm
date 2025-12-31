# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Common Module - Shared functions between Volume.pm and Snapshot.pm

package PVE::Storage::Custom::IBMFlashSystem::Common;

use strict;
use warnings;
use JSON;
use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Logger;

use Exporter 'import';
our @EXPORT_OK = qw(_get_vdisk_id _get_vdisk_uid _clear_vdisk_uid_cache _get_hostname wait_for_vdisk_state);

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

    # Query specific volume by name with retries
    my $max_attempts = 5;
    my $attempt = 0;
    my $vdisk_info;

    while ($attempt < $max_attempts) {
        my $result = eval { PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$volname", { bytes => JSON::true }) };
        
        if (ref($result) eq 'ARRAY' && scalar(@$result) > 0) {
            $vdisk_info = $result->[0];
        } elsif (ref($result) eq 'HASH' && keys %$result) {
            $vdisk_info = $result;
        }

        last if $vdisk_info && $vdisk_info->{vdisk_UID};

        $attempt++;
        if ($attempt < $max_attempts) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume '$volname' not found in API, retrying in 2s (attempt $attempt/$max_attempts)");
            sleep(2);
        }
    }

    unless ($vdisk_info && $vdisk_info->{vdisk_UID}) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Volume '$volname' not found or has no UID after $max_attempts attempts");
        return undef;
    }

    my $vdisk_uid = $vdisk_info->{vdisk_UID};

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

    # Query specific volume by name with retries
    my $max_attempts = 5;
    my $attempt = 0;
    my $vdisk_info;

    while ($attempt < $max_attempts) {
        my $result = eval { PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$volname", { bytes => JSON::true }) };
        
        if (ref($result) eq 'ARRAY' && scalar(@$result) > 0) {
            $vdisk_info = $result->[0];
        } elsif (ref($result) eq 'HASH' && keys %$result) {
            $vdisk_info = $result;
        }

        last if $vdisk_info && defined($vdisk_info->{id});

        $attempt++;
        if ($attempt < $max_attempts) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "Volume '$volname' not found in API, retrying in 2s (attempt $attempt/$max_attempts)");
            sleep(2);
        }
    }

    unless ($vdisk_info && defined($vdisk_info->{id})) {
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Volume '$volname' not found or has no ID after $max_attempts attempts");
        return undef;
    }

    return $vdisk_info->{id};
}

# Clear vdisk UID cache (for testing)
sub _clear_vdisk_uid_cache {
    %vdisk_uid_cache = ();
}

# Get hostname for this node
sub _get_hostname {
    my ($class) = @_;

    # Try to get FQDN first, fall back to short hostname
    my $hostname = eval { `hostname -f` } || `hostname`;
    chomp $hostname;

    return $hostname;
}

# Wait for vdisk to reach a specific state: 'exists', 'absent', 'online', 'unmapped'
# Returns: 1 on success, undef on timeout
sub wait_for_vdisk_state {
    my ($class, $scfg, $storeid, $volname, $target_state, $timeout) = @_;

    $timeout //= 30; # Default to 30 seconds
    my $start_time = time();
    my $interval = 2;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, $scfg, "ENTER wait_for_vdisk_state (volname=%s, target=%s, timeout=%ds)", $volname, $target_state, $timeout);

    while ((time() - $start_time) < $timeout) {
        # Note: _get_vdisk_id itself has retries, so we might want a direct check here to be faster
        # but for simplicity and safety against API transient errors, we use it.
        my $vdisk_id = eval { _get_vdisk_id($class, $scfg, $volname, $storeid) };

        if ($target_state eq 'exists') {
            return 1 if $vdisk_id;
        } elsif ($target_state eq 'absent') {
            return 1 if !$vdisk_id;
        } elsif ($target_state eq 'online') {
            if ($vdisk_id) {
                my $result = eval { PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdisk/$volname", {}) };
                my $vdisk_info = (ref($result) eq 'ARRAY') ? $result->[0] : $result;
                if ($vdisk_info && $vdisk_info->{status} eq 'online') {
                    return 1;
                }
            }
        } elsif ($target_state eq 'unmapped') {
            if ($vdisk_id) {
                my $mappings = eval { PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/lsvdiskhostmap/$vdisk_id", {}) };
                if (ref($mappings) eq 'ARRAY' && scalar(@$mappings) == 0) {
                    return 1;
                }
            } else {
                return 1; # Non-existent is unmapped
            }
        }

        sleep($interval);
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_error($class, $scfg, "TIMEOUT waiting for volume '%s' to reach state '%s'", $volname, $target_state);
    return undef;
}

1;
