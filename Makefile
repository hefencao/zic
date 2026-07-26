.PHONY: check bootstrap test

check:
	./tool/check.sh

bootstrap:
	./tool/bootstrap_platforms.sh

test:
	./tool/check.sh --require-toolchains
