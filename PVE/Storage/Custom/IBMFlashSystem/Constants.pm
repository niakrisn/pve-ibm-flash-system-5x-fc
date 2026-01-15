package PVE::Storage::Custom::IBMFlashSystem::Constants;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    VOLUME_STATE_TIMEOUT
    FCMAP_PREPARE_TIMEOUT
    FCMAP_START_TIMEOUT
    FCMAP_COPY_TIMEOUT
    FCMAP_STOP_TIMEOUT
    DEVICE_DISCOVERY_TIMEOUT
    RESTORE_TIMEOUT
    MAX_API_RETRIES
    MAX_BUSY_RETRIES
    RETRY_DELAY_SEC
    BUSY_RETRY_DELAY_SEC
    MIN_VOLUME_SIZE_BYTES
);

# Volume operations
use constant VOLUME_STATE_TIMEOUT    => 30;   # Wait for vdisk exists/absent/unmapped
use constant DEVICE_DISCOVERY_TIMEOUT => 30;  # Wait for multipath device

# FlashCopy operations
use constant FCMAP_PREPARE_TIMEOUT   => 60;   # prestartfcmap
use constant FCMAP_START_TIMEOUT     => 60;   # Wait for copying state
# copyrate=0 makes it stay in copying, but if we used copyrate>0 it would go to idle_or_copied
use constant FCMAP_COPY_TIMEOUT      => 60;   # Wait for idle_or_copied (if applicable)
use constant FCMAP_STOP_TIMEOUT      => 300;  # stopfcmap with cleaning
use constant RESTORE_TIMEOUT         => 600;  # Rollback restore operation

# API retry logic
use constant MAX_API_RETRIES         => 3;
use constant MAX_BUSY_RETRIES        => 5;
use constant RETRY_DELAY_SEC         => 1;
use constant BUSY_RETRY_DELAY_SEC    => 2;

# Volume sizing
use constant MIN_VOLUME_SIZE_BYTES   => 4 * 1024 * 1024;  # 4 MB

1;
