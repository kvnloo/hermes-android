import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/hm/features/settings/chat_settings_screen.dart';
import 'package:hermes_android/hm/features/settings/settings_prefs.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/hm/screens/hm_settings_screen.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/nextgen_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_support.dart';

void main() {
  group('Chat page', () {
    testWidgets('loaded: official options with their defaults', (
      tester,
    ) async {
      phoneSize(tester);
      final settings = await loadedSettings();
      await tester.pumpWidget(
        hmTestApp(HmChatSettingsScreen(prefs: settings)),
      );

      expect(find.text('Chat Style'), findsOneWidget);
      expect(find.text('Your day is all planned.'), findsNWidgets(2));
      expect(
        find.text('Choose how messages appear in all your conversations.'),
        findsOneWidget,
      );
      expect(find.text('Dismiss keyboard after sending'), findsOneWidget);
      expect(
        find.text('Off keeps the keyboard ready for your next message.'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(find.text('Fold finished turns'), 200);
      expect(find.text('In New Chats'), findsOneWidget);
      expect(find.text('Tool calls'), findsOneWidget);
      expect(find.text('Device actions'), findsOneWidget);
      expect(find.text('Thinking'), findsOneWidget);
      expect(
        find.text(
          'What Hermes reasons through before it answers, when the model shares it.',
        ),
        findsOneWidget,
      );

      Switch switchFor(String title) => tester.widget<Switch>(
        find.descendant(
          of: find.ancestor(
            of: find.text(title),
            matching: find.byType(InkWell),
          ),
          matching: find.byType(Switch),
        ),
      );
      expect(switchFor('Tool calls').value, isTrue);
      expect(switchFor('Device actions').value, isTrue);
      expect(switchFor('Thinking').value, isFalse);
    });

    testWidgets('choosing Bubbles and Thinking persists them', (
      tester,
    ) async {
      phoneSize(tester);
      final settings = await loadedSettings();
      await tester.pumpWidget(
        hmTestApp(HmChatSettingsScreen(prefs: settings)),
      );

      await tester.tap(find.byKey(const ValueKey('hm-chat-style-bubbles')));
      await tester.pump();
      expect(settings.chatStyle, HmChatStyle.bubbles);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(HmSettingsPrefs.chatStyleKey), 'bubbles');

      await tester.tap(find.text('Dismiss keyboard after sending'));
      await tester.pump();
      expect(prefs.getBool(HmSettingsPrefs.dismissKeyboardKey), isTrue);

      await tester.scrollUntilVisible(find.text('Thinking'), 200);
      await tester.ensureVisible(find.text('Thinking'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thinking'));
      await tester.pump();
      expect(settings.showThinking, isTrue);
      expect(prefs.getBool(HmSettingsPrefs.showThinkingKey), isTrue);
    });

    testWidgets('error: a failed save rolls back and says so', (tester) async {
      phoneSize(tester);
      final settings = await loadedSettings(failWrites: true);
      await tester.pumpWidget(
        hmTestApp(HmChatSettingsScreen(prefs: settings)),
      );
      await tester.tap(find.byKey(const ValueKey('hm-chat-style-bubbles')));
      await tester.pump();
      expect(settings.chatStyle, HmChatStyle.standard);
      expect(find.text("Couldn't save this setting."), findsOneWidget);
    });
  });

  group('Settings rows', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      phoneSize(tester);
      final prefs = await SharedPreferences.getInstance();
      final conn = SavedConnection(
        id: 'c1',
        label: 'Home',
        host: '10.0.0.5',
        port: 9119,
        apiKey: '',
        desktopGatewayUrl: 'http://10.0.0.5:9119',
        singleLogin: true,
        signInMethod: 'none',
      );
      final gateway = NextGenGateway(conn);
      final bots = HmBotsModel(gateway);
      addTearDown(bots.dispose);
      await tester.pumpWidget(
        MaterialApp(
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
            child: HmSettingsScreen(bots: bots),
          ),
        ),
      );
    }

    /// The value text in the row labelled [label].
    String valueOf(WidgetTester tester, String label) {
      final row = find.ancestor(
        of: find.text(label),
        matching: find.byType(InkWell),
      );
      final texts = tester
          .widgetList<Text>(
            find.descendant(of: row.first, matching: find.byType(Text)),
          )
          .map((t) => t.data)
          .where((d) => d != label)
          .toList();
      return texts.single!;
    }

    testWidgets('defaults read Off / On / Standard', (tester) async {
      HmSettingsPrefs.instance.load(await freshPrefs());
      await pumpSettings(tester);
      expect(valueOf(tester, 'Security'), 'Off');
      expect(valueOf(tester, 'Caching'), 'On');
      expect(valueOf(tester, 'Chat'), 'Standard');
    });

    testWidgets('rows show the stored settings and open their pages', (
      tester,
    ) async {
      HmSettingsPrefs.instance.load(
        await freshPrefs(
          values: {
            HmSettingsPrefs.lockEnabledKey: true,
            HmSettingsPrefs.cacheChatListKey: false,
            HmSettingsPrefs.cacheMessagesKey: false,
            HmSettingsPrefs.cacheFilesKey: false,
            HmSettingsPrefs.chatStyleKey: 'bubbles',
          },
        ),
      );
      await pumpSettings(tester);
      expect(valueOf(tester, 'Security'), 'On');
      expect(valueOf(tester, 'Caching'), 'Off');
      expect(valueOf(tester, 'Chat'), 'Bubbles');

      await tester.tap(find.text('Chat'));
      await tester.pumpAndSettle();
      expect(find.text('Chat Style'), findsOneWidget);

      // Changing it there updates the row on return.
      await tester.tap(find.byKey(const ValueKey('hm-chat-style-standard')));
      await tester.pump();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(valueOf(tester, 'Chat'), 'Standard');
    });
  });
}
