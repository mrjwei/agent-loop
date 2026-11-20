# make install [PREFIX=~/.local]   copies the package to $(PREFIX)/share/agent-loop and links $(PREFIX)/bin/agent-loop
# make uninstall | make test | make lint (needs shellcheck)
PREFIX ?= $(HOME)/.local
SHARE = $(PREFIX)/share/agent-loop
FILES = bin lib libexec prompts templates VERSION

.PHONY: install uninstall test lint

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

# jq before 1.7 rejects a keyword as a variable name (`... as $$as`): a compile error that newer jq (and CI) accepts
JQ_KEYWORDS = as|if|then|elif|else|end|def|reduce|foreach|try|catch|label|import|include|and|or|not|__loc__

lint:
	shellcheck -S warning bin/agent-loop lib/common.sh libexec/*.sh test/run.sh
	@! grep -nE 'as \$$($(JQ_KEYWORDS))\b|def [a-z_]+\([^)]*\$$($(JQ_KEYWORDS))[;)]' bin/agent-loop lib/common.sh libexec/*.sh \
	  || { echo "lint: a jq variable above is named after a keyword, which jq < 1.7 cannot compile" >&2; exit 1; }
