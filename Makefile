# imagine — Makefile
# Quick dev install:  make install   (builds binary + installs skill)

# ----- configurable paths (override on the command line) -----------------
PREFIX      ?= $(HOME)/.local
BINDIR      ?= $(PREFIX)/bin
AGENTS_DIR  ?= $(HOME)/.agents
SKILL_DIR   ?= $(AGENTS_DIR)/skills/imagine
OPTIMIZE    ?= ReleaseFast

ZIG         ?= zig
BIN_NAME    := imagine
BUILD_BIN   := zig-out/bin/$(BIN_NAME)

.DEFAULT_GOAL := build

# ----- build / test ------------------------------------------------------
.PHONY: build
build: ## Build the optimized binary
	$(ZIG) build -Doptimize=$(OPTIMIZE)

.PHONY: debug
debug: ## Build a debug binary
	$(ZIG) build

.PHONY: test
test: ## Run unit tests
	$(ZIG) build test

.PHONY: run
run: ## Build & run (use ARGS="generate -m ... -p ...")
	$(ZIG) build run -- $(ARGS)

.PHONY: fmt
fmt: ## Format all Zig sources
	$(ZIG) fmt build.zig src

.PHONY: check
check: fmt test ## Format + test

# ----- install / uninstall ----------------------------------------------
.PHONY: install
install: build install-bin install-skill ## Build, then install binary + skill
	@echo ""
	@echo "imagine installed."
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; \
	  *) echo "NOTE: $(BINDIR) is not on PATH. Add to your shell rc:"; \
	     echo "      export PATH=\"$(BINDIR):\$$PATH\"";; esac

.PHONY: install-bin
install-bin: build ## Install only the binary
	@mkdir -p "$(BINDIR)"
	install -m 0755 "$(BUILD_BIN)" "$(BINDIR)/$(BIN_NAME)"
	@echo "binary -> $(BINDIR)/$(BIN_NAME)"

.PHONY: install-skill
install-skill: ## Install only the skill into ~/.agents/skills/imagine
	@mkdir -p "$(SKILL_DIR)"
	cp -R skills/imagine/. "$(SKILL_DIR)/"
	@echo "skill  -> $(SKILL_DIR)"

.PHONY: uninstall
uninstall: ## Remove installed binary and skill
	rm -f "$(BINDIR)/$(BIN_NAME)"
	rm -rf "$(SKILL_DIR)"
	@echo "uninstalled $(BIN_NAME) and skill"

# ----- housekeeping ------------------------------------------------------
.PHONY: clean
clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
