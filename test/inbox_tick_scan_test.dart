import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'activity_tick_scan_test.dart' show checkPassiveTickScan;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Inbox ticks reuse the metadata scan; manual refresh is fresh', (
    tester,
  ) async {
    await checkPassiveTickScan(tester, inbox: true);
  });
}
