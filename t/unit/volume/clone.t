#!/usr/bin/env perl
# Unit tests for IBMFlashSystem Volume.pm clone_volume() method
# Tests volume cloning via FlashCopy (linked and full clones)

use strict;
use warnings;
use Test::More;
use Test::Exception;
use Test::MockModule;
use lib qw(lib t/unit/lib);

# Load test helpers
use lib 't/unit/lib';
use TestHelpers qw(setup_test_env restore_env);

# Load mock library
use MockLWP;

# Load plugin under test
use lib 'PVE/Storage/Custom';
use PVE::Storage::Custom::IBMFlashSystem::Volume;

my %test_scfg = (
    storage => 'ibmfs-test',
    portal  => '10.0.0.222',
    pool    => 'pool-pvc-01',
    timeout => 30,
);

my $test_storeid = 'ibmfs-test';
my $test_token = 'test-token-abc123';
my $source_volname = 'vm-100-disk-0';
my $target_vmid = 101;
my $new_name = 'vm-101-disk-0';

# ============================================================================
# Test: clone_volume - linked clone from base template
# ============================================================================
subtest 'clone_volume - linked clone from base template' => sub {

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    # Mock _find_free_diskname to return predictable name
    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_find_free_diskname', sub { return $new_name; });

    my $source_base = 'base-100-disk-0';

    # Get source volume size
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$source_base$},
        token       => $test_token,
        body        => { bytes => 1 },
        response    => {
            json => [{
                id       => '123',
                name     => $source_base,
                capacity => 10 * 1024 * 1024 * 1024,
            }]
        },
    );

    # Create target volume
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkvolume$},
        token       => $test_token,
        body        => {
            name => $new_name,
            pool => 'pool-pvc-01',
            size => 10 * 1024 * 1024 * 1024,
            unit => 'b',
            thin  => JSON::true,
        },
        response    => {
            json => { id => '456' }
        },
    );

    # Create FlashCopy mapping (copyrate=0 for linked clone)
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkfcmap$},
        token       => $test_token,
        body        => {
            source   => $source_base,
            target   => $new_name,
            copyrate => 0,
        },
        response    => {
            json => { id => '789' }
        },
    );

    # Pre-start FlashCopy
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/prestartfcmap/789$},
        token       => $test_token,
        response    => {
            json => {}
        },
    );

    # Start FlashCopy
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/startfcmap/789$},
        token       => $test_token,
        response    => {
            json => {}
        },
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::clone_volume(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        $source_base,
        $target_vmid
    );

    is($result, $new_name, 'Returns new volume name');

    MockLWP::verify_all_requests('Linked clone: get size, mkvolume, mkfcmap, prestart, start');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: clone_volume - full clone from regular volume
# ============================================================================
subtest 'clone_volume - full clone from regular volume' => sub {

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    # Mock _find_free_diskname
    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_find_free_diskname', sub { return $new_name; });

    # Get source volume size
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$source_volname$},
        token       => $test_token,
        body        => { bytes => 1 },
        response    => {
            json => [{
                id       => '123',
                name     => $source_volname,
                capacity => 20 * 1024 * 1024 * 1024,
            }]
        },
    );

    # Create target volume
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkvolume$},
        token       => $test_token,
        body        => {
            name => $new_name,
            pool => 'pool-pvc-01',
            size => 20 * 1024 * 1024 * 1024,
            unit => 'b',
            thin  => JSON::true,
        },
        response    => {
            json => { id => '456' }
        },
    );

    # Create FlashCopy mapping (copyrate=100 for full clone)
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkfcmap$},
        token       => $test_token,
        body        => {
            source   => $source_volname,
            target   => $new_name,
            copyrate => 100,
        },
        response    => {
            json => { id => '790' }
        },
    );

    # Pre-start FlashCopy
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/prestartfcmap/790$},
        token       => $test_token,
        response    => {
            json => {}
        },
    );

    # Start FlashCopy
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/startfcmap/790$},
        token       => $test_token,
        response    => {
            json => {}
        },
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::clone_volume(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        $source_volname,
        $target_vmid
    );

    is($result, $new_name, 'Returns new volume name');

    MockLWP::verify_all_requests('Full clone: get size, mkvolume, mkfcmap, prestart, start');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: clone_volume - base detection by name
