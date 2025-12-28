# IBM FlashSystem Storage Plugin - Integration Test Helper
# Provides utilities for testing against real storage array

package TestHelper;

use strict;
use warnings;
use Exporter 'import';
use Data::Dumper;
use JSON;

# Use the plugin directly for API requests
use PVE::Storage::Custom::IBMFlashSystem::Client;
use PVE::Storage;

our @EXPORT = qw(
    ssh_exec
    api_request
    get_token
    cleanup_test_volumes
    get_volume_mappings
    wait_for_device
    generate_volid
    get_scfg
);

# Remote server config
our $REMOTE_HOST = 'root@10.4.0.122';
our $STORAGE_ID = 'fs-01';
our $API_PORTAL = '10.0.0.222';

# Detect if we're running on the Proxmox server
# Check for any IBM token file
our $IS_LOCAL = 0;
if (-f '/run/pve-storage-ibm-ibmfs.token' ||
    -f '/run/pve-storage-ibm-fs-01.token' ||
    glob('/run/pve-storage-ibm-*.token')) {
    $IS_LOCAL = 1;
}

# Execute command on remote Proxmox server (or locally if on that server)
sub ssh_exec {
    my ($cmd, $die_on_error) = @_;

    $die_on_error //= 1;

    my $full_cmd;
    if ($IS_LOCAL) {
        $full_cmd = "$cmd 2>&1";
    } else {
        $full_cmd = "ssh $REMOTE_HOST '$cmd' 2>&1";
    }

    my $output = `$full_cmd`;
    my $exit_code = $? >> 8;

    if ($die_on_error && $exit_code != 0) {
        die "Command failed (exit=$exit_code): $cmd\nOutput: $output\n";
    }

    return ($output, $exit_code);
}

# Get cached token from remote server
# Auto-detect token file to handle different storage IDs
sub get_token {
    my ($output, $exit_code) = ssh_exec("cat /run/pve-storage-ibm-*.token 2>/dev/null | head -1", 0);

    # If that fails, try specific storage ID
    if (!$output || $exit_code != 0) {
        ($output, $exit_code) = ssh_exec("cat /run/pve-storage-ibm-$STORAGE_ID.token", 0);
    }

    die "No token found on remote server\n" unless $output && $exit_code == 0;
    chomp $output;
    return $output;
}

# Get storage config with proper storage ID
sub get_scfg {
    my $cfg = PVE::Storage::config();
    my $scfg = $cfg->{ids}->{$STORAGE_ID};

    # Add storage ID if not present (plugin expects it)
    $scfg->{storage} = $STORAGE_ID unless $scfg->{storage};

    return $scfg;
}

# Make API request to IBM FlashSystem
# Now uses the plugin's api_request method directly
sub api_request {
    my ($method, $endpoint, $data) = @_;

    my $scfg = get_scfg();

    return PVE::Storage::Custom::IBMFlashSystem::Client::api_request(
        'PVE::Storage::Custom::IBMFlashSystem',
        $scfg,
        $method,
        $endpoint,
        $data
    );
}

# Get all mappings for a specific volume
sub get_volume_mappings {
    my ($volname) = @_;

    my $result = api_request('POST', '/lsvdiskhostmap', {});
    return [] if ref($result) ne 'ARRAY';

    my @mappings = grep { $_->{vdisk_name} eq $volname } @$result;
    return \@mappings;
}

# Check if multipath device exists
sub wait_for_device {
    my ($vdisk_uid, $timeout) = @_;

    $timeout ||= 30;

    # Convert UID to multipath format
    my $mpath = $vdisk_uid;
    $mpath =~ s/^6/3/;
    $mpath = lc($mpath);

    my $start = time();
    while (time() - $start < $timeout) {
        my ($output) = ssh_exec("ls -la /dev/mapper/$mpath 2>/dev/null || echo 'NOT_FOUND'", 0);
        if ($output !~ /NOT_FOUND/) {
            return 1;
        }
        sleep(1);
    }

    return 0;
}

# Generate unique volume ID for testing
sub generate_volid {
    my ($prefix) = @_;

    $prefix ||= 'test';
    my $timestamp = time();
    my $rand = int(rand(10000));
    return "${prefix}-${timestamp}-${rand}";
}

# Clean up all test volumes
sub cleanup_test_volumes {
    my ($pattern) = @_;

    $pattern ||= 'test-';

    # Get all volumes
    my $result = api_request('POST', '/lsvdisk', {});

    # Handle error or empty result
    return if ref($result) ne 'ARRAY';

    my @test_volumes = grep { $_->{name} =~ /^$pattern/ } @$result;

    foreach my $vol (@test_volumes) {
        print "Cleaning up test volume: $vol->{name}\n";

        # Step 1: Remove all FlashCopy mappings for this volume
        my $fcmaps = api_request('POST', '/lsfcmap', {});
        if (ref($fcmaps) eq 'ARRAY') {
            foreach my $fcmap (@$fcmaps) {
                if ($fcmap->{source_vdisk_name} eq $vol->{name} ||
                    $fcmap->{target_vdisk_name} eq $vol->{name}) {

                    # Stop mapping first
                    eval { api_request('POST', "/stopfcmap/$fcmap->{id}", {}); };
                    # Remove mapping with force
                    eval { api_request('POST', "/rmfcmap/$fcmap->{id}", { force => JSON::true }); };
                }
            }
        }

        # Step 2: Remove host mappings - query by vdisk ID for complete list
        eval {
            my $mappings = api_request('POST', "/lsvdiskhostmap/$vol->{id}", {});
            if (ref($mappings) eq 'ARRAY') {
                foreach my $map (@$mappings) {
                    my $hostname = $map->{host_name};
                    eval {
                        api_request('POST', "/rmvdiskhostmap/$vol->{id}", { host => $hostname });
                    };
                }
            }
        };

        # Step 3: Delete volume (may still fail if mappings exist, but we tried)
        eval {
            api_request('POST', "/rmvdisk/$vol->{id}", {});
            print "Volume $vol->{name} deleted\n";
        };
        if ($@) {
            print "Warning: Failed to delete $vol->{name}: $@\n";
        }
    }
}

1;
