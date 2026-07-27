.PHONY: check bootstrap test analyze dart-test flutter-test

check:
	./tool/check.sh

bootstrap:
	./tool/bootstrap_platforms.sh

test:
	./tool/check.sh --require-toolchains

analyze:
	./tool/analyze.sh

dart-test:
	./tool/test_dart.sh

flutter-test:
	./tool/test_flutter.sh
