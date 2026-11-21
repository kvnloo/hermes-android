// Connections sign-in returns through hermes://connections/done (the official
// manifest registers it). The app must claim that link, and Flutter must not
// push it as a named route: the app has none, so a warm return would throw.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const _android = 'http://schemas.android.com/apk/res/android';

void main() {
  final manifest = XmlDocument.parse(
    File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
  );
  final activity = manifest
      .findAllElements('activity')
      .firstWhere(
        (a) => a.getAttribute('name', namespace: _android) == '.MainActivity',
      );
  String? attr(XmlElement e, String name) =>
      e.getAttribute(name, namespace: _android);

  test('MainActivity opens hermes://connections/done from the browser', () {
    final filters = activity.findElements('intent-filter').where(
      (f) => f
          .findElements('data')
          .any(
            (d) =>
                attr(d, 'scheme') == 'hermes' &&
                attr(d, 'host') == 'connections' &&
                attr(d, 'path') == '/done',
          ),
    );
    expect(filters, hasLength(1));
    final filter = filters.single;
    expect(
      filter.findElements('action').map((a) => attr(a, 'name')),
      contains('android.intent.action.VIEW'),
    );
    expect(
      filter.findElements('category').map((c) => attr(c, 'name')),
      containsAll([
        'android.intent.category.DEFAULT',
        'android.intent.category.BROWSABLE',
      ]),
    );
  });

  test('the link is not pushed as a Flutter route', () {
    final flag = activity
        .findElements('meta-data')
        .where((m) => attr(m, 'name') == 'flutter_deeplinking_enabled');
    expect(flag, hasLength(1));
    expect(attr(flag.single, 'value'), 'false');
  });
}
