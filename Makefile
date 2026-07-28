.PHONY: clean check bootstrap test analyze dart-test flutter-test android-apk android-native webp-source webp-check rust-test

clean:
	./tool/clean.sh

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

android-apk:
	./tool/build_android.sh release

android-native:
	./tool/build_android_native.sh release

webp-source:
	./tool/fetch_webp.sh

webp-check:
	./tool/check_webp.sh

rust-test:
	./tool/test_rust.sh
