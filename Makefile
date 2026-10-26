.DEFAULT_GOAL := all
SHELL    := /bin/sh
SDK      ?= $(shell xcrun --sdk iphoneos --show-sdk-path)
SDK_VERSION ?= $(shell xcrun --sdk iphoneos --show-sdk-version)
TARGET   ?= arm64-apple-ios15.0
SWIFT    ?= swift
LDID     ?= ldid
INSTALL  ?= /var/jb/usr/bin/icli

BUILD    := .build
BIN      := $(BUILD)/icli
ENT      := Resources/icli.entitlements

ifeq ($(DEBUG),1)
CONFIGURATION := debug
else
CONFIGURATION := release
endif

SWIFT_FLAGS := --configuration $(CONFIGURATION) --triple $(TARGET) --sdk $(SDK) \
	--scratch-path $(BUILD)/swiftpm --product icli --force-resolved-versions

TVOS_SDK         ?= $(shell xcrun --sdk appletvos --show-sdk-path)
TVOS_SDK_VERSION ?= $(shell xcrun --sdk appletvos --show-sdk-version)
TVOS_TARGET      ?= arm64-apple-tvos15.0
TVOS_BIN         := $(BUILD)/icli-tvos
TVOS_STUBS       := $(BUILD)/tvos-stubs
TVOS_FLAGS := --configuration $(CONFIGURATION) --triple $(TVOS_TARGET) --sdk $(TVOS_SDK) \
	--scratch-path $(BUILD)/swiftpm --product icli --force-resolved-versions \
	-Xcc -F$(TVOS_STUBS) -Xswiftc -F$(TVOS_STUBS) -Xlinker -F$(TVOS_STUBS)

.PHONY: all debug resolve install clean deb deb-rootless deb-roothide deb-rootful tvos deb-tvos

all:
	$(SWIFT) build $(SWIFT_FLAGS)
	cp "$$($(SWIFT) build $(SWIFT_FLAGS) --show-bin-path)/icli" $(BIN)
	# SwiftPM can stamp the triple's version as the SDK too. Frameworks branch
	# on the linked SDK (NSURL's parser, UIKit and Swift runtime behaviour), so
	# the binary says the SDK it was really built with, as 0.8.0 did (sdk 26.5).
	xcrun vtool -set-build-version ios 15.0 $(SDK_VERSION) -replace -output $(BIN) $(BIN)
	$(LDID) -S$(ENT) $(BIN)
	python3 scripts/verify-binary.py

debug:
	$(MAKE) DEBUG=1 all

resolve:
	$(SWIFT) package --scratch-path $(BUILD)/swiftpm resolve

install: all
	sudo mkdir -p $(dir $(INSTALL))
	sudo cp $(BIN) $(INSTALL)
	sudo $(LDID) -S$(ENT) $(INSTALL)

clean:
	rm -rf $(BUILD) packaging/root

deb: all
	./packaging/build-deb.sh rootless

deb-rootless: deb

deb-roothide: all
	./packaging/build-deb.sh roothide

deb-rootful: all
	./packaging/build-deb.sh rootful

# tvOS: the same sources against the AppleTVOS SDK, as their own binary.
tvos:
	./scripts/tvos-iokit-stub.sh $(TVOS_STUBS)
	$(SWIFT) build $(TVOS_FLAGS)
	cp "$$($(SWIFT) build $(TVOS_FLAGS) --show-bin-path)/icli" $(TVOS_BIN)
	xcrun vtool -set-build-version tvos 15.0 $(TVOS_SDK_VERSION) -replace -output $(TVOS_BIN) $(TVOS_BIN)
	$(LDID) -S$(ENT) $(TVOS_BIN)
	python3 scripts/verify-binary.py --platform tvos

deb-tvos: tvos
	./packaging/build-deb.sh tvos
