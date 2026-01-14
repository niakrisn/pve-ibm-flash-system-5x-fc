# IBM FlashSystem 5.x FC Plugin - Makefile
PACKAGE_NAME := pve-ibm-fs5x-fc-plugin
PLUGIN_FILE := PVE/Storage/Custom/IBMFlashSystem.pm
VERSION := $(shell head -n 1 debian/changelog | cut -d'(' -f2 | cut -d')' -f1)

.PHONY: all package package-docker clean install-plugin install-package install
.PHONY: patch-check tools-image

TEST_HOST ?= 10.4.0.122
SSH_KEY ?= $(HOME)/.ssh/id_ed25519
PATCH_VERSIONS ?= pkg-versions.txt
SKIP_SSH ?= 0

all: package

# Build deb packages locally using dpkg-buildpackage
package:
	@echo "Building Debian packages..."
	@mkdir -p output
	debuild -us -uc -b
	mv ../$(PACKAGE_NAME)_*.deb output/
	mv ../$(PACKAGE_NAME)_*.changes output/
	mv ../$(PACKAGE_NAME)_*.buildinfo output/
	@echo "✓ Built: output/"

# Build a single tools image for build + patch workflows
tools-image:
	@docker build -t $(PACKAGE_NAME)-tools -f Dockerfile --build-arg SUITE=trixie .

docker-image: tools-image

package-docker: tools-image
	@echo "Building packages in Docker..."
	@mkdir -p output
	@docker run --rm -v "$$(pwd):/build/source" -w /build/source \
		$(PACKAGE_NAME)-tools bash -c \
		"debuild -us -uc -b && \
		 mkdir -p /build/source/output && \
		 mv ../$(PACKAGE_NAME)* /build/source/output/"
	@echo "✓ Built: output/"

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
	LATEST_DEB=$$(ls -t output/$(PACKAGE_NAME)_*.deb | head -n 1); \
	scp $$LATEST_DEB root@$$host:/tmp/ && \
	DEB_NAME=$$(basename $$LATEST_DEB); \
	ssh root@$$host "dpkg -i /tmp/$$DEB_NAME"
	@echo "✓ Package installed"

install: install-package

patch-check:
	@set -e; \
	if [ "$(SKIP_SSH)" = "1" ]; then \
		echo "SKIP_SSH=1, using existing $(PATCH_VERSIONS)"; \
	elif ssh -i $(SSH_KEY) root@$(TEST_HOST) \
		"dpkg-query -W -f='${Package} ${Version}\n' qemu-server libpve-storage-perl pve-manager" > $(PATCH_VERSIONS); then \
		echo "Updated $(PATCH_VERSIONS) from $(TEST_HOST)"; \
	elif [ -f "$(PATCH_VERSIONS)" ]; then \
		echo "SSH unavailable, using existing $(PATCH_VERSIONS)"; \
	else \
		echo "ERROR: SSH unavailable and $(PATCH_VERSIONS) is missing" >&2; \
		exit 1; \
	fi; \
	$(MAKE) tools-image; \
	./scripts/patch-apply-docker-check.sh --versions $(PATCH_VERSIONS)

clean:
	rm -rf output
	rm -rf debian/pve-ibm-fs5x-fc-plugin
	rm -rf debian/pve-ibm-fs5x-fc-plugin-tests
	rm -rf debian/.debhelper
	rm -f debian/files
	rm -f debian/*.substvars
	rm -f debian/*.debhelper*
	rm -f ../$(PACKAGE_NAME)_*
