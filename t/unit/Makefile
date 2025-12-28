# Unit Tests for IBM FlashSystem Proxmox Plugin

PERL = perl
PROVE = prove
PROVE_OPTS = -I t/unit/lib -I PVE/Storage/Custom

.PHONY: help test all client volume snapshot clean

help:
	@echo "Unit Tests for IBM FlashSystem Plugin"
	@echo ""
	@echo "Targets:"
	@echo "  make test         - Run all unit tests"
	@echo "  make client       - Run Client.pm tests"
	@echo "  make volume       - Run Volume.pm tests"
	@echo "  make verbose      - Run with verbose output"
	@echo "  make clean        - Clean test artifacts"
	@echo ""

test: all

all:
	$(PROVE) $(PROVE_OPTS) t/unit/volume/*.t

volume:
	$(PROVE) $(PROVE_OPTS) t/unit/volume/*.t

verbose:
	$(PROVE) $(PROVE_OPTS) -v t/unit/volume/*.t

clean:
	rm -f /tmp/test-ibm-*.token
	find t/unit -name "*.bak" -delete 2>/dev/null || true
