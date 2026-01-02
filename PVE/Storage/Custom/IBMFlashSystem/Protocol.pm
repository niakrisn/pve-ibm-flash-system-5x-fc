# IBM FlashSystem 5.x Storage Plugin for Proxmox VE 9.1+
# Protocol Module - Abstract interface for storage protocol backends

package PVE::Storage::Custom::IBMFlashSystem::Protocol;

use strict;
use warnings;

# ============================================================================
# Abstract Protocol Interface
# ============================================================================
# This module defines the interface that all protocol backends must implement.
# Currently only FC is implemented, but the interface is designed to support
# NVMe-oF (TCP, RoCE, RDMA) in the future.

# ============================================================================
# Factory Method - Returns appropriate protocol handler based on config
# ============================================================================

# Get protocol handler based on storage configuration
# Args: $scfg - storage configuration hash
# Returns: protocol handler class name
sub get_handler {
    my ($class, $scfg) = @_;
    
    # Default to FC if protocol not specified (backwards compatibility)
    my $protocol = $scfg->{protocol} // 'fc';
    
    if ($protocol eq 'fc') {
        require PVE::Storage::Custom::IBMFlashSystem::Protocol::FC;
        return 'PVE::Storage::Custom::IBMFlashSystem::Protocol::FC';
    }
    # Future protocols:
    # elsif ($protocol eq 'nvme-tcp') {
    #     require PVE::Storage::Custom::IBMFlashSystem::Protocol::NVMeoF_TCP;
    #     return 'PVE::Storage::Custom::IBMFlashSystem::Protocol::NVMeoF_TCP';
    # }
    
    die "Unknown protocol '$protocol'. Supported: fc\n";
}

# ============================================================================
# Abstract Interface Methods
# ============================================================================

# Get local ports for host connectivity
# Returns: arrayref of port identifiers (WWPNs for FC, NQNs for NVMe)
sub get_local_ports {
    my ($class) = @_;
    die "Abstract method get_local_ports() must be implemented by subclass\n";
}

# Scan for new devices after mapping
# Args: $scfg - storage configuration
sub scan_for_devices {
    my ($class, $scfg) = @_;
    die "Abstract method scan_for_devices() must be implemented by subclass\n";
}

# Convert vdisk UID to device name format
# Args: $uid - volume UID from storage array
# Returns: device name string
sub convert_uid_to_device {
    my ($class, $uid) = @_;
    die "Abstract method convert_uid_to_device() must be implemented by subclass\n";
}

# Wait for device to appear after mapping
# Args: $scfg - storage config, $uid - volume UID, $timeout - seconds
# Returns: 1 on success, dies on timeout
sub wait_for_device {
    my ($class, $scfg, $uid, $timeout) = @_;
    die "Abstract method wait_for_device() must be implemented by subclass\n";
}

# Get device path for a volume
# Args: $uid - volume UID
# Returns: device path string (e.g., /dev/mapper/xxx)
sub get_device_path {
    my ($class, $uid) = @_;
    die "Abstract method get_device_path() must be implemented by subclass\n";
}

# Flush device I/O before removal
# Args: $device_name - device identifier
sub flush_device {
    my ($class, $device_name) = @_;
    die "Abstract method flush_device() must be implemented by subclass\n";
}

# Remove device from local system
# Args: $device_name - device identifier
sub remove_device {
    my ($class, $device_name) = @_;
    die "Abstract method remove_device() must be implemented by subclass\n";
}

# Remove underlying SCSI/NVMe devices
# Args: $uid - volume UID
sub remove_scsi_devices {
    my ($class, $uid) = @_;
    die "Abstract method remove_scsi_devices() must be implemented by subclass\n";
}

# Create host port on storage array
# Args: $scfg, $storeid, $hostname, $port - port identifier
sub create_host_port {
    my ($class, $scfg, $storeid, $hostname, $port) = @_;
    die "Abstract method create_host_port() must be implemented by subclass\n";
}

# Validate system configuration for this protocol
# Dies with error message if configuration is invalid
sub validate_system_config {
    my ($class, $scfg) = @_;
    die "Abstract method validate_system_config() must be implemented by subclass\n";
}

1;
