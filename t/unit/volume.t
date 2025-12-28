#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm
# Tests Proxmox Storage API v13 methods

use strict;
use warnings;
use Test::More;
use Test::Exception;
use lib 't/unit/lib';

# Mock modules first
use MockIBMFlashSystemAPI;

# Then load the plugin
use PVE::Storage::Custom::IBMFlashSystem::Volume;

# Test configuration
my %test_scfg = (
    storage => 'ibmfs-test',
    portal => '10.0.0.222',
    pool => 'pool-pvc-01',
    hostcluster => 'pvc-01',
    username => 'testuser',
    timeout => 30,
    debug => 0,
);

my $test_storeid = 'ibmfs-test';
my $test_vmid = 100;
my $test_volname = 'vm-100-disk-0';

# ============================================================================
# Test 1: activate_storage
# ============================================================================
subtest 'activate_storage' => sub {
    plan tests => 3;

    # Mock successful responses
    MockIBMFlashSystemAPI->mock_response(
        '/lshostcluster/pvc-01' => { id => '1', name => 'pvc-01', status => 'online' },
        '/lsmdiskgrp/pool-pvc-01' => { capacity => '1.00TB', free_capacity => '1.00TB' },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::activate_storage(
            $test_storeid, \%test_scfg, {}
        );
    } 'activate_storage succeeds';

    # Verify API was called
    my @calls = MockIBMFlashSystemAPI->get_calls();
    like($calls[0], qr/lshostcluster/, 'Called lshostcluster');
    like($calls[1], qr/lsmdiskgrp/, 'Called lsmdiskgrp');

    MockIBMFlashSystemAPI->reset();
};

# ============================================================================
# Test 2: status
# ============================================================================
subtest 'status' => sub {
    plan tests => 2;

    MockIBMFlashSystemAPI->mock_response(
        '/lsmdiskgrp/pool-pvc-01' => {
            capacity => '1099511627776',    # 1TB in bytes
            free_capacity => '549755813888',  # 512GB in bytes
        },
    );

    my ($total, $free, $used, $active) = PVE::Storage::Custom::IBMFlashSystem::Volume::status(
        $test_storeid, \%test_scfg, {}
    );

    is($total, 1099511627776, 'Total capacity in bytes');
    is($free, 549755813888, 'Free capacity in bytes');

    MockIBMFlashSystemAPI->reset();
};

# ============================================================================
# Test 3: alloc_image (create volume)
# ============================================================================
subtest 'alloc_image' => sub {
    plan tests => 3;

    my $size_gb = 10;
    my $size_bytes = $size_gb * 1024 * 1024 * 1024;

    MockIBMFlashSystemAPI->mock_response(
        '/mkvolume' => {
            id => '123',
            name => $test_volname,
            capacity => "$size_gb.00GB",
        },
    );

    my $volname = PVE::Storage::Custom::IBMFlashSystem::Volume::alloc_image(
        $test_storeid, \%test_scfg, $test_vmid, 'raw', $test_volname, $size_gb
    );

    is($volname, $test_volname, 'Returns volume name');

    # Verify the API call
    my ($call) = MockIBMFlashSystemAPI->get_calls();
    like($call, qr/mkvolume/, 'Called mkvolume');
    like($call, qr/"size":\s*$size_bytes/, 'Passed size in bytes');

    MockIBMFlashSystemAPI->reset();
};

# ============================================================================
# Test 4: volume_size_info
# ============================================================================
subtest 'volume_size_info' => sub {
    plan tests => 2;

    MockIBMFlashSystemAPI->mock_response(
        "/lsvdisk/$test_volname" => {
            id => '123',
            name => $test_volname,
            capacity => '10.00GB',
            used_capacity => '2.50GB',
        },
    );

    my ($size, $used) = PVE::Storage::Custom::IBMFlashSystem::Volume::volume_size_info(
        \%test_scfg, $test_storeid, $test_volname, 30
    );

    is($size, 10 * 1024 * 1024 * 1024, 'Size in bytes');
    is($used, 2.5 * 1024 * 1024 * 1024, 'Used in bytes');

    MockIBMFlashSystemAPI->reset();
};

