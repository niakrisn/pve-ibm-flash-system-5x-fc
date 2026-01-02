# IBM FlashSystem 5.x FC Storage Plugin for Proxmox VE 9.1+
# Protocol::FC Module - Fibre Channel protocol backend implementation

package PVE::Storage::Custom::IBMFlashSystem::Protocol::FC;

use strict;
use warnings;
use Fcntl qw(O_WRONLY);
use PVE::Tools qw(run_command);

use base qw(PVE::Storage::Custom::IBMFlashSystem::Protocol);

use PVE::Storage::Custom::IBMFlashSystem::Logger;
use PVE::Storage::Custom::IBMFlashSystem::Client;

# ============================================================================
# FC Protocol Implementation
# ============================================================================

# Get local WWPNs for FC connectivity
sub get_local_ports {
    my ($class) = @_;

    my @wwpns;

    # Scan /sys/class/fc_host for WWPNs
    if (opendir(my $dh, '/sys/class/fc_host')) {
        while (my $entry = readdir($dh)) {
            next if $entry =~ /^\./;
            my $port_name_file = "/sys/class/fc_host/$entry/port_name";
            if (-f $port_name_file) {
                if (open(my $fh, '<', $port_name_file)) {
                    my $wwpn = <$fh>;
                    chomp $wwpn;
                    # Format: 0xXX...XX, convert to XX:XX:...:XX format for IBM API
                    if ($wwpn =~ /^0x([0-9a-fA-F]{16})$/) {
                        $wwpn = $1;
                        $wwpn =~ s/(..)/$1:/g;
                        $wwpn =~ s/:$//;
                        push @wwpns, uc($wwpn);
                    }
                    close($fh);
                }
            }
        }
        closedir($dh);
    }

    return \@wwpns;
}

# Scan FC hosts for new devices
sub scan_for_devices {
    my ($class, $scfg) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Scanning FC hosts");

    # Scan only FC hosts (from /sys/class/fc_host)
    my $scanned = 0;
    if (opendir(my $dh, '/sys/class/fc_host')) {
        while (my $entry = readdir($dh)) {
            next if $entry =~ /^\./;

            # Sanitize: extract safe hostname via capture group (untaints the value)
            # fc_host entry format: hostX -> SCSI host is hostX
            if ($entry =~ /\A([\w]+)\z/) {
                my $scsi_host = $1;  # $1 is untainted by Perl

                my $scan_file = "/sys/class/scsi_host/$scsi_host/scan";
                if (-f $scan_file) {
                    eval {
                        sysopen(my $fh, $scan_file, O_WRONLY)
                            or die "Cannot open $scan_file: $!";
                        syswrite($fh, "- - -\n");
                        close($fh);
                        $scanned++;
                    };
                    if ($@) {
                        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Failed to scan FC host %s (error=%s)", $scsi_host, $@);
                    }
                }
            }
        }
        closedir($dh);
        PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Scanned %d FC hosts", $scanned);
    }

    return;
}

# Convert vdisk UID to multipath device name format
# UID format: 6005076XXXXXXXXX -> multipath: 36005076xxxxxxxxx (lowercase)
sub convert_uid_to_device {
    my ($class, $uid) = @_;

    # Add '3' prefix if UID starts with '6' (multipath convention)
    if ($uid =~ /^6/) {
        $uid = "3$uid";
    }

    # Convert to lowercase - Linux multipath creates devices in lowercase
    return lc($uid);
}

# Wait for multipath device to appear
sub wait_for_device {
    my ($class, $scfg, $vdisk_uid, $timeout) = @_;

    $timeout ||= 30;
    my $mpath = $class->convert_uid_to_device($vdisk_uid);
    my $device_path = "/dev/mapper/$mpath";

    my $start_time = time();
    while (time() - $start_time < $timeout) {
        # Scan for new devices
        $class->scan_for_devices($scfg);

        # Check if device exists - try multiple paths
        my $found = 0;

        # Check /dev/mapper directly
        if (-e $device_path) {
            $found = 1;
        }
        # Check via /dev/disk/by-id/scsi-3 (more reliable, try both cases)
        elsif (-e "/dev/disk/by-id/scsi-3$vdisk_uid") {
            $device_path = "/dev/disk/by-id/scsi-3$vdisk_uid";
            $found = 1;
        }
        elsif (-e "/dev/disk/by-id/scsi-3\L$vdisk_uid") {
            $device_path = "/dev/disk/by-id/scsi-3\L$vdisk_uid";
            $found = 1;
        }

        if ($found) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, $scfg, "Multipath device appeared (vdisk_uid=%s, device=%s, waited=%.1fs)", $vdisk_uid, $device_path, time() - $start_time);
            return 1;
        }

        select(undef, undef, undef, 0.5);  # 500ms poll interval
    }

    PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, $scfg, "Timeout waiting for multipath device (vdisk_uid=%s, device=%s, timeout=%d)", $vdisk_uid, $device_path, $timeout);

    die "Timeout waiting for multipath device '$device_path'\n";
}

