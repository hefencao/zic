.PHONY: check bootstrap test analyze dart-test flutter-test android-apk android-native webp-check

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

webp-check:
	./tool/check_webp.sh
