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

# Create VM with q35 + EFI + optional SCSI disks + optional cloud-init
# Args: ($env, $vmid, $scsi_disks_arrayref, $options_hashref)
# $scsi_disks_arrayref = [{ size => '10G', slot => 0 }, { size => '5G', slot => 1 }]
# $options_hashref = { cloudinit => 1, cloudinit_slot => 2, cloudinit_storage => 'fs-01' }
# Returns: 1 on success, 0 on failure
sub create_q35_vm {
    my ($env, $vmid, $scsi_disks, $options) = @_;
    $scsi_disks //= [];
    $options //= {};
    
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
    
    # Add cloud-init if requested
    if ($options->{cloudinit}) {
        my $ide_slot = $options->{cloudinit_slot} // 2;  # ide2 by default
        my $ci_storage = $options->{cloudinit_storage} // $env->{storeid};
        push @cmd, "--ide$ide_slot", "$ci_storage:cloudinit";
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

# Cleanup VM (silent and idempotent, used in test setup and cleanup blocks)
# Args: ($vmid)
sub cleanup_vm {
    my ($vmid) = @_;
    return unless $vmid;

    # Check if VM configuration exists before doing anything
    # This prevents "unable to find configuration file" errors in PVE tasks
    if (-f "/etc/pve/qemu-server/$vmid.conf") {
        # Check status and only stop if running
        my $status = `qm status $vmid 2>/dev/null`;
        if ($status && $status =~ /status: running/i) {
            system('qm', 'stop', $vmid, '--skiplock');
        }
        
        # Destroy VM with purge to be sure
        system('qm', 'destroy', $vmid, '--destroy-unreferenced-disks', '1');
    }
}


# Create VM on specific storage + optional cloud-init
# Args: ($env, $vmid, $storeid, $scsi_disks_arrayref, $options_hashref)
# $options_hashref = { cloudinit => 1, cloudinit_slot => 2, cloudinit_storage => 'fs-01' }
sub create_vm_on_storage {
    my ($env, $vmid, $storeid, $scsi_disks, $options) = @_;
    $scsi_disks //= [];
    $options //= {};
    
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

    # Always add EFI disk for OVMF (standard practice)
    push @cmd, '--efidisk0', "$storeid:1,efitype=4m";
    
    # Add cloud-init if requested
    if ($options->{cloudinit}) {
        my $ide_slot = $options->{cloudinit_slot} // 2;  # ide2 by default
        my $ci_storage = $options->{cloudinit_storage} // $storeid;
        push @cmd, "--ide$ide_slot", "$ci_storage:cloudinit";
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
