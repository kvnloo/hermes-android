import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Android publishes chat, voice and sessions launcher shortcuts',
    () async {
      final manifest = await File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsString();
      final shortcuts = await File(
        'android/app/src/main/res/xml/shortcuts.xml',
      ).readAsString();

      expect(manifest, contains('android.app.shortcuts'));
      expect(manifest, contains('@xml/shortcuts'));
      final debugShortcuts = await File(
        'android/app/src/debug/res/xml/shortcuts.xml',
      ).readAsString();
      expect(
        debugShortcuts,
        shortcuts.replaceAll(
          'io.github.kvnloo.z0agent',
          'io.github.kvnloo.z0agent.dev',
        ),
      );
      expect(RegExp(r'<shortcut\s').allMatches(shortcuts), hasLength(3));
      for (final (id, action) in [
        ('new_quick_chat', 'QUICK_CHAT'),
        ('live_voice', 'LIVE_VOICE'),
        ('sessions', 'SESSIONS'),
      ]) {
        expect(shortcuts, contains('android:shortcutId="$id"'));
        expect(
          shortcuts,
          contains('com.hermesagent.hermes_android.action.$action'),
        );
      }
    },
  );

  test('MainActivity forwards cold and warm shortcut launches', () async {
    final source = await File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/MainActivity.kt',
    ).readAsString();

    expect(source, contains('getInitialLaunchAction'));
    expect(source, contains('launchAction'));
    expect(source, contains('AndroidEntry.actions::contains'));
    final actions = await File(
      'android/app/src/main/kotlin/com/hermesagent/hermes_android/AndroidEntry.kt',
    ).readAsString();
    for (final action in ['QUICK_CHAT', 'LIVE_VOICE', 'SESSIONS']) {
      expect(actions, contains(action));
    }
  });
}