# ============================================================================
# Test 5: list_images
# ============================================================================
subtest 'list_images' => sub {
    plan tests => 2;

    MockIBMFlashSystemAPI->mock_response(
        '/lsvdisk' => [
            { id => '1', name => 'vm-100-disk-0', capacity => '10.00GB', vdisk_UID => '6005...100' },
            { id => '2', name => 'vm-100-disk-1', capacity => '20.00GB', vdisk_UID => '6005...101' },
            { id => '3', name => 'base-9000-disk-0', capacity => '50.00GB', vdisk_UID => '6005...102' },
        ],
    );

    my $volumes = PVE::Storage::Custom::IBMFlashSystem::Volume::list_images(
        $test_storeid, \%test_scfg, {}
    );

    is(scalar(keys %$volumes), 3, 'Returns 3 volumes');
    ok($volumes->{"vm-100-disk-0"}, 'Contains vm-100-disk-0');

    MockIBMFlashSystemAPI->reset();
};

# ============================================================================
# Test 6: free_image (delete volume) - with mappings
# ============================================================================
subtest 'free_image with mappings' => sub {
    plan tests => 3;

    # Mock: volume has mappings that need to be removed first
    MockIBMFlashSystemAPI->mock_sequence([
        # Step 1: Get volume info
        [ GET => "/lsvdisk/$test_volname" => { id => '123', name => $test_volname } ],

        # Step 2: Check for FlashCopy mappings (found)
        [ POST => '/lsfcmap' => [
            { id => '1', source_vdisk_name => $test_volname, target_vdisk_name => 'snap-1' }
        ]],

        # Step 3: Stop FlashCopy
        [ POST => '/stopfcmap/1' => {} ],

        # Step 4: Remove FlashCopy
        [ POST => '/rmfcmap/1' => {} ],

        # Step 5: Get host mappings
        [ POST => "/lsvdiskhostmap/123" => [
            { host_name => 'pve-01', id => '1' }
        ]],

        # Step 6: Remove host mapping
        [ POST => "/rmvdiskhostmap/123" => { host => 'pve-01' } ],

        # Step 7: Delete volume
        [ POST => "/rmvdisk/123" => {} ],
    ]);

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::free_image(
            $test_storeid, \%test_scfg, $test_volname, 0
        );
    } 'free_image succeeds with mappings';

    my @calls = MockIBMFlashSystemAPI->get_calls();
    is(scalar(@calls), 7, 'Made 7 API calls');

    # Verify cleanup sequence
    like(join(' ', @calls), qr/lsfcmap.*stopfcmap.*rmfcmap.*lsvdiskhostmap.*rmvdiskhostmap.*rmvdisk/s,
        'Cleanup order: fcmaps -> mappings -> delete');

    MockIBMFlashSystemAPI->reset();
};

# ============================================================================
# Test 7: volume_resize
# ============================================================================
subtest 'volume_resize' => sub {
    plan tests => 2;

    MockIBMFlashSystemAPI->mock_sequence([
        # Get volume info (including current fcmaps)
        [ POST => "/lsvdisk/$test_volname" => { id => '123', name => $test_volname, capacity => '10.00GB' } ],

        # Check for dependent fcmaps
        [ POST => '/lsfcmap' => [
            { id => '1', source_vdisk_name => $test_volname, target_vdisk_name => 'snap-1', state => 'active' }
        ]],

        # Expand main volume
        [ POST => "/expandvdisksize/123" => {} ],

        # Expand dependent snapshot too
        [ POST => "/expandvdisksize/456" => {} ],
    ]);

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::volume_resize(
            \%test_scfg, $test_storeid, $test_volname, 15, 0
        );
    } 'volume_resize succeeds';

    my @calls = MockIBMFlashSystemAPI->get_calls();
    like($calls[2], qr/expandvdisksize.*5368709120/, 'Expand by 5GB in bytes');

    MockIBMFlashSystemAPI->reset();
};

