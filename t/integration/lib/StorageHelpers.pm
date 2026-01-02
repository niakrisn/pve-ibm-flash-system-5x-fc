#!/usr/bin/env perl
# Storage Helpers for Integration Tests
# Provides cleanup and query functions for volumes and mappings

package StorageHelpers;

use strict;
use warnings;
use Exporter 'import';
use JSON;

our @EXPORT_OK = qw(volume_exists volume_exists_by_wwn cleanup_volume get_volume_info get_volume_uid get_host_mappings get_flashcopy_mappings volume_is_accessible);

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

    return $info->{uid};
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

# Check if a volume is accessible on the storage
# Returns: 1 if accessible, 0 otherwise
sub volume_is_accessible {
    my ($env, $volname) = @_;

    return 0 unless $env && $volname;

    my $info = eval {
        PVE::Storage::Custom::IBMFlashSystem::volume_size_info(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->scfg,
            $env->storeid,
            $volname,
        );
    };

    return $@ ? 0 : 1;
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

    return [] if $@ || !$result;
    # Handle both array and hash responses
    if (ref($result) eq 'ARRAY') {
        return $result;
    } elsif (ref($result) eq 'HASH') {
        # Check for empty hash (no mappings) vs single mapping object
        my @keys = keys %$result;
        return [] if @keys == 0;
        return [$result];
    }
    return [];
}

# Get FlashCopy mappings for a volume (as source or target)
# Returns: arrayref of fcmap objects
sub get_flashcopy_mappings {
    my ($env, $volname) = @_;

    my $fcmaps = eval {
        # Get all FlashCopy mappings (requires POST method)
        my $all_fcmaps = PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->scfg,
            $env->storeid,
            'POST',
            '/lsfcmap',
            undef,
        );

        return [] unless ref($all_fcmaps) eq 'ARRAY';

        # Filter by volume name (source or target)
        my @filtered;
        foreach my $fcmap (@$all_fcmaps) {
            if (($fcmap->{source_vdisk_name} && $fcmap->{source_vdisk_name} eq $volname) ||
                ($fcmap->{target_vdisk_name} && $fcmap->{target_vdisk_name} eq $volname)) {
                push @filtered, $fcmap;
            }
        }
        return \@filtered;
    };

    if ($@) {
        warn "Error getting FlashCopy mappings: $@";
        return [];
    }

    return [] unless ref($fcmaps) eq 'ARRAY';
    return $fcmaps;
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
