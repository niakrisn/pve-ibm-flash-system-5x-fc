#!/usr/bin/env perl
# Storage Helpers for Integration Tests
# Provides cleanup and query functions for volumes and mappings

package StorageHelpers;

use strict;
use warnings;
use Exporter 'import';
use JSON;

our @EXPORT_OK = qw(volume_exists volume_exists_by_wwn cleanup_volume get_volume_info get_volume_uid get_host_mappings get_flashcopy_mappings fcmap_exists get_fcmap_between local_volume_exists local_volume_path_exists get_local_vm_volumes verify_local_vm_volumes);

# Add plugin paths (rely on PERL5LIB for system-installed modules)
# use lib 'PVE/Storage/Custom', 'PVE/Storage/Custom/IBMFlashSystem';

use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Logger;
use PVE::Storage::Custom::IBMFlashSystem::Volume;

# ============================================================================
# Public API
# ============================================================================

# Check if volume exists on storage
# Returns: 1 if volume exists, 0 otherwise
sub volume_exists {
    my ($env, $volname) = @_;

    my $result = eval {
        PVE::Storage::Custom::IBMFlashSystem::volume_size_info(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->scfg,
            $env->storeid,
            $volname,
        );
    };

    return $@ ? 0 : 1;
}

# Get volume information
# Returns: hashref with volume data (capacity, used_capacity) or undef
sub get_volume_info {
    my ($env, $volname) = @_;

    my ($size_bytes, $format, $used_bytes, $owner) = eval {
        PVE::Storage::Custom::IBMFlashSystem::volume_size_info(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->scfg,
            $env->storeid,
            $volname,
        );
    };

    return undef if $@;

    return {
        capacity => $size_bytes,
        used_capacity => $used_bytes,
        format => $format,
    };
}

# Get volume UID (WWN) for device path construction
# Returns: string with vdisk_UID (WWN) or undef
sub get_volume_uid {
    my ($env, $volname) = @_;

    return undef unless $env && $volname;

    # Use the new Volume helper
    my $info = eval {
        PVE::Storage::Custom::IBMFlashSystem::Volume::_get_volume_info(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->scfg,
            $env->storeid,
            $volname,
        );
    };

    if ($@ || !$info) {
        warn "Error getting volume UID for $volname: $@" if $@;
        return undef;
    }

    return $info->{vdisk_UID};
}

# Check if volume exists on storage by WWN
# Returns: 1 if volume exists, 0 otherwise
sub volume_exists_by_wwn {
    my ($env, $wwn) = @_;

    return 0 unless $env && $wwn;

    # Query storage for volume with this UID/WWN
    my $result = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->scfg,
            $env->storeid,
            'POST',
            '/lsvdisk',
            { filtervalue => "vdisk_UID=$wwn" },
        );
    };

    return 0 if $@ || !$result;

    # Check if we got any results
    if (ref($result) eq 'ARRAY') {
        return scalar(@$result) > 0;
    } elsif (ref($result) eq 'HASH') {
        # Single volume returned
        my @keys = keys %$result;
        return @keys > 0;
    }

    return 0;
}


# Check if a volume exists on a local storage by querying pvesm list
sub local_volume_exists {
    my ($storeid, $volname) = @_;
    return 0 unless $storeid && $volname;

    my $list = `pvesm list $storeid 2>/dev/null`;
    return 0 unless $list;

    return $list =~ /\Q$storeid:$volname\E/ ? 1 : 0;
}

# Check if a local storage volume path exists on host
sub local_volume_path_exists {
    my ($storeid, $volname) = @_;
    return 0 unless $storeid && $volname;

    my $path = `pvesm path $storeid:$volname 2>/dev/null`;
    chomp $path if $path;
    return ($path && -e $path) ? 1 : 0;
}

# Get all volume names for a VM from a specific storage
# Returns: arrayref of volume names or empty arrayref on failure
sub get_local_vm_volumes {
    my ($storeid, $vmid) = @_;
    my $conf = `qm config $vmid 2>/dev/null`;
    return [] unless $conf;

    my @vols;
    while ($conf =~ /\Q$storeid\E:([^\s,]+)/g) {
        push @vols, $1;
    }
    return \@vols;
}

# Verify all volumes for a VM exist on local storage
# Returns: 1 if all volumes exist, 0 otherwise
sub verify_local_vm_volumes {
    my ($storeid, $vmid) = @_;
    my $vols = get_local_vm_volumes($storeid, $vmid);
    return 0 unless $vols && @$vols;

    for my $vol (@$vols) {
        return 0 unless local_volume_exists($storeid, $vol);
        return 0 unless local_volume_path_exists($storeid, $vol);
    }
    return 1;
}


# Get host mappings for a volume
sub get_host_mappings {
    my ($env, $volname) = @_;

    # Use volname directly as IBM API supports it
    my $result = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->scfg,
            $env->storeid,
            'POST',
            '/lsvdiskhostmap/' . $volname,
            {},
        );
    };
    die "Failed to list host mappings for $volname: $@" if $@;
    die "Empty response while listing host mappings for $volname\n" if !defined $result;

    # Handle both array and hash responses
    if (ref($result) eq 'ARRAY') {
        return $result;
    } elsif (ref($result) eq 'HASH') {
        # Check for empty hash (no mappings) vs single mapping object
        my @keys = keys %$result;
        return [] if @keys == 0;
        return [$result];
    }
    die "Unexpected host mapping response type: " . (ref($result) || 'SCALAR') . "\n";
}

