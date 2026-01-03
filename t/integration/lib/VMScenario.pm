#!/usr/bin/env perl
# VM Scenario Helpers for Integration Tests
# Provides helpers for creating q35 VMs with EFI and verifying full lifecycle

package VMScenario;

use strict;
use warnings;
use Exporter 'import';
use Test::More;
use StateVerifier;

our @EXPORT_OK = qw(
    create_q35_vm
    create_vm_on_storage
    convert_to_template
    verify_full_lifecycle
    cleanup_vm
);

# Create VM with q35 + EFI + optional SCSI disks
# Args: ($env, $vmid, $scsi_disks_arrayref)
# $scsi_disks_arrayref = [{ size => '10G', slot => 0 }, { size => '5G', slot => 1 }]
# Returns: 1 on success, 0 on failure
sub create_q35_vm {
    my ($env, $vmid, $scsi_disks) = @_;
    $scsi_disks //= [];
    
    # Build qm create command
    my @cmd = (
        'qm', 'create', $vmid,
        '--bios', 'ovmf',
        '--machine', 'q35',
        '--scsihw', 'virtio-scsi-pci',
        '--memory', '512',
        '--boot', 'order=scsi0',
        '--efidisk0', "$env->{storeid}:1,efitype=4m",
    );
    
    # Add SCSI disks
    foreach my $disk (@$scsi_disks) {
        my $slot = $disk->{slot};
        my $size = $disk->{size};
        $size =~ s/G$//i;  # Remove 'G' suffix (qm expects just the number)
        push @cmd, "--scsi$slot", "$env->{storeid}:$size";
    }
    
    # Create VM
    my $result = system(@cmd);
    
    return $result == 0 ? 1 : 0;
}

# Verify full lifecycle: create → start → stop → destroy
# Args: ($env, $vmid, $disks_arrayref)
# $disks_arrayref = ['vm-9999-disk-0', 'vm-9999-disk-1', ...]
# Returns: 1 on success, 0 on failure
sub verify_full_lifecycle {
    my ($env, $vmid, $disks) = @_;
    
    # 1. Verify CREATED state
    unless (StateVerifier::verify_created($env, $vmid, $disks)) {
        diag("FAILED: VM $vmid not in CREATED state");
        return 0;
    }
    
    # 2. Start VM
    diag("Starting VM $vmid...");
    my $start_result = system('qm', 'start', $vmid);
    unless ($start_result == 0) {
        diag("FAILED: qm start $vmid failed");
        return 0;
    }
    
    # 3. Verify ACTIVATED state
    unless (StateVerifier::verify_activated($env, $vmid, $disks)) {
        diag("FAILED: VM $vmid not in ACTIVATED state");
        return 0;
    }
    
    # 4. Stop VM
    diag("Stopping VM $vmid...");
    my $stop_result = system('qm', 'stop', $vmid);
    unless ($stop_result == 0) {
        diag("FAILED: qm stop $vmid failed");
        return 0;
    }
    
    # 5. Verify DEACTIVATED state
    unless (StateVerifier::verify_deactivated($env, $vmid, $disks)) {
        diag("FAILED: VM $vmid not in DEACTIVATED state");
        return 0;
    }
    
    # 6. Destroy VM
    diag("Destroying VM $vmid...");
    my $destroy_result = system('qm', 'destroy', $vmid, '--destroy-unreferenced-disks', '1');
    unless ($destroy_result == 0) {
        diag("FAILED: qm destroy $vmid failed");
        return 0;
    }
    
    # 7. Verify DESTROYED state
    unless (StateVerifier::verify_destroyed($env, $vmid, $disks)) {
        diag("FAILED: VM $vmid not in DESTROYED state");
        return 0;
    }
    
    return 1;
}

# Cleanup VM (best-effort, used in test cleanup blocks)
# Args: ($vmid)
sub cleanup_vm {
    my ($vmid) = @_;
    
    # Try to stop VM
    eval { system('qm', 'stop', $vmid) };
    
    # Try to destroy VM
    eval { system('qm', 'destroy', $vmid, '--destroy-unreferenced-disks', '1') };
}


# Create VM on specific storage
# Args: ($env, $vmid, $storeid, $scsi_disks_arrayref)
sub create_vm_on_storage {
    my ($env, $vmid, $storeid, $scsi_disks) = @_;
    $scsi_disks //= [];
    
    my @cmd = (
        'qm', 'create', $vmid,
        '--bios', 'ovmf',
        '--machine', 'q35',
        '--scsihw', 'virtio-scsi-pci',
        '--memory', '512',
    );
    
    # Add SCSI disks
    foreach my $disk (@$scsi_disks) {
        my $slot = $disk->{slot};
        my $size = $disk->{size};
        $size =~ s/G$//i;
        push @cmd, "--scsi$slot", "$storeid:$size";
    }

    # Add EFI disk if not on local-lvm
    if ($storeid =~ /^fs-/) {
        push @cmd, '--efidisk0', "$storeid:1,efitype=4m";
    }
    
    my $result = system(@cmd);
    return $result == 0 ? 1 : 0;
}

# Convert VM to template
# Args: ($vmid)
sub convert_to_template {
    my ($vmid) = @_;
    my $result = system('qm', 'template', $vmid);
    return $result == 0 ? 1 : 0;
}

1;
