// Renders Play Store screenshots of the NextGen chat with real fonts.
// Run: flutter test test/store_screenshots_test.dart --update-goldens
// Output: test/goldens/store/*.png (1080x2340, 3x of a 360x780 phone).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/theme/ng_theme_spec.dart';
import 'package:hermes_android/nextgen/ui/chat_view.dart';
import 'package:hermes_android/nextgen/ui/nextgen_scope.dart';
import 'package:hermes_android/nextgen/ui/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(
      File(f).readAsBytes().then((b) => ByteData.sublistView(b)),
    );
  }
  await loader.load();
}

void main() {
  final sdkFonts =
      '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await _font('Roboto', ['$sdkFonts/Roboto-Regular.ttf']);
    await _font('MaterialIcons', ['$sdkFonts/MaterialIcons-Regular.otf']);
    List<String> files(String prefix) => Directory('assets/fonts/geist')
        .listSync()
        .map((f) => f.path)
        .where((p) => p.split('/').last.startsWith('$prefix-'))
        .toList();
    await _font('Geist', files('Geist'));
    await _font('GeistMono', files('GeistMono'));
    await _font('Nunito', [
      'assets/fonts/nunito/Nunito-VariableFont_wght.ttf',
      'assets/fonts/nunito/Nunito-Italic-VariableFont_wght.ttf',
    ]);
  });

  for (final themeId in ['onyx', 'dash', 'settings']) {
    testWidgets('store chat $themeId', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final prefs = await SharedPreferences.getInstance();
      final look = NextGenLook.instance
        ..themeId = themeId == 'settings' ? 'onyx' : themeId;
      final conn = SavedConnection(
        id: 'c1',
        label: 'Home',
        host: '10.0.0.5',
        port: 9119,
        apiKey: 'k',
        desktopGatewayUrl: 'http://10.0.0.5:9119',
        dashboardPortOverride: 9119,
        singleLogin: true,
        signInMethod: 'none',
      );
      final gateway = NextGenGateway(conn)
        ..debugSetPhase(NgConnectionPhase.connected);
      final chat = NgChatController(gateway, sessionId: 's');
      final now = DateTime(2026, 11, 15, 9, 41);
      chat.items.addAll([
        NgUserItem('u1', 'Find the three slowest tests in my repo and fix one.',
            time: now),
        NgAssistantItem('a1', open: false, time: now)
          ..reasoning = 'Profile the suite first.'
          ..tools.add(NgTool(
            id: 't1',
            name: 'terminal',
            detail: 'pytest --durations=3',
            durationSeconds: 41.2,
          ))
          ..text =
              'The slowest are **test_sync_large** (18.4 s), '
              '**test_render_all** (9.1 s) and **test_migrate** (6.7 s).\n\n'
              '`test_sync_large` rebuilt its fixture for every case. I moved it '
              'to a session-scoped fixture: it now runs in **2.3 s**.',
        NgUserItem('u2', 'Nice. Open a PR for it.', time: now),
      ]);
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: look,
          builder: (context, _) => MaterialApp(
            debugShowCheckedModeBanner: false,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: nextGenTheme(Brightness.dark, look),
            home: NgScope(
              connManager: ConnectionManager(prefs),
              gateway: gateway,
              connections: [conn],
              switchTo: (_) async {},
              addGateway: () async {},
              signOut: (_) async {},
              reload: () async {},
              signInAgain: () async {},
              child: themeId == 'settings'
                  ? const NgSettingsPage()
                  : Scaffold(
                body: NgChatView(
                  chat: chat,
                  onOpenSidebar: () {},
                  onNewChat: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      if (themeId == 'settings') {
        await tester.scrollUntilVisible(find.text('Look'), 300, scrollable: find.byType(Scrollable).first);
        await tester.pump(const Duration(milliseconds: 300));
      }
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/store/chat_$themeId.png'),
      );
    });
  }
}
