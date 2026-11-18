# Build Intent OS in an x86_64 Arch container. Needs Docker; on non-x86 hosts
# Docker also needs qemu-user binfmt, so CI is the normal place to build.
ARCHIVE_DATE ?= $(shell cat channel/archive-date)
BUILD_ID ?= $(shell date -u +%Y%m%d%H%M)-local
IMAGE ?= archlinux:base-devel
ISO = $(firstword $(wildcard out/iso/*-x86_64.iso))
ISO_ARM64 = $(firstword $(wildcard out/iso/*-aarch64.iso))

DOCKER = docker run --rm --privileged --platform linux/amd64 \
	-v "$(CURDIR)":/src -w /src \
	-e ARCHIVE_DATE="$(ARCHIVE_DATE)" -e BUILD_ID="$(BUILD_ID)" \
	-e INTENT_OS_SIGNING_KEY -e HOST_UID="$(shell id -u)" \
	$(IMAGE) bash build/in-container.sh

# arm64: an Arch Linux ARM rootfs imported as a Docker image (aarch64 host).
ALARM_IMAGE ?= intent-os-alarm:latest
ALARM_ROOTFS ?= http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz

DOCKER_ARM = docker run --rm --privileged --platform linux/arm64 \
	-v "$(CURDIR)":/src -v /dev:/dev -w /src \
	-e ARCHIVE_DATE="$(ARCHIVE_DATE)" -e BUILD_ID="$(BUILD_ID)" \
	-e INTENT_OS_SIGNING_KEY -e HOST_UID="$(shell id -u)" \
	$(ALARM_IMAGE) bash build/in-container.sh

.PHONY: packages image smoke lint clean alarm-image image-arm64 image-asahi smoke-arm64

packages:
	$(DOCKER) packages

image:
	$(DOCKER) all

smoke:
	tests/smoke.sh "$(ISO)" out/smoke

alarm-image:
	docker image inspect $(ALARM_IMAGE) >/dev/null 2>&1 || \
		curl -fsSL $(ALARM_ROOTFS) | docker import --platform linux/arm64 - $(ALARM_IMAGE)

image-arm64: alarm-image
	$(DOCKER_ARM) all

# Apple silicon image for the Asahi installer (after image-arm64 built out/repo).
image-asahi: alarm-image
	$(DOCKER_ARM) asahi

smoke-arm64:
	tests/smoke.sh "$(ISO_ARM64)" out/smoke

lint:
	shellcheck -x build/*.sh tests/*.sh asahi/*.sh iso/airootfs/usr/local/bin/intent-os-install \
		$$(grep -rlE '^#!/bin/(ba)?sh' packages/*/files)

clean:
	rm -rf out
