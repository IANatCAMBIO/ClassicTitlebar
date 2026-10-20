SDK ?= macosx
ARCHS ?= arm64 x86_64
OUT ?= ClassicTitlebar.dylib
SRC ?= ClassicTitlebar.m
WHITELIST ?= $(OUT).whitelist
INSTALL_DIR ?= /private/var/ammonia/core/tweaks

all: $(OUT)

$(OUT): $(SRC)
	clang -dynamiclib -fobjc-arc \
		-isysroot "$$(xcrun --sdk $(SDK) --show-sdk-path)" \
		-framework Cocoa -framework QuartzCore \
		-arch arm64 -arch arm64e -arch x86_64 \
		-Wall -Wextra -Wno-unused-parameter \
		-o $(OUT) $(SRC)

# The linker already emits an adhoc,linker-signed signature for arm64/arm64e
# slices. Re-running `codesign --sign -` afterward rewrites that signature
# into a tool-signed form with extra special slots, which the macOS page
# validator rejects on load in some processes (e.g. Slack — SIGKILL "Invalid
# Page" during dlopen). Leave the linker's signature alone.

# The kernel caches the dylib's code signature per-inode. `cp` overwrites
# in place (same inode, new mtime), which leaves the cached cs_mtime out
# of sync with the file's mtime and causes the page validator to reject
# every subsequent dlopen with "Invalid Page" in dmesg. Copy to a sidecar
# path and rename(2) into place so the install path gets a fresh inode —
# the kernel then reads the signature from scratch.
install: $(OUT)
	@if [ -d "$(INSTALL_DIR)" ]; then \
		echo "Using existing $(INSTALL_DIR)"; \
	else \
		mkdir -p $(INSTALL_DIR); \
	fi
	cp $(OUT) "$(INSTALL_DIR)/$(OUT).new"
	mv -f "$(INSTALL_DIR)/$(OUT).new" "$(INSTALL_DIR)/$(OUT)"
	@if [ -f "$(INSTALL_DIR)/$(WHITELIST)" ]; then \
		echo "Keeping existing $(INSTALL_DIR)/$(WHITELIST)"; \
	else \
		cp $(WHITELIST) $(INSTALL_DIR)/; \
		echo "Installed default $(INSTALL_DIR)/$(WHITELIST)"; \
	fi

clean:
	rm -f $(OUT)
