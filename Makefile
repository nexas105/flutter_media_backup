# media_backup — developer Makefile
#
# Usage:
#   make help               list all targets
#   make ios:dev            full dev cycle: clean → pods → run on first device
#   make ios:sim            run on first booted simulator (no signing needed)
#   make ios:open           open Runner.xcworkspace in Xcode
#   make ios:build          build .app for device (no signing)
#   make ios:clean          deep clean iOS artifacts
#   make ios:pods           reinstall CocoaPods
#   make analyze            flutter analyze (plugin + example)
#   make test               run dart tests
#   make doctor             flutter doctor -v
#
# Note: targets contain `:` which is normally a Make separator, so they're
# escaped (`ios\:dev`). Type them on the command line without the backslash:
# `make ios:dev`.

PLUGIN_DIR := $(CURDIR)
EXAMPLE_DIR := $(PLUGIN_DIR)/example
IOS_DIR := $(EXAMPLE_DIR)/ios
WORKSPACE := $(IOS_DIR)/Runner.xcworkspace
ENV_FILE := $(EXAMPLE_DIR)/.env

# Resolve first physical iOS device id (excluding simulators).
DEVICE_ID = $(shell flutter devices --machine 2>/dev/null \
	| python3 -c "import json,sys; ds=json.load(sys.stdin); \
ph=[d['id'] for d in ds if d.get('targetPlatform','').startswith('ios') and not d.get('emulator', False)]; \
print(ph[0] if ph else '')")

# Resolve first booted iOS simulator id.
SIM_ID = $(shell xcrun simctl list devices booted --json 2>/dev/null \
	| python3 -c "import json,sys; data=json.load(sys.stdin); \
ids=[d['udid'] for k,v in data['devices'].items() if 'iOS' in k for d in v if d.get('state')=='Booted']; \
print(ids[0] if ids else '')")

.DEFAULT_GOAL := help
.PHONY: help analyze test doctor env\:check env\:init ios\:dev ios\:sim ios\:open ios\:build ios\:clean ios\:pods

help:
	@printf "\n  \033[1mmedia_backup — make targets\033[0m\n\n"
	@printf "  \033[36m%-14s\033[0m %s\n" "ios:dev"   "clean → pods → run on first physical device (with .env)"
	@printf "  \033[36m%-14s\033[0m %s\n" "ios:sim"   "run on first booted simulator (with .env)"
	@printf "  \033[36m%-14s\033[0m %s\n" "ios:open"  "open Runner.xcworkspace in Xcode"
	@printf "  \033[36m%-14s\033[0m %s\n" "ios:build" "build .app for device (no signing)"
	@printf "  \033[36m%-14s\033[0m %s\n" "ios:clean" "deep clean iOS build artifacts"
	@printf "  \033[36m%-14s\033[0m %s\n" "ios:pods"  "reinstall CocoaPods"
	@printf "  \033[36m%-14s\033[0m %s\n" "env:init"  "scaffold example/.env from .env.example"
	@printf "  \033[36m%-14s\033[0m %s\n" "env:check" "show keys loaded from .env (root or example/, masked)"
	@printf "  \033[36m%-14s\033[0m %s\n" "analyze"   "flutter analyze"
	@printf "  \033[36m%-14s\033[0m %s\n" "test"      "run dart tests"
	@printf "  \033[36m%-14s\033[0m %s\n" "doctor"    "flutter doctor -v"
	@printf "\n"

env\:init: ## scaffold example/.env from .env.example
	@if [ -f $(ENV_FILE) ]; then \
		echo "✖ $(ENV_FILE) already exists. Refusing to overwrite."; \
		exit 1; \
	fi
	@cp $(EXAMPLE_DIR)/.env.example $(ENV_FILE)
	@echo "✓ Created $(ENV_FILE) — fill in real values before running."

env\:check: ## list .env keys (values masked)
	@FILE=""; \
	if [ -f $(ENV_FILE) ]; then FILE=$(ENV_FILE); \
	elif [ -f $(PLUGIN_DIR)/.env ]; then FILE=$(PLUGIN_DIR)/.env; \
	else echo "✖ no .env found at $(ENV_FILE) or $(PLUGIN_DIR)/.env"; exit 1; fi; \
	echo "Loaded keys from $$FILE:"; \
	awk -F= '/^[[:space:]]*[A-Z_][A-Z0-9_]*=/ { \
		k=$$1; gsub(/^[[:space:]]+|[[:space:]]+$$/, "", k); \
		v=substr($$0, index($$0, "=")+1); \
		gsub(/^[[:space:]]+|[[:space:]]+$$/, "", v); \
		gsub(/^"|"$$/, "", v); \
		mask=length(v)>0 ? "set ("length(v)" chars)" : "(empty)"; \
		printf "  \033[36m%-25s\033[0m %s\n", k, mask; \
	}' "$$FILE"

doctor: ## flutter doctor -v
	flutter doctor -v

analyze: ## flutter analyze (plugin + example)
	flutter analyze

test: ## run dart tests
	flutter test

ios\:dev: ## clean → pods → run on first physical device
	@echo "▶ Cleaning…"
	@cd $(EXAMPLE_DIR) && flutter clean >/dev/null
	@rm -rf $(IOS_DIR)/Pods $(IOS_DIR)/Podfile.lock $(IOS_DIR)/.symlinks
	@echo "▶ Resolving Flutter packages…"
	@cd $(EXAMPLE_DIR) && flutter pub get >/dev/null
	@echo "▶ Installing CocoaPods…"
	@cd $(IOS_DIR) && pod install --repo-update >/dev/null
	@if [ -z "$(DEVICE_ID)" ]; then \
		echo "✖ No physical iOS device connected."; \
		echo "  Tip: \`make ios:sim\` to run on a simulator instead."; \
		exit 1; \
	fi
	@echo "▶ Running on device $(DEVICE_ID)"
	@sh $(PLUGIN_DIR)/.make/flutter_run.sh $(EXAMPLE_DIR) $(ENV_FILE) $(DEVICE_ID)

ios\:sim: ## run on first booted simulator
	@if [ -z "$(SIM_ID)" ]; then \
		echo "✖ No booted iOS simulator. Boot one first:"; \
		echo "  open -a Simulator"; \
		exit 1; \
	fi
	@echo "▶ Resolving packages…"
	@cd $(EXAMPLE_DIR) && flutter pub get >/dev/null
	@echo "▶ Running on simulator $(SIM_ID)"
	@sh $(PLUGIN_DIR)/.make/flutter_run.sh $(EXAMPLE_DIR) $(ENV_FILE) $(SIM_ID)

ios\:open: ## open Runner.xcworkspace in Xcode
	open $(WORKSPACE)

ios\:build: ## build .app (no signing)
	@cd $(EXAMPLE_DIR) && flutter build ios --no-codesign --debug

ios\:clean: ## deep clean iOS build artifacts
	@cd $(EXAMPLE_DIR) && flutter clean
	@rm -rf $(IOS_DIR)/Pods $(IOS_DIR)/Podfile.lock $(IOS_DIR)/.symlinks
	@rm -rf $(EXAMPLE_DIR)/build
	@echo "✓ Clean complete"

ios\:pods: ## reinstall CocoaPods (after adding/removing plugins)
	@cd $(IOS_DIR) && pod install --repo-update
