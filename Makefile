DOTFILES_DIR := $(shell pwd)

.PHONY: help link brew all

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

link: ## Create symlinks for all config files
	@bash setup.sh

brew: ## Install Homebrew packages
	brew bundle --file=$(DOTFILES_DIR)/Brewfile

mise-install: ## Install mise-managed tools
	mise install

dump: ## Dump current configs (update Brewfile, extensions, etc.)
	brew bundle dump --file=$(DOTFILES_DIR)/Brewfile --force
	mise list > mise/mise-versions.txt 2>/dev/null || true
	anyenv versions > mise/anyenv-versions.txt 2>/dev/null || true

all: link brew mise-install ## Run full setup
