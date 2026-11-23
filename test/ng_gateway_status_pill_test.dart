import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/settings_page.dart';

SavedConnection _conn() => SavedConnection(
  id: 'c1',
  label: 'Home',
  host: 'gateway.test',
  port: 9119,
  apiKey: '',
  desktopGatewayUrl: 'http://gateway.test:9119',
  singleLogin: true,
  signInMethod: 'password',
);

class _Gateway extends NextGenGateway {
  _Gateway() : super(_conn());

  NgConnectionState _phase = const NgConnectionState(NgConnectionPhase.idle);

  @override
  NgConnectionState get state => _phase;

  set phase(NgConnectionPhase phase) {
    _phase = NgConnectionState(phase);
    notifyListeners();
  }
}

Future<void> _pump(WidgetTester tester, _Gateway gateway, bool signedIn) =>
    tester.pumpWidget(
      MaterialApp(
        theme: nextGenTheme(Brightness.light, NextGenLook.instance),
        home: Scaffold(
          body: Center(
            child: NgGatewayStatusPill(gateway: gateway, signedIn: signedIn),
          ),
        ),
      ),
    );

void main() {
  testWidgets('a confirmed sign-in never sits beside a Signed out pill', (
    tester,
  ) async {
    final gateway = _Gateway()..phase = NgConnectionPhase.sessionExpired;
    await _pump(tester, gateway, true);
    expect(find.text('Signed out'), findsNothing);
    expect(find.text('Connection failed'), findsOneWidget);
  });

  testWidgets('an expired session without a confirmed user reads Signed out', (
    tester,
  ) async {
    final gateway = _Gateway()..phase = NgConnectionPhase.sessionExpired;
    await _pump(tester, gateway, false);
    expect(find.text('Signed out'), findsOneWidget);
  });

  testWidgets('the pill follows the socket while signed in', (tester) async {
    final gateway = _Gateway()..phase = NgConnectionPhase.connecting;
    await _pump(tester, gateway, true);
    expect(find.text('Connecting…'), findsOneWidget);
    gateway.phase = NgConnectionPhase.connected;
    await tester.pump();
    expect(find.text('Connected'), findsOneWidget);
    gateway.phase = NgConnectionPhase.sessionExpired;
    await tester.pump();
    expect(find.text('Signed out'), findsNothing);
  });
}