# Get all FlashCopy mappings (strict)
sub _get_all_fcmaps {
    my ($env) = @_;

    die "Missing test environment for FlashCopy query\n" unless $env;

    my $result = PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
        'PVE::Storage::Custom::IBMFlashSystem',
        $env->scfg,
        $env->storeid,
        'POST',
        '/lsfcmap',
        undef,
    );

    if (ref($result) eq 'ARRAY') {
        return $result;
    } elsif (ref($result) eq 'HASH') {
        my @keys = keys %$result;
        return [] if @keys == 0;
        return [$result];
    }

    die "Unexpected FlashCopy response type: " . (ref($result) || 'SCALAR') . "\n";
}

# Get FlashCopy mappings for a volume (as source or target)
# Returns: arrayref of fcmap objects
sub get_flashcopy_mappings {
    my ($env, $volname) = @_;

    my $all_fcmaps = eval { _get_all_fcmaps($env) };
    die "Failed to list FlashCopy mappings for $volname: $@" if $@;

    # Filter by volume name (source or target)
    my @filtered;
    foreach my $fcmap (@$all_fcmaps) {
        if (($fcmap->{source_vdisk_name} && $fcmap->{source_vdisk_name} eq $volname) ||
            ($fcmap->{target_vdisk_name} && $fcmap->{target_vdisk_name} eq $volname)) {
            push @filtered, $fcmap;
        }
    }
    return \@filtered;
}

# Check if FlashCopy mapping exists between source and target volumes
# Returns: 1 if mapping exists, 0 otherwise
sub fcmap_exists {
    my ($env, $source_volname, $target_volname) = @_;

    return 0 unless $env && $source_volname && $target_volname;

    my $all_fcmaps = eval { _get_all_fcmaps($env) };
    die "Failed to check FlashCopy mapping $source_volname -> $target_volname: $@" if $@;

    foreach my $fcmap (@$all_fcmaps) {
        if ($fcmap->{source_vdisk_name} && $fcmap->{source_vdisk_name} eq $source_volname &&
            $fcmap->{target_vdisk_name} && $fcmap->{target_vdisk_name} eq $target_volname) {
            return 1;
        }
    }

    return 0;
}

# Get a FlashCopy mapping between source and target volumes
# Returns: hashref mapping or undef
sub get_fcmap_between {
    my ($env, $source_volname, $target_volname) = @_;

    return undef unless $env && $source_volname && $target_volname;

    my $all_fcmaps = eval { _get_all_fcmaps($env) };
    die "Failed to get FlashCopy mapping $source_volname -> $target_volname: $@" if $@;

    foreach my $map (@$all_fcmaps) {
        next unless $map->{source_vdisk_name} && $map->{target_vdisk_name};
        if ($map->{source_vdisk_name} eq $source_volname &&
            $map->{target_vdisk_name} eq $target_volname) {
            return $map;
        }
    }

    return undef;
}
# Force remove FlashCopy mappings for a volume
sub _remove_flashcopy_mappings {
    my ($env, $volname) = @_;

    my $fcmaps = get_flashcopy_mappings($env, $volname);
    return unless @$fcmaps;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug('StorageHelpers',
        $env->scfg,
        "Found %d FlashCopy mappings for volume %s, removing...",
        scalar(@$fcmaps), $volname);

    foreach my $fcmap (@$fcmaps) {
        my $fcmap_id = $fcmap->{id};

        # Stop if active/copying
        if ($fcmap->{state} && $fcmap->{state} =~ /active|copying/i) {
            eval {
                PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
                    'PVE::Storage::Custom::IBMFlashSystem',
                    $env->scfg,
                    $env->storeid,
                    'POST',
                    "/stopfcmap/$fcmap_id",
                    undef,
                );
            };
            warn "Failed to stop FlashCopy $fcmap_id: $@" if $@;
        }

        # Remove mapping
        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
                'PVE::Storage::Custom::IBMFlashSystem',
                $env->scfg,
                $env->storeid,
                'POST',
                "/rmfcmap/$fcmap_id",
                { force => JSON::true },
            );
        };
        warn "Failed to remove FlashCopy $fcmap_id: $@" if $@;
    }
}

# Force remove host mappings for a volume
sub _remove_host_mappings {
    my ($env, $volname) = @_;

    my $mappings = get_host_mappings($env, $volname);
    return unless @$mappings;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug('StorageHelpers',
        $env->scfg,
        "Found %d host mappings for volume %s, removing...",
        scalar(@$mappings), $volname);

    foreach my $map (@$mappings) {
        my $vdisk_id = $map->{vdisk_id} || $map->{id};
        my $host_id = $map->{host_id} || $map->{host} || $map->{hostcluster};

        # Skip if essential fields are missing
        next unless $vdisk_id && $host_id;

        eval {
            PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
                'PVE::Storage::Custom::IBMFlashSystem',
                $env->scfg,
                $env->storeid,
                'POST',
                '/rmvdiskhostmap',
                {
                    obj => $vdisk_id,
                    host => $host_id,
                    force => JSON::true,
                },
            );
        };
        warn "Failed to remove host mapping (vdisk_id=$vdisk_id, host=$host_id): $@" if $@;
    }
}

# Cleanup volume - remove all mappings and the volume itself
# This is a force cleanup for test failures
sub cleanup_volume {
    my ($env, $volname) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug('StorageHelpers',
        $env->scfg,
        "Cleaning up volume %s", $volname);

    # Use plugin's free_image which handles all cleanup correctly
    eval {
        PVE::Storage::Custom::IBMFlashSystem::free_image(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->storeid,
            $env->scfg,
            $volname,
            undef,  # is_base
        );
    };
    # Don't warn if volume doesn't exist
    warn "Failed to cleanup volume $volname: $@" if $@ && $@ !~ /not found|does not exist/i;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug('StorageHelpers',
        $env->scfg,
        "Cleanup complete for volume %s", $volname);

    return;
}

1;
