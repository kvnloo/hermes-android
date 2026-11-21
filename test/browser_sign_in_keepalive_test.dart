import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_keepalive_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/main.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Android freezes the app behind the sign-in Custom Tab, and a frozen app
// can't answer the browser's loopback redirect. While a browser sign-in waits
// for its code, leaving the app must start the foreground service.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a browser sign-in keeps the process up behind the browser', (
    tester,
  ) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      ConnectionKeepAliveService.channel,
      (call) async {
        calls.add(call.method);
        return true;
      },
    );
    addTearDown(() {
      browserSignInPending.value = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        ConnectionKeepAliveService.channel,
        null,
      );
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(HermesApp(connManager: ConnectionManager(prefs)));
    await tester.pump(const Duration(seconds: 1));

    browserSignInPending.value = true;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    expect(calls.where((m) => m == 'start'), isNotEmpty);

    calls.clear();
    browserSignInPending.value = false;
    await tester.pump();
    expect(calls, contains('stop'));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('leaving the app with no sign-in pending starts nothing', (
    tester,
  ) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      ConnectionKeepAliveService.channel,
      (call) async {
        calls.add(call.method);
        return true;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        ConnectionKeepAliveService.channel,
        null,
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(HermesApp(connManager: ConnectionManager(prefs)));
    await tester.pump(const Duration(seconds: 1));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(calls, isNot(contains('start')));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  });
}
