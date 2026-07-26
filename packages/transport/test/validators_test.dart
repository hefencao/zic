import 'package:test/test.dart';
import 'package:transport/transport.dart';

void main() {
  test('parses optional last-modified without an unchecked cast', () {
    final validators = Validators.fromJson(<String, Object?>{
      'etag': 'v1',
      'lastModified': '2026-07-26T00:00:00.000Z',
    });

    expect(validators.etag, 'v1');
    expect(validators.lastModified, DateTime.utc(2026, 7, 26));
  });

  test('rejects a non-string last-modified value', () {
    expect(
      () => Validators.fromJson(<String, Object?>{'lastModified': 1}),
      throwsFormatException,
    );
  });
}
