package TestCommon;

use strict;
use warnings;
use Test::More;
use PVE::Storage;
use PVE::Storage::Custom::IBMFlashSystem::Client;
use JSON;
use Data::Dumper;

use Exporter 'import';
our @EXPORT = qw(
    setup_env
    run_cmd
    get_storeid
    api_request
    verify_volume_exists
    verify_volume_absent
    verify_fcmap_exists
    verify_fcmap_absent
    wait_for_task
    get_vmid_status
    log_info
    cleanup_test_volumes
    cleanup_host_orphans
    verify_task_log
    wait_for_vm_config
);

my $STOREID = 'fs-01';

sub setup_env {
    my $cfg = PVE::Storage::config();
    my $scfg = PVE::Storage::storage_config($cfg, $STOREID);
    
    # Authenticate immediately
    eval {
        PVE::Storage::Custom::IBMFlashSystem::Client::authenticate('PVE::Storage::Custom::IBMFlashSystem::Client', $scfg, $STOREID);
    };
    if ($@) {
        plan skip_all => "Authentication failed: $@";
    }
    
    return ($cfg, $scfg);
}

sub get_storeid {
    return $STOREID;
}

sub log_info {
    my ($msg) = @_;
    diag("INFO: $msg");
}

sub run_cmd {
    my ($cmd) = @_;
    log_info("Running: $cmd");
    my $output = `$cmd 2>&1`;
    my $exit_code = $? >> 8;
    if ($exit_code != 0) {
        log_info("COMMAND FAILED (exit=$exit_code): $output");
    }
    return ($exit_code, $output);
}

sub api_request {
    my ($scfg, $method, $endpoint, $data) = @_;
    
    diag("DEBUG: API_REQUEST $method $endpoint Body: " . Dumper($data));

    return PVE::Storage::Custom::IBMFlashSystem::Client::_api_request(
        'PVE::Storage::Custom::IBMFlashSystem::Volume', 
        $scfg,
        get_storeid(),
        $method,
        $endpoint,
        $data
    );
}

