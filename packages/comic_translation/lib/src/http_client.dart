import 'package:dio/dio.dart';

/// App composition installs the shared network-lane adapter before initialization.
abstract final class ComicTranslationHttp {
  static HttpClientAdapter Function()? adapterFactory;

  static Dio create([BaseOptions? options]) {
    final client = Dio(options);
    final adapter = adapterFactory;
    if (adapter != null) client.httpClientAdapter = adapter();
    return client;
  }
}
