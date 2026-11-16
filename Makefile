.PHONY: build install test test-unit test-slow test-attended test-refresh

# TOOL=notes (or TOOL=notes,calendar) limits the live groups to those tools.
tool_arg = $(if $(TOOL),--tool $(TOOL))

build:
	bin/build

install:
	bin/install-skill

# Unit tests, then read-only checks against this Mac's real data.
test:
	bin/check $(tool_arg)

# Fixtures only. This is what pre-commit runs.
test-unit:
	bin/check --unit

# Also create, read back and remove labeled test data.
test-slow:
	bin/check --slow $(tool_arg)

# Also run tests that put a window or dialog in front of you.
test-attended:
	bin/check --attended $(tool_arg)

# Re-discover the items the read-only group remembers. Only after confirming the data really changed.
test-refresh:
	bin/check --refresh $(tool_arg)