sub verify_volume_exists {
    my ($scfg, $volname, $size_bytes) = @_;
    my $res = eval { api_request($scfg, 'POST', "/lsvdisk/$volname", { bytes => JSON::true }) };
    if ($@ || !defined $res || (ref($res) eq 'ARRAY' && !@$res) || (ref($res) eq 'HASH' && !keys %$res)) {
        my $err = $@ || "Not found (empty response)";
        diag("Volume $volname check failed: $err");
        
        # Dump all volumes to see what's actually there
        my $all = eval { api_request($scfg, 'POST', "/lsvdisk", {}) };
        if (ref($all) eq 'ARRAY') {
            diag("Existing volumes on storage: " . join(', ', map { $_->{name} } @$all));
        }
        
        fail("Volume $volname check failed");
        return 0;
    }
    # Handle both array and single object returns
    $res = $res->[0] if ref($res) eq 'ARRAY';
    pass("Volume $volname exists on storage");
    
    # Debug dump if looks empty
    if (!keys %$res) {
        diag("Response is empty HASH! Dump: " . Dumper($res));
        return 0;
    }
    
    if (defined $size_bytes) {
        my $actual = $res->{capacity};
        if (!defined $actual) {
             diag("Capacity missing in response! Dump: " . Dumper($res));
        }
        is($actual, $size_bytes, "Volume $volname size is " . ($actual // 'undef'));
    }
    return 1;
}

sub verify_volume_absent {
    my ($scfg, $volname) = @_;
    my $res = eval { api_request($scfg, 'POST', "/lsvdisk/$volname", {}) };
    
    # If API error (likely 500/CMMVC5753E object not found), then it's absent
    if ($@) {
        pass("Volume $volname absent (API error: $@)");
        return 1;
    }
    
    # If result is empty list, empty hash or undefined
    if (!defined $res || (ref($res) eq 'ARRAY' && scalar(@$res) == 0) || (ref($res) eq 'HASH' && !keys %$res)) {
        pass("Volume $volname absent");
        return 1;
    }
    
    # If it returns a non-empty hash or non-empty array, it exists
    if ((ref($res) eq 'HASH' && keys %$res) || (ref($res) eq 'ARRAY' && scalar(@$res) > 0)) {
        fail("Volume $volname STILL EXISTS on storage");
        diag("Non-empty response received: " . Dumper($res));
        return 0;
    }
    
    pass("Volume $volname absent (Unrecognized empty state)");
    return 1;
}

sub verify_fcmap_exists {
    my ($scfg, $source, $target) = @_;
    my $maps = api_request($scfg, 'POST', '/lsfcmap', {});
    my $found = 0;
    foreach my $map (@$maps) {
        if ($map->{source_vdisk_name} eq $source && $map->{target_vdisk_name} eq $target) {
            pass("FlashCopy map $source -> $target exists");
            $found = 1;
            last;
        }
    }
    fail("FlashCopy map $source -> $target NOT found") unless $found;
    return $found;
}

sub verify_fcmap_absent {
    my ($scfg, $source, $target) = @_;
    
    # Retry for up to 30 seconds to allow autodelete to finish
    my $max_retries = 30;
    for (my $i = 0; $i < $max_retries; $i++) {
        my $maps = api_request($scfg, 'POST', '/lsfcmap', {});
        my $found = 0;
        foreach my $map (@$maps) {
            if ($map->{source_vdisk_name} eq $source && $map->{target_vdisk_name} eq $target) {
                $found = 1;
                last;
            }
        }
        
        if (!$found) {
            pass("FlashCopy map $source -> $target absent");
            return 1;
        }
        
        sleep(1);
    }
    
    fail("FlashCopy map $source -> $target STILL EXISTS after 30s");
    return 0;
}

sub cleanup_host_orphans {
    my ($pattern) = @_; # Regex pattern for WWID if possible, or just flush all failed/orphan
    log_info("Cleaning up host orphans...");

    # 1. Flush any multipath maps matching IBM vendor
    my ($ret, $out) = run_cmd("multipath -ll");
    my @maps_to_flush;
    
    # Parser for multipath -ll: catch WWID and map name
    # Example: 360050763808185cfd000000000000430 dm-9 IBM,2145
    while ($out =~ /([0-9a-f]{32,})\s+dm-\d+\s+IBM,2145/gi) {
        my $wwid = $1;
        # For test environment, we flush all IBM maps if they are not supposed to be there
        # or if they have faulty paths.
        push @maps_to_flush, $wwid;
    }
    
    foreach my $wwid (@maps_to_flush) {
        log_info("Flushing multipath map: $wwid");
        run_cmd("multipath -f $wwid");
    }

    # 2. Cleanup stuck SCSI devices (IBM vendor) not part of any active map
    log_info("Cleaning up stale SCSI devices...");
    ($ret, $out) = run_cmd("multipath -ll");
    my %active_disks;
    # parsing: "| - 14:0:2:0 sdd 8:48 active ready running"
    while ($out =~ /\s(sd[a-z]+)\s/g) {
        $active_disks{$1} = 1;
    }
    
    my @sd_devs = glob("/sys/block/sd*");
    foreach my $dev_path (@sd_devs) {
        my $dev = $dev_path;
        $dev =~ s|.*/||; # get sda, sdb...
        
        next if $active_disks{$dev}; # Skip active paths
        
        # Check vendor
        my $vendor = `cat /sys/block/$dev/device/vendor 2>/dev/null`;
        chomp $vendor;
        if (defined $vendor && $vendor =~ /IBM/) {
             log_info("Deleting stale device: $dev (Vendor: $vendor)");
             run_cmd("echo 1 > /sys/block/$dev/device/delete");
        }
    }
}

sub cleanup_test_volumes {
    my ($scfg, $pattern) = @_;
    log_info("Cleaning up volumes matching: $pattern");
    
    my $vdisks = api_request($scfg, 'POST', '/lsvdisk', {});
    $vdisks = [] if ref($vdisks) ne 'ARRAY';
    
    my $hostname = `hostname -f`; chomp $hostname;
    my $short_hostname = $hostname; $short_hostname =~ s/\..*//;

    foreach my $vdisk (@$vdisks) {
        if ($vdisk->{name} =~ /$pattern/) {
            log_info("Deleting orphaned volume: " . $vdisk->{name});
            
            # Retrieve and stop any FC maps first
            my $fcmaps = eval { api_request($scfg, 'POST', '/lsfcmap', {}) };
            $fcmaps = [] if $@ || ref($fcmaps) ne 'ARRAY';

            foreach my $map (@$fcmaps) {
                if ($map->{source_vdisk_name} eq $vdisk->{name} || $map->{target_vdisk_name} eq $vdisk->{name}) {
                    eval { api_request($scfg, 'POST', "/stopfcmap/" . $map->{id}, {}); };
                    eval { api_request($scfg, 'POST', "/rmfcmap/" . $map->{id}, { force => JSON::true }); };
                }
            }
            
            # Remove host mappings (try both FQDN and shortname)
            eval { api_request($scfg, 'POST', "/rmvdiskhostmap/" . $vdisk->{id}, { host => $hostname }); };
            eval { api_request($scfg, 'POST', "/rmvdiskhostmap/" . $vdisk->{id}, { host => $short_hostname }); };
            eval { api_request($scfg, 'POST', "/rmvdiskhostmap/" . $vdisk->{id}, { host => 'pve-01' }); }; 
            eval { api_request($scfg, 'POST', "/rmvdiskhostmap/" . $vdisk->{id}, { host => 'pve-02' }); };

            # Delete volume
            eval { api_request($scfg, 'POST', "/rmvdisk/" . $vdisk->{id}, { force => JSON::true }); };
            if ($@) {
                log_info("FAILED to delete volume " . $vdisk->{name} . ": $@");
            } else {
                log_info("Successfully deleted volume " . $vdisk->{name});
            }
        }
    }

    # Aggressive cleanup: Try to delete expected test volume names explicitly
    my @aggressive_names;
    for my $id (9000, 9001, 9888, 9777, 9999) {
        push @aggressive_names, ("vm-$id-disk-0", "vm-$id-disk-1", "vm-$id-disk-2", "vm-$id-cloudinit");
        push @aggressive_names, ("base-$id-disk-0", "base-$id-disk-1", "base-$id-disk-2", "base-$id-cloudinit");
    }
    
    foreach my $name (@aggressive_names) {
         # Stop any FC maps involving this name
         my $fcmaps = eval { api_request($scfg, 'POST', '/lsfcmap', {}) };
         if (ref($fcmaps) eq 'ARRAY') {
             foreach my $map (@$fcmaps) {
                 if ($map->{source_vdisk_name} eq $name || $map->{target_vdisk_name} eq $name) {
                     eval { api_request($scfg, 'POST', "/stopfcmap/" . $map->{id}, {}); };
                     eval { api_request($scfg, 'POST', "/rmfcmap/" . $map->{id}, { force => JSON::true }); };
                 }
             }
         }
         
         eval { api_request($scfg, 'POST', "/rmvdiskhostmap/" . $name, { host => 'pve-01' }); };
         eval { api_request($scfg, 'POST', "/rmvdisk/" . $name, { force => JSON::true }); };
         if ($@) {
             # log_info("Failed to aggressively delete $name: $@") unless $@ =~ /CMMVC5753E/;
         } else {
             log_info("Aggressively deleted potential ghost volume: $name");
         }
    }
}

sub verify_task_log {
    my ($out, $desc) = @_;
    
    if ($out =~ /TASK ERROR/) {
        fail("$desc: Task Error found in log");
        diag("Log Content:\n$out");
        return 0;
    }
    
    if ($out =~ /WARNING/) {
        diag("$desc: WARNING found in log:\n$out");
        # We don't fail on warnings unless strict, but good to know
    }
    
    pass("$desc: Task log is clean");
    return 1;
}

sub get_vmid_status {
    my ($vmid) = @_;
    my ($ret, $out) = run_cmd("qm status $vmid");
    if ($out =~ /status: (\w+)/) {
        return $1;
    }
    return 'unknown';
}

# Wait for VM config file to exist and be stable
# This is needed after operations like rollback that may temporarily affect config
sub wait_for_vm_config {
    my ($vmid, $timeout) = @_;
    $timeout //= 10;
    
    my $start = time();
    while (time() - $start < $timeout) {
        my ($ret, $out) = run_cmd("qm config $vmid 2>&1");
        if ($ret == 0 && $out !~ /does not exist/) {
            log_info("VM $vmid config is stable");
            return 1;
        }
        sleep(1);
    }
    
    log_info("WARNING: VM $vmid config not stable after ${timeout}s");
    return 0;
}

1;
