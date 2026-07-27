APP_NAME := HAOS
DEST_DIR ?= /Applications
# Kept out of the repo: it may live in iCloud Drive, which both breaks
# codesign and would sync every build artifact. See scripts/install.sh.
BUILD_DIR := $(HOME)/Library/Caches/HAOS

.PHONY: help build install dmg uninstall clean

help:
	@echo "make build      Build Release, ad-hoc signed (no install)"
	@echo "make install    Build and install to $(DEST_DIR), then relaunch"
	@echo "make dmg        Build the release .dmg in $(BUILD_DIR)"
	@echo "make uninstall  Remove $(DEST_DIR)/$(APP_NAME).app (leaves VM data)"
	@echo "make clean      Delete build products in $(BUILD_DIR)"

build:
	@./scripts/install.sh --build-only

install:
	@./scripts/install.sh

dmg:
	@./scripts/make-dmg.sh

uninstall:
	@if pgrep -x $(APP_NAME) >/dev/null 2>&1; then \
		echo "Quitting $(APP_NAME)…"; \
		osascript -e 'quit app "$(APP_NAME)"' >/dev/null 2>&1 || true; \
		sleep 3; \
	fi
	rm -rf "$(DEST_DIR)/$(APP_NAME).app"
	@echo "Removed. VM state in ~/Library/HAOS and"
	@echo "~/Library/Application Support/HAOS was left in place."

clean:
	rm -rf $(BUILD_DIR)