# ============================================================================
# Test 8: path (returns device path)
# ============================================================================
subtest 'path' => sub {
    plan tests => 2;

    my $test_uid = '60050763808185CFD000000000000150';

    MockIBMFlashSystemAPI->mock_response(
        "/lsvdisk/$test_volname" => {
            id => '123',
            name => $test_volname,
            vdisk_UID => $test_uid,
        },
    );

    my $path = PVE::Storage::Custom::IBMFlashSystem::Volume::path(
        \%test_scfg, $test_volname, $test_storeid, undef
    );

    is($path, "/dev/mapper/3" . lc($test_uid), 'Returns correct multipath path');

    my ($call) = MockIBMFlashSystemAPI->get_calls();
    like($call, qr/lsvdisk.*$test_volname/, 'Queried volume for UID');

    MockIBMFlashSystemAPI->reset();
};

# ============================================================================
# Test 9: activate_volume (map to host)
# ============================================================================
subtest 'activate_volume' => sub {
    plan tests => 2;

    MockIBMFlashSystemAPI->mock_sequence([
        # Get volume ID and UID
        [ POST => "/lsvdisk/$test_volname" => {
            id => '123',
            name => $test_volname,
            vdisk_UID => '60050763808185CFD000000000000150',
        }],

        # Check existing mappings
        [ POST => "/lsvdiskhostmap/123" => [] ],

        # Create mapping
        [ POST => "/mkvdiskhostmap/123" => {} ],
    ]);

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::activate_volume(
            $test_storeid, \%test_scfg, $test_volname, undef, {}
        );
    } 'activate_volume succeeds';

    my @calls = MockIBMFlashSystemAPI->get_calls();
    like($calls[-1], qr/mkvdiskhostmap/, 'Created host mapping');

    MockIBMFlashSystemAPI->reset();
};

# ============================================================================
# Test 10: deactivate_volume (unmap from host)
# ============================================================================
subtest 'deactivate_volume' => sub {
    plan tests => 2;

    MockIBMFlashSystemAPI->mock_sequence([
        # Get volume info
        [ POST => "/lsvdisk/$test_volname" => {
            id => '123',
            name => $test_volname,
            vdisk_UID => '60050763808185CFD000000000000150',
        }],

        # Remove host mapping
        [ POST => "/rmvdiskhostmap/123" => {} ],
    ]);

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::deactivate_volume(
            $test_storeid, \%test_scfg, $test_volname, undef
        );
    } 'deactivate_volume succeeds';

    my @calls = MockIBMFlashSystemAPI->get_calls();
    like($calls[-1], qr/rmvdiskhostmap/, 'Removed host mapping');

    MockIBMFlashSystemAPI->reset();
};

# ============================================================================
# Test 11: create_base
# ============================================================================
subtest 'create_base' => sub {
    plan tests => 2;

    my $base_name = 'base-100-disk-0';

    MockIBMFlashSystemAPI->mock_sequence([
        # Check if exists
        [ POST => "/lsvdisk/$test_volname" => {
            id => '123',
            name => $test_volname,
            vdisk_UID => '60050763808185CFD000000000000150',
        }],

        # Rename to base-
        [ POST => "/chvdisk/$test_volname" => { name => $base_name } ],
    ]);

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::create_base(
            $test_storeid, \%test_scfg, $test_volname
        );
    } 'create_base succeeds';

    my @calls = MockIBMFlashSystemAPI->get_calls();
    like($calls[-1], qr/chvdisk/, 'Renamed volume to base-');

    MockIBMFlashSystemAPI->reset();
};

# ============================================================================
# Test 12: volume_has_feature
# ============================================================================
subtest 'volume_has_feature' => sub {
    plan tests => 4;

    my %features = (
        clone => PVE::Storage::Custom::IBMFlashSystem::Volume::volume_has_feature(
            \%test_scfg, 'clone', $test_storeid, $test_volname, undef, 0
        ),
        snapshot => PVE::Storage::Custom::IBMFlashSystem::Volume::volume_has_feature(
            \%test_scfg, 'snapshot', $test_storeid, $test_volname, undef, 0
        ),
        copy => PVE::Storage::Custom::IBMFlashSystem::Volume::volume_has_feature(
            \%test_scfg, 'copy', $test_storeid, $test_volname, undef, 0
        ),
    );

    ok($features{clone}, 'Clone feature supported');
    ok($features{snapshot}, 'Snapshot feature supported');
    ok($features{copy}, 'Copy feature supported');
    ok($features{clone}{base}, 'Clone on base supported');
};

done_testing();
