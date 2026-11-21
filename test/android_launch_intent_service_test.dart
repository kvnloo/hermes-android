import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/android_launch_intent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AndroidLaunchIntentService.channelName);

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final (action, destination) in [
    ('QUICK_CHAT', AndroidEntryDestination.newChat),
    ('LIVE_VOICE', AndroidEntryDestination.liveVoice),
    ('SESSIONS', AndroidEntryDestination.sessions),
    ('UNKNOWN', null),
  ]) {
    test('routes Android action $action on cold and warm delivery', () async {
      final raw = 'com.hermesagent.hermes_android.action.$action';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => raw);
      final service = AndroidLaunchIntentService();
      addTearDown(service.dispose);
      await service.initialize();
      expect(service.pendingDestination.value, destination);

      service.pendingDestination.value = null;
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall('launchAction', raw)),
        (_) {},
      );
      expect(service.pendingDestination.value, destination);
    });
  }

  test('initializes from a cold-start Quick Chat shortcut once', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getInitialLaunchAction');
          return 'quickChat';
        });

    final service = AndroidLaunchIntentService();
    await service.initialize();

    expect(service.pendingQuickChat.value, isTrue);
    expect(service.takePendingQuickChat(), isTrue);
    expect(service.takePendingQuickChat(), isFalse);
  });

  test('receives a warm Quick Chat shortcut from Android', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    final service = AndroidLaunchIntentService();
    await service.initialize();

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            const MethodCall('launchAction', 'quickChat'),
          ),
          (_) {},
        );

    expect(service.takePendingQuickChat(), isTrue);
    expect(service.takePendingQuickChat(), isFalse);
  });
}