# Get device path for a volume
sub get_device_path {
    my ($class, $uid) = @_;

    my $mpath = $class->convert_uid_to_device($uid);
    return "/dev/mapper/$mpath";
}

# Flush multipath device (ensure I/O is complete)
sub flush_device {
    my ($class, $device_name) = @_;

    my $mpath_device = "/dev/mapper/$device_name";

    if (-e $mpath_device) {
        eval {
            # Try multipath -F first to flush I/O
            run_command(['/usr/sbin/multipath', '-F', $device_name], timeout => 10);
        };
        if ($@) {
            PVE::Storage::Custom::IBMFlashSystem::Logger::log_warn($class, "Failed to flush multipath device %s (error=%s)", $device_name, $@);
        }
    }
    return;
}

# Remove multipath device
sub remove_device {
    my ($class, $device_name) = @_;

    my $mpath_device = "/dev/mapper/$device_name";

    if (-e $mpath_device) {
        eval {
            # Try multipath -f first
            run_command(['/usr/sbin/multipath', '-f', $device_name], timeout => 10);
        };
        if ($@) {
            # If multipath -f fails, try dmsetup remove
            eval {
                run_command(['/sbin/dmsetup', 'remove', $device_name], timeout => 5);
            };
        }
    }

    return;
}

# Remove SCSI devices for a given vdisk UID
sub remove_scsi_devices {
    my ($class, $uid) = @_;

    # Find all SCSI devices with this WWN via sysfs
    # FC devices have wwid files in /sys/block/sdX/device/wwid
    my @devices;
    
    # Convert UID to NAA format (naa.60050763...)
    my $uid_lower = lc($uid);
    my $naa_wwid = "naa.$uid_lower";
    
    # Scan all sd* block devices
    if (opendir(my $dh, '/sys/block')) {
        while (my $entry = readdir($dh)) {
            next unless $entry =~ /^sd[a-z]+$/;
            
            my $wwid_file = "/sys/block/$entry/device/wwid";
            if (-f $wwid_file) {
                if (open(my $fh, '<', $wwid_file)) {
                    my $wwid = <$fh>;
                    close($fh);
                    chomp($wwid) if $wwid;

                    if ($wwid && $wwid eq $naa_wwid) {
                        push @devices, $entry;
                    }
                }
            }
        }
        closedir($dh);
    }

    if (@devices) {
         PVE::Storage::Custom::IBMFlashSystem::Logger::log_info($class, undef, "Deleting SCSI devices for UID $uid: " . join(", ", @devices));
    } else {
         PVE::Storage::Custom::IBMFlashSystem::Logger::log_debug($class, undef, "No SCSI devices found for UID $uid (WWID: $naa_wwid)");
    }

    # Delete each SCSI device via sysfs
    for my $dev (@devices) {
        my $delete_file = "/sys/block/$dev/device/delete";
        if (-f $delete_file) {
            eval {
                open(my $fh, '>', $delete_file);
                print $fh "1";
                close($fh);
            };
        }
    }

    return;
}

# Create FC host port on storage array
sub create_host_port {
    my ($class, $scfg, $storeid, $hostname, $port) = @_;

    PVE::Storage::Custom::IBMFlashSystem::Client::api_request($class, $scfg, $storeid, 'POST', "/mkport/$hostname", {
        fcport_name => $port,
    });

    return;
}

# Validate multipathd configuration for FC
sub validate_system_config {
    my ($class, $scfg) = @_;

    my $config_output = "";

    # Get current active configuration from multipathd
    eval {
        PVE::Tools::run_command(['/usr/sbin/multipathd', 'show', 'config'],
            logfunc => sub { $config_output .= shift . "\n"; },
            timeout => 5);
    };

    if ($@ || !$config_output) {
        die "multipathd is not running or not responding. " .
            "Please install multipath-tools and start the service:\n" .
            "  apt-get install multipath-tools\n" .
            "  systemctl start multipathd\n";
    }

    # Parse user_friendly_names - must be 'no'
    my ($user_friendly_names) = $config_output =~ /user_friendly_names\s+"?([yes|no]+)"?/i;
    if (defined($user_friendly_names) && lc($user_friendly_names) eq 'yes') {
        die "CRITICAL: multipathd is configured with 'user_friendly_names yes'. " .
            "The IBM FlashSystem plugin requires 'user_friendly_names no'.\n";
    }

    # Parse find_multipaths - must be 'no' or 'off'
    my ($find_multipaths) = $config_output =~ /find_multipaths\s+"?([yes|no|off|on]+)"?/i;
    if (defined($find_multipaths) && (lc($find_multipaths) eq 'yes' || lc($find_multipaths) eq 'on')) {
        die "CRITICAL: multipathd has 'find_multipaths $find_multipaths' enabled. " .
            "The IBM FlashSystem plugin requires 'find_multipaths no'.\n";
    }

    return 1;
}

1;
