VERSION := $(shell cat VERSION 2>/dev/null || echo "1.0.0")
PVE_VERSION := 9
PACKAGE_NAME := pve-ibm-fs5x-fc-plugin
PLUGIN_FILE := PVE/Storage/Custom/IBMFlashSystem.pm

.PHONY: all package package-docker clean install-plugin install-package install

all: package

# Build deb package using Docker (simple, no debhelper)
package-docker:
	@echo "Building $(PACKAGE_NAME)_$(VERSION)_all.deb in Docker..."
	@mkdir -p output
	@docker run --rm -v "$$(pwd):/build" -w /build \
		debian:bookworm bash -c \
		"apt-get update -qq && apt-get install -y dpkg patch perl && \
		 bash scripts/build-deb.sh"
	@echo ""
	@ls -la output/*.deb 2>/dev/null || echo "Package built in output/"
	@echo "✓ Built: output/$(PACKAGE_NAME)_$(VERSION)_all.deb"

# Install plugin only (for development)
install-plugin:
	@echo "Installing plugin to test server..."
	@read -p "SSH host (default: 10.4.0.122): " host; \
	host=$${host:-10.4.0.122}; \
	scp $(PLUGIN_FILE) root@$$host:/tmp/IBMFlashSystem.pm && \
	ssh root@$$host "cp /tmp/IBMFlashSystem.pm /usr/share/perl5/PVE/Storage/Custom/ && \
	                 perl -c /usr/share/perl5/PVE/Storage/Custom/IBMFlashSystem.pm && \
	                 systemctl restart pvedaemon"
	@echo "✓ Plugin installed"

# Install deb package
install-package: package-docker
	@echo "Installing package..."
	@read -p "SSH host (default: 10.4.0.122): " host; \
	host=$${host:-10.4.0.122}; \
	scp output/$(PACKAGE_NAME)_$(VERSION)_all.deb root@$$host:/tmp/ && \
	ssh root@$$host "dpkg -i /tmp/$(PACKAGE_NAME)_$(VERSION)_all.deb"
	@echo "✓ Package installed"

# Install both plugin and package
install: install-package

clean:
	dh clean || true
	rm -f ../$(PACKAGE_NAME)_*.deb ../$(PACKAGE_NAME)_*.changes ../$(PACKAGE_NAME)_*.buildinfo
	rm -f ../$(PACKAGE_NAME)_*.tar.gz ../$(PACKAGE_NAME)_*.dsc
	rm -rf output
