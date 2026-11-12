# make install [PREFIX=~/.local]   copies the package to $(PREFIX)/share/agent-loop and links $(PREFIX)/bin/agent-loop
# make uninstall | make test
PREFIX ?= $(HOME)/.local
SHARE = $(PREFIX)/share/agent-loop
FILES = bin lib libexec prompts templates VERSION

.PHONY: install uninstall test

install:
	rm -rf "$(SHARE)"
	mkdir -p "$(SHARE)" "$(PREFIX)/bin"
	cp -R $(FILES) "$(SHARE)/"
	ln -sf "$(SHARE)/bin/agent-loop" "$(PREFIX)/bin/agent-loop"
	@echo "installed agent-loop $$(cat VERSION) to $(SHARE) (make sure $(PREFIX)/bin is on PATH)"

uninstall:
	rm -f "$(PREFIX)/bin/agent-loop"
	rm -rf "$(SHARE)"

test:
	bash test/run.sh
