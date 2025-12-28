# IBM FlashSystem Storage Plugin - Integration Tests

PERL = perl
TEST_HOST = root@10.4.0.122
STORAGE_ID = fs-01
TEST_POOL = pool-pvc-01
TEST_HOSTCLUSTER = pvc-01

.PHONY: help test setup check clean ssh

help:
	@echo "IBM FlashSystem Integration Tests"
	@echo ""
	@echo "Targets:"
	@echo "  make test         - Run all integration tests"
	@echo "  make check        - Quick pre-flight check"
	@echo "  make setup        - Setup test environment"
	@echo "  make clean        - Cleanup test volumes"
	@echo "  make ssh          - SSH to test server"
	@echo "  make status       - Check storage status"
	@echo ""

# Quick pre-flight check
check:
	@echo "=== Checking SSH connectivity ==="
	@ssh $(TEST_HOST) "hostname && uptime"
	@echo ""
	@echo "=== Checking storage plugin ==="
	@ssh $(TEST_HOST) "ls -la /usr/share/perl5/PVE/Storage/Custom/IBMFlashSystem.pm"
	@echo ""
	@echo "=== Checking authentication token ==="
	@ssh $(TEST_HOST) "cat /run/pve-storage-ibm-$(STORAGE_ID).token | head -c 20 && echo '...'"
	@echo ""
	@echo "=== Checking multipathd ==="
	@ssh $(TEST_HOST) "systemctl status multipathd --no-pager | head -5"

# Run all tests
test:
	@echo "=== Running Integration Tests ==="
	@echo ""
	$(PERL) -I t/integration/lib t/integration/volume_lifecycle.t

# Setup test environment
setup:
	@echo "=== Setting up test environment ==="
	@echo "Installing Perl dependencies..."
	ssh $(TEST_HOST) "apt-get install -y libtest-simple-perl libjson-perl 2>/dev/null || true"
	@echo "Done"

# Cleanup test volumes
clean:
	@echo "=== Cleaning up test volumes ==="
	@$(PERL) -I t/integration/lib -e "use TestHelper; TestHelper::cleanup_test_volumes('vm-99999')"
	@echo "Cleanup complete"

# SSH to test server
ssh:
	ssh $(TEST_HOST)

# Check storage status
status:
	@echo "=== Storage Status ==="
	@echo ""
	@echo "--- Token status ---"
	@ssh $(TEST_HOST) "ls -la /run/pve-storage-ibm-*.token"
	@echo ""
	@echo "--- Storage status ---"
	@ssh $(TEST_HOST) "pvesm status"
	@echo ""
	@echo "--- Pool info ---"
	@ssh $(TEST_HOST) "curl -s -k -H \"X-Auth-Token: \\\$(cat /run/pve-storage-ibm-$(STORAGE_ID).token)\" https://10.0.0.222/rest/lsmdiskgrp/Pool1 | jq -r '.capacity, .free_capacity'"
