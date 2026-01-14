#!/usr/bin/env perl
# Scenario 9: Linked Clone Disallowed
# Tests: template creation -> linked clone attempt must fail

use strict;
use warnings;
use Test::More;
use lib qw(t/unit/lib t/integration/lib);

use TestEnv;
use VMScenario qw(create_q35_vm convert_to_template cleanup_vm);
use StateVerifier;
use StorageHelpers;
use VMHelpers qw(run_cmd_checked run_cmd_expect_fail run_shell_checked);
use TestAssert qw(ok_or_bail);
use FCHelpers qw(skip_without_fc);

# Skip if no FC connectivity
skip_without_fc('FC connectivity required');

my $env = TestEnv->setup();
my $template_vmid = 9995;
my $clone_vmid = 9994;

subtest 'Linked clone is forbidden' => sub {

    # PRE-TEST: Verify environment is clean
    diag("Verifying environment is clean before test...");
    TestEnv::verify_clean_environment($env, [9995, 9994], ['vm-9995-disk', 'base-9995-disk', 'vm-9994-disk']);
    diag("Environment is clean. Starting test...");

    # Step 1: Create VM with q35 + EFI + 1 SCSI disk (no cloud-init)
    diag("Creating VM $template_vmid with q35 + EFI + 1 SCSI disk...");
    my $scsi_disks = [
        { size => '10G', slot => 0 },
    ];
    ok_or_bail(create_q35_vm($env, $template_vmid, $scsi_disks, { cloudinit => 0 }),
        "VM $template_vmid created", { env => $env, vmid => $template_vmid });

    my $vm_disks = ["vm-$template_vmid-disk-0", "vm-$template_vmid-disk-1"];
    ok_or_bail(StateVerifier::verify_created($env, $template_vmid, $vm_disks), "VM $template_vmid is CREATED", { env => $env, vmid => $template_vmid, disks => $vm_disks });

    # Step 2: Convert to template (base-*)
    diag("Converting VM $template_vmid to template...");
    run_cmd_checked("qm template $template_vmid", 'qm', 'template', $template_vmid, { env => $env, vmid => $template_vmid });

    my $base_disks = ["base-$template_vmid-disk-0", "base-$template_vmid-disk-1"];
    ok_or_bail(StateVerifier::verify_template($env, $template_vmid, $base_disks), "VM $template_vmid is TEMPLATE", { env => $env, vmid => $template_vmid, disks => $base_disks });

    # Step 3: Attempt linked clone (must fail)
    diag("Attempting linked clone from template $template_vmid to $clone_vmid (must fail)...");
    ok_or_bail(run_cmd_expect_fail("qm clone $template_vmid $clone_vmid (linked)", 'qm', 'clone', $template_vmid, $clone_vmid, { env => $env, vmid => $clone_vmid }),
        "Linked clone is rejected", { env => $env, vmid => $clone_vmid });

    # Step 4: Verify no clone config and no clone volumes created
    run_shell_checked("qm config $clone_vmid (expect missing)",
        "qm config $clone_vmid 2>/dev/null && exit 1 || exit 0", { env => $env, vmid => $clone_vmid });

    my $clone_disks = ["vm-$clone_vmid-disk-0", "vm-$clone_vmid-disk-1"];
    for my $disk (@$clone_disks) {
        ok_or_bail(!StorageHelpers::volume_exists($env, $disk), "Storage: Clone volume $disk was not created", { env => $env, vmid => $clone_vmid, disks => [$disk] });
    }
};

# Cleanup
END {
    cleanup_vm($clone_vmid);
    cleanup_vm($template_vmid);
}

done_testing();