# ============================================================================
subtest 'clone_volume - base detection by name' => sub {

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_find_free_diskname', sub { return $new_name; });

    my $source_base = 'base-999-disk-1';

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$source_base$},
        token       => $test_token,
        body        => { bytes => 1 },
        response    => {
            json => [{ capacity => 5 * 1024 * 1024 * 1024 }]
        },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkvolume$},
        token       => $test_token,
        response    => { json => {} },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkfcmap$},
        token       => $test_token,
        response    => { json => { id => '111' } },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/prestartfcmap/111$},
        token       => $test_token,
        response    => { json => {} },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/startfcmap/111$},
        token       => $test_token,
        response    => { json => {} },
    );

    my $result = PVE::Storage::Custom::IBMFlashSystem::Volume::clone_volume(
        'PVE::Storage::Custom::IBMFlashSystem',
        \%test_scfg,
        $test_storeid,
        $source_base,
        $target_vmid
    );

    is($result, $new_name, 'Clone from base- prefix succeeds');

    MockLWP::verify_all_requests('Used copyrate=0 for base template');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: clone_volume - cleanup on FlashCopy failure
# ============================================================================
subtest 'clone_volume - cleanup on FlashCopy failure' => sub {
    plan tests => 2;

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_find_free_diskname', sub { return $new_name; });
    $volume_mock->mock('_get_vdisk_id', sub { return '456'; });

    my $source_base = 'base-100-disk-0';

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$source_base$},
        token       => $test_token,
        body        => { bytes => 1 },
        response    => {
            json => [{ capacity => 10 * 1024 * 1024 * 1024 }]
        },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkvolume$},
        token       => $test_token,
        response    => { json => { id => '456' } },
    );

    # FlashCopy creation fails
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkfcmap$},
        token       => $test_token,
        response    => {
            code => 500,
            raw  => 'CMMVC5879E The FlashCopy mapping cannot be created',
        },
    );

    # Cleanup: remove target volume
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/rmvdisk/456$},
        token       => $test_token,
        response    => { json => {} },
    );

    throws_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::clone_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $source_base,
            $target_vmid
        );
    } qr/Failed to create FlashCopy mapping for clone/, 'Dies on FlashCopy failure with cleanup';

    MockLWP::verify_all_requests('Made cleanup call after FlashCopy failure');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: clone_volume - FlashCopy returns numeric ID
# ============================================================================
subtest 'clone_volume - FlashCopy returns numeric ID' => sub {

    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_find_free_diskname', sub { return $new_name; });
    # Mock _get_vdisk_id to avoid lsvdisk call that triggers cleanup
    $volume_mock->mock('_get_vdisk_id', sub { return '456'; });

    my $source_base = 'base-100-disk-0';

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$source_base$},
        token       => $test_token,
        body        => { bytes => 1 },
        response    => {
            json => [{ capacity => 10 * 1024 * 1024 * 1024 }]
        },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkvolume$},
        token       => $test_token,
        response    => { json => {} },
    );

    # FlashCopy returns numeric ID (not object) - USE PROPER JSON FORMAT
    # Actually, just test with proper JSON object {id => 999}
    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/mkfcmap$},
        token       => $test_token,
        response    => {
            json => { id => 999 }  # Proper format
        },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/prestartfcmap/999$},
        token       => $test_token,
        response    => { json => {} },
    );

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/startfcmap/999$},
        token       => $test_token,
        response    => { json => {} },
    );

    lives_ok {
        PVE::Storage::Custom::IBMFlashSystem::Volume::clone_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $source_base,
            $target_vmid
        );
    } 'Handles numeric FlashCopy ID';

    MockLWP::verify_all_requests('Used numeric fcmap_id correctly');
    MockLWP::reset_mock();
    done_testing();
};

# ============================================================================
# Test: clone_volume - source volume not found (BUG: code doesn't die)
# ============================================================================
subtest 'clone_volume - source volume not found' => sub {
    setup_test_env($test_token);
    MockLWP::setup_lwp_mock();

    my $volume_mock = Test::MockModule->new('PVE::Storage::Custom::IBMFlashSystem::Volume');
    $volume_mock->mock('_find_free_diskname', sub { return $new_name; });

    MockLWP::expect_request(
        method      => 'POST',
        url_pattern => qr{/rest/lsvdisk/$source_volname$},
        token       => $test_token,
        response    => {
            json => []  # Empty = not found
        },
    );

    # BUG: Code continues with 0 bytes instead of dying
    # Expected behavior: die "Volume '$source_volname' not found"
    # Actual behavior: continues to mkvolume with size=0
    my $result = eval {
        PVE::Storage::Custom::IBMFlashSystem::Volume::clone_volume(
            'PVE::Storage::Custom::IBMFlashSystem',
            \%test_scfg,
            $test_storeid,
            $source_volname,
            $target_vmid
        );
    };

    like($@, qr/mkvolume/i, 'Code continues to mkvolume even when source not found (BUG)');

    MockLWP::verify_all_requests('Made lsvdisk call (BUG: should have died here)');
    MockLWP::reset_mock();
    done_testing();
};

done_testing();
