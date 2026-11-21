// The bot chat header's avatar follows the person and the turn: dictating is
// listening, a sent turn thinks, streaming reply text speaks, a finished turn
// idles, a failed one shows an error, and reduced motion sleeps.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/voice_composer_adapter.dart';
import 'package:hermes_android/hm/avatar/hm_avatar.dart';
import 'package:hermes_android/hm/avatar/hm_avatar_state.dart';
import 'package:hermes_android/hm/hm_bots.dart';
import 'package:hermes_android/hm/screens/hm_chat_screen.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/nextgen_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A chat whose turn the test drives: send records the text and starts a
/// turn; [stream], [finish] and [fail] play the gateway's part.
class _FakeChat extends NgChatController {
  _FakeChat(super.gateway) : super(sessionId: 'stored');

  final sent = <String>[];
  bool refuse = false;

  @override
  Future<bool> send(
    String text, {
    List attachments = const [],
    String? submissionId,
  }) async {
    sent.add(text);
    final user = NgUserItem('u${items.length}', text, time: DateTime.now());
    items.add(user);
    if (refuse) {
      user.failure = 'Refused';
      notifyListeners();
      return false;
    }
    running = true;
    lastTurnFailed = false;
    items.add(NgAssistantItem('a${items.length}'));
    notifyListeners();
    return true;
  }

  NgAssistantItem get _reply => items.last as NgAssistantItem;

  void stream(String chunk) {
    _reply.text += chunk;
    notifyListeners();
  }

  void finish({bool failed = false}) {
    _reply.open = false;
    running = false;
    lastTurnFailed = failed;
    notifyListeners();
  }
}

/// The mic: hands its callbacks to the test instead of a recognizer.
class _FakeVoice implements VoiceComposerAdapter {
  bool available = true;
  VoiceResultCallback? onResult;
  VoiceStatusCallback? onStatus;
  int stops = 0;

  @override
  Future<bool> get hasPermission async => available;

  @override
  Future<bool> initialize({
    required VoiceStatusCallback onStatus,
    required VoiceErrorCallback onError,
  }) async {
    this.onStatus = onStatus;
    return available;
  }

