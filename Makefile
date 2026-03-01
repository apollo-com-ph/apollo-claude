.PHONY: test test-rust test-shell test-safe-bash-shell syntax-check

test: syntax-check test-rust test-shell test-safe-bash-shell

syntax-check:
	bash -n setup-apollotech-otel-for-claude.sh
	bash -n apollotech-otel-headers.sh
	bash -n bin/apollo-claude
	bash -n install-statusline.sh
	bash -n install-safe-bash-hook.sh
	bash -n bin/recommended-statusline.sh
	sh -n install-apollo-claude-wrapper.sh
	bash -n install_collector.sh

test-rust:
	cd hooks/safe-bash && $(HOME)/.cargo/bin/cargo test

test-shell:
	@for t in tests/test-*.sh; do \
		printf '\n\033[1;34m==>\033[0m Running %s\n' "$$t"; \
		bash "$$t" || exit 1; \
	done

test-safe-bash-shell:
	cd hooks/safe-bash && ./test.sh
