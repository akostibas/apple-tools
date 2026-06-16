.PHONY: build test install

build:
	bin/build

test:
	swift test

install:
	bin/install-skill
