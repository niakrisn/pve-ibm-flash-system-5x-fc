#!/usr/bin/env perl
# Storage Helpers for Integration Tests
# Provides cleanup and query functions for volumes and mappings

package StorageHelpers;

use strict;
use warnings;
use Exporter 'import';
use JSON;

our @EXPORT_OK = qw(volume_exists cleanup_volume get_volume_info get_host_mappings get_flashcopy_mappings);

# Add plugin paths
use lib 'PVE/Storage/Custom', 'PVE/Storage/Custom/IBMFlashSystem';

use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage::Custom::IBMFlashSystem::Logger;

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

# Get host mappings for a volume
# Returns: arrayref of mapping objects
sub get_host_mappings {
    my ($env, $volname) = @_;

    my $result = eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
            'PVE::Storage::Custom::IBMFlashSystem',
            $env->scfg,
            $env->storeid,
            'POST',
            '/lsvdiskhostmap',
            { name => $volname },
        );
    };

    return [] if $@ || !$result;
    # Handle both array and hash responses
    if (ref($result) eq 'ARRAY') {
        return $result;
    } elsif (ref($result) eq 'HASH') {
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