  @override
  Future<void> listen({
    required VoiceResultCallback onResult,
    String? localeId,
  }) async {
    this.onResult = onResult;
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> cancel() async {}

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const bot = HmBot(
    profile: 'default',
    isDefault: true,
    displayName: 'Hermes',
    model: 'm',
    provider: 'p',
    skillCount: 0,
    character: HmCharacterSpec(seed: 3),
  );

  Future<(_FakeChat, _FakeVoice, NextGenGateway)> pump(
    WidgetTester tester, {
    bool reducedMotion = false,
  }) async {
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
    final chat = _FakeChat(gateway)..runtimeId = 'stored';
    final voice = _FakeVoice();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: nextGenTheme(Brightness.light, NextGenLook.instance),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reducedMotion),
          child: child!,
        ),
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
            bot: bot,
            chat: chat,
            onAction: (_) async {},
            onNewChat: () {},
            voiceFactory: () => voice,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    return (chat, voice, gateway);
  }

  Future<void> teardown(
    WidgetTester tester,
    NgChatController chat,
    NextGenGateway gateway,
  ) async {
    await tester.pumpWidget(const SizedBox());
    chat.dispose();
    gateway.dispose();
  }

  HmAvatarState header(WidgetTester tester) =>
      tester.widget<HmAvatar>(find.byType(HmAvatar)).state;

  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 50));

  testWidgets('dictate -> send -> streaming -> done -> error', (tester) async {
    final (chat, voice, gateway) = await pump(tester);
    expect(header(tester), HmAvatarState.idle);

    // Dictate: the mic turns on and the bot listens.
    await tester.tap(find.byTooltip('Dictate'));
    await settle(tester);
    expect(find.byTooltip('Stop dictation'), findsOneWidget);
    expect(header(tester), HmAvatarState.listening);

    // Words arrive while still listening; Send replaces the mic.
    voice.onResult!(transcript: 'what is up', isFinal: false);
    await settle(tester);
    expect(find.text('what is up'), findsOneWidget);
    expect(header(tester), HmAvatarState.listening);

    // Send: the dictated text goes out, dictation ends, the bot thinks.
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    expect(chat.sent, ['what is up']);
    expect(voice.stops, 1);
    expect(header(tester), HmAvatarState.thinking);

    // A late recognizer result can't refill the composer or relisten.
    voice.onResult!(transcript: 'what is up', isFinal: true);
    await settle(tester);
    expect(find.widgetWithText(TextField, 'what is up'), findsNothing);
    expect(header(tester), HmAvatarState.thinking);

    // Reply text streams: speaking.
    chat.stream('Not much');
    await settle(tester);
    expect(header(tester), HmAvatarState.speaking);

    // Turn done: idle.
    chat.finish();
    await settle(tester);
    expect(header(tester), HmAvatarState.idle);

    // A turn that fails: error, kept until the next turn.
    await tester.enterText(find.byType(TextField), 'again');
    await settle(tester);
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    expect(header(tester), HmAvatarState.thinking);
    chat.finish(failed: true);
    await settle(tester);
    expect(header(tester), HmAvatarState.error);

    await teardown(tester, chat, gateway);
  });

  testWidgets('a final result or the recognizer stopping ends listening', (
    tester,
  ) async {
    final (chat, voice, gateway) = await pump(tester);
    await tester.tap(find.byTooltip('Dictate'));
    await settle(tester);
    expect(header(tester), HmAvatarState.listening);
    voice.onResult!(transcript: 'hello', isFinal: true);
    await settle(tester);
    expect(find.text('hello'), findsOneWidget);
    expect(header(tester), HmAvatarState.idle);

    // Nothing heard: the recognizer reports it stopped.
    await tester.enterText(find.byType(TextField), '');
    await settle(tester);
    await tester.tap(find.byTooltip('Dictate'));
    await settle(tester);
    expect(header(tester), HmAvatarState.listening);
    voice.onStatus!('notListening');
    await settle(tester);
    expect(header(tester), HmAvatarState.idle);
    expect(find.byTooltip('Dictate'), findsOneWidget);

    await teardown(tester, chat, gateway);
  });

  testWidgets('no recognizer: the mic says so and the bot stays idle', (
    tester,
  ) async {
    final (chat, voice, gateway) = await pump(tester);
    voice.available = false;
    await tester.tap(find.byTooltip('Dictate'));
    await settle(tester);
    expect(header(tester), HmAvatarState.idle);
    expect(find.text("Speech recognition isn't available."), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await teardown(tester, chat, gateway);
  });

  testWidgets('a refused send shows an error', (tester) async {
    final (chat, _, gateway) = await pump(tester);
    chat.refuse = true;
    await tester.enterText(find.byType(TextField), 'hi');
    await settle(tester);
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    expect(header(tester), HmAvatarState.error);
    await teardown(tester, chat, gateway);
  });

  testWidgets('reduced motion: asleep while busy, error still shows', (
    tester,
  ) async {
    final (chat, _, gateway) = await pump(tester, reducedMotion: true);
    expect(header(tester), HmAvatarState.asleep);
    await tester.tap(find.byTooltip('Dictate'));
    await settle(tester);
    expect(header(tester), HmAvatarState.asleep);
    await teardown(tester, chat, gateway);
    final (chat2, _, gateway2) = await pump(tester, reducedMotion: true);
    await tester.enterText(find.byType(TextField), 'hi');
    await settle(tester);
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    expect(header(tester), HmAvatarState.asleep);
    chat2.finish(failed: true);
    await settle(tester);
    expect(header(tester), HmAvatarState.error);
    await teardown(tester, chat2, gateway2);
  });
}
