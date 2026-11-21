// The bot chat header: the character and the title pill are one tap target
// that opens Agent settings. The face has its own poke handler; it must not
// swallow the tap.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/hm/avatar/hm_avatar.dart';
import 'package:hermes_android/hm/avatar/syn_face.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/hm/screens/hm_chat_screen.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/nextgen_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

SavedConnection _conn() => SavedConnection(
  id: 'c1',
  label: 'Home',
  host: '10.0.0.5',
  port: 9119,
  apiKey: '',
  desktopGatewayUrl: 'http://10.0.0.5:9119',
  singleLogin: true,
  signInMethod: 'none',
);

const _bot = HmBot(
  profile: 'default',
  isDefault: true,
  displayName: 'Hermes',
  model: 'm',
  provider: 'p',
  skillCount: 0,
  character: HmCharacterSpec(seed: 3),
);

Future<List<String>> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final conn = _conn();
  final gateway = NextGenGateway(conn);
  final chat = NgChatController(gateway, sessionId: 'stored')
    ..runtimeId = 'stored';
  final opened = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: nextGenTheme(Brightness.light, NextGenLook.instance),
      home: NgScope(
        connManager: ConnectionManager(prefs),
        gateway: gateway,
        connections: [conn],
        switchTo: (_) async {},
        addGateway: () async {},
        signOut: (_) async {},
        reload: () async {},
        signInAgain: () async {},
        child: HmChatScreen(
          bot: _bot,
          chat: chat,
          onAction: (_) async {},
          onNewChat: () {},
          onOpenBot: () => opened.add('agent settings'),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    chat.dispose();
    gateway.dispose();
  });
  return opened;
}

void main() {
  testWidgets('tapping the avatar centre opens Agent settings', (tester) async {
    final opened = await _pump(tester);
    // The default look draws the Syn face, which has its own tap handler.
    expect(find.byType(SynFace), findsOneWidget);
    await tester.tap(find.byType(HmAvatar));
    await tester.pump();
    expect(opened, ['agent settings']);
  });

  testWidgets('tapping the title pill opens Agent settings', (tester) async {
    final opened = await _pump(tester);
    await tester.tap(find.text('Hermes').first);
    await tester.pump();
    expect(opened, ['agent settings']);
  });

  testWidgets('the header reads as one Agent settings button', (tester) async {
    await _pump(tester);
    expect(find.bySemanticsLabel(RegExp('^Agent settings')), findsOneWidget);
  });
}
