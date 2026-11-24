import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/dashboard_api_client.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/nextgen/data/chat_controller.dart';
import 'package:hermes_android/nextgen/data/history_rows.dart';
import 'package:hermes_android/nextgen/data/nextgen_gateway.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/chat_view.dart';
import 'package:hermes_android/nextgen/ui/nextgen_scope.dart';
import 'package:http/http.dart' as http;
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

class _ReactionGateway extends NextGenGateway {
  _ReactionGateway() : super(_conn());
  final requests = <Map<String, dynamic>>[];
  bool reject = false;

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    expect(method, 'message.react');
    requests.add({...params});
    if (reject) throw StateError('Rejected');
    return {
      'row_id': params['row_id'] ?? 43,
      'reactions': [
        if (params['emoji'] != null)
          {'emoji': params['emoji'], 'author': 'user'},
      ],
    };
  }
}

/// Serves [rows] (oldest first) newest-first by offset, as the dashboard's
/// `order=latest` paging does.
class _PagedApi extends DashboardApiClient {
  _PagedApi(super.dashboard, this.rows) : super.withDashboard();
  final List<Map<String, dynamic>> rows;
  final calls = <(int?, int)>[];

  @override
  Future<Uint8List> getMessagesBytes(
    String sessionId, {
    int? limit,
    int offset = 0,
    bool latest = false,
  }) async {
    calls.add((limit, offset));
    final end = (rows.length - offset).clamp(0, rows.length);
    final start = (end - (limit ?? rows.length)).clamp(0, end);
    return Uint8List.fromList(
      utf8.encode(jsonEncode({'messages': rows.sublist(start, end)})),
    );
  }
}

/// A [_PagedApi] whose Nth call (zero-based) can be held open until released,
/// so adoption can run while a page fetch is in flight.
class _HeldPagedApi extends _PagedApi {
  _HeldPagedApi(super.dashboard, super.rows);
  final gates = <int, Completer<void>>{};

  @override
  Future<Uint8List> getMessagesBytes(
    String sessionId, {
    int? limit,
    int offset = 0,
    bool latest = false,
  }) async {
    final gate = gates[calls.length];
    if (gate != null) await gate.future;
    return super.getMessagesBytes(
      sessionId,
      limit: limit,
      offset: offset,
      latest: latest,
    );
  }
}

/// Captures the query params a [DashboardApiClient] builds, bypassing auth.
class _CapturingDashboard extends DashboardClient {
  _CapturingDashboard() : super(host: 'fixture.local');
  Map<String, String>? lastQuery;

  @override
  Future<http.Response> apiRequest(
    String method,
    String endpoint, {
    Object? body,
    Map<String, String>? queryParameters,
    Duration timeout = ApiClient.requestTimeout,
    bool retried = false,
  }) async {
    lastQuery = queryParameters;
    return http.Response('{"messages": []}', 200);
  }
}

/// [turns] turns of a prompt, a tool call, its result and a reply.
List<Map<String, dynamic>> _turns(int turns, {int toolChars = 50000}) => [
  for (var t = 0; t < turns; t++) ...[
    {'id': 't$t-u', 'role': 'user', 'content': 'Prompt $t'},
    {
      'id': 't$t-a1',
      'role': 'assistant',
      'content': '',
      'tool_calls': [
        {
          'id': 'call$t',
          'function': {'name': 'terminal', 'arguments': '{"command":"ls"}'},
        },
      ],
    },
    {
      'id': 't$t-tool',
      'role': 'tool',
      'tool_call_id': 'call$t',
      'content': 'x' * toolChars,
    },
    {'id': 't$t-a2', 'role': 'assistant', 'content': 'Reply $t'},
  ],
];

/// Re-tags row (and tool-call) ids so appended rows never collide with the
/// base fixture's ids — the real gateway never reuses a row id.
List<Map<String, dynamic>> _shift(
  List<Map<String, dynamic>> rows,
  String tag,
) => [
  for (final r in rows)
    {
      ...r,
      'id': '$tag-${r['id']}',
      if (r['tool_calls'] != null)
        'tool_calls': [
          for (final c
              in (r['tool_calls'] as List).cast<Map<String, dynamic>>())
            {...c, 'id': '$tag-${c['id']}'},
        ],
      if (r['tool_call_id'] != null)
        'tool_call_id': '$tag-${r['tool_call_id']}',
    },
];

/// Waits (in real time: large pages decode on an isolate) until [done].
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _pumpChat(WidgetTester tester, NgChatController chat) async {
  final gateway = chat.gateway;
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: nextGenTheme(Brightness.light, NextGenLook.instance),
      home: NgScope(
        connManager: ConnectionManager(prefs),
        gateway: gateway,
        connections: [gateway.connection],
        switchTo: (_) async {},
        addGateway: () async {},
        signOut: (_) async {},
        reload: () async {},
        signInAgain: () async {},
        child: Scaffold(
          body: NgChatView(chat: chat, onOpenSidebar: () {}, onNewChat: () {}),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('reaction actions send skin tones and show live agent reactions', (
    tester,
  ) async {
    final gateway = _ReactionGateway();
    final chat = NgChatController(gateway, sessionId: 'stored')
      ..runtimeId = 'runtime';
    addTearDown(gateway.dispose);
    addTearDown(chat.dispose);
    chat.debugApplyHistory([
      {
        'row_id': 41,
        'role': 'user',
        'content': 'Question',
        'display_metadata': {
          'reactions': [
            {'emoji': '💡', 'author': 'agent'},
          ],
        },
      },
      {'row_id': 42, 'role': 'assistant', 'content': 'Answer'},
    ]);
    await _pumpChat(tester, chat);
    final actions = find.byTooltip('Add Reaction');
    expect(actions, findsNothing);
    expect(find.text('💡'), findsNothing);

    gateway.readyFrame = const {'replay_epoch': 'test'};
    gateway.debugSetPhase(NgConnectionPhase.connected);
    await tester.pump();
    expect(find.text('💡'), findsOneWidget);
    // The transcript is reversed: the assistant's action is built first.
    await tester.tap(actions.first);
    await tester.pumpAndSettle();
    expect(find.text('SKIN TONE'), findsOneWidget);
    expect(
      find.text(
        'Hermes sees your reactions and can react to your messages with an emoji.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('✋🏽'));
    await tester.pump();
    await tester.tap(find.text('👍🏽'));
    await tester.pumpAndSettle();
    expect(gateway.requests.single, {
      'session_id': 'runtime',
      'row_id': 42,
      'emoji': '👍🏽',
      'author': 'user',
    });
    expect(find.text('👍🏽'), findsOneWidget);

    gateway.debugEmit(
      StreamEvent(
        type: 'message.reaction',
        sessionId: 'runtime',
        data: const {
          'row_id': 42,
          'role': 'assistant',
          'reactions': [
            {'emoji': '👍🏽', 'author': 'user'},
            {'emoji': '🎉', 'author': 'agent'},
          ],
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('🎉'), findsOneWidget);

    await tester.tap(actions.first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove reaction'));
    await tester.pumpAndSettle();
    expect(gateway.requests.last, {
      'session_id': 'runtime',
      'row_id': 42,
      'emoji': null,
      'author': 'user',
    });
    expect(find.text('👍🏽'), findsNothing);

    gateway.reject = true;
    await tester.tap(actions.first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('❤️'));
    await tester.pumpAndSettle();
    expect(find.text('Could not add reaction'), findsOneWidget);

    gateway.debugSetPhase(NgConnectionPhase.reconnecting);
    await tester.pump();
    await tester.tap(actions.first);
    await tester.pumpAndSettle();
    expect(
      find.text('Reconnect this conversation before reacting.'),
      findsOneWidget,
    );
    expect(gateway.requests, hasLength(3));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('memory updates show as compact system rows', (tester) async {
    final gateway = NextGenGateway(_conn());
    final chat = NgChatController(gateway, sessionId: 'stored');
    addTearDown(gateway.dispose);
    addTearDown(chat.dispose);
    chat.debugApplyHistory([
      {'role': 'assistant', 'content': 'Done'},
      {'role': 'assistant', 'content': '💾 Memory updated'},
    ]);
    await _pumpChat(tester, chat);
    expect(find.text('Memory updated'), findsOneWidget);
    expect(find.byIcon(Icons.save_outlined), findsOneWidget);
    expect(find.text('💾 Memory updated'), findsNothing);

    gateway.debugEmit(
      StreamEvent(
        type: 'review.summary',
        data: const {'text': '💾 Self-improvement review: Memory updated'},
        sessionId: 'stored',
      ),
    );
    await tester.pump();
    expect(find.text('Memory updated'), findsNWidgets(2));
    expect(find.byIcon(Icons.save_outlined), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });

  // The live frame from a disposable host (memory.nudge_interval: 1): a
  // background review that wrote USER.md logs result=memory and publishes
  // its summary under the runtime session id with the "User profile" label
  // (agent/background_review.py display.review.label.user), not "Memory".
  testWidgets('a user-profile review summary shows the memory row', (
    tester,
  ) async {
    final gateway = NextGenGateway(_conn());
    final chat = NgChatController(gateway, sessionId: 'stored');
    addTearDown(gateway.dispose);
    addTearDown(chat.dispose);
    chat.runtimeId = '511e3787';
    chat.debugApplyHistory([
      {'role': 'assistant', 'content': 'Done'},
    ]);
    await _pumpChat(tester, chat);
    expect(find.text('Memory updated'), findsNothing);

    for (final text in const [
      '💾 Self-improvement review: User profile updated',
      "💾 Self-improvement review: Skill 'x' created · User profile updated",
    ]) {
      gateway.debugEmit(
        StreamEvent(
          type: 'review.summary',
          data: {'text': text},
          sessionId: '511e3787',
        ),
      );
    }
    await tester.pump();
    expect(find.text('Memory updated'), findsNWidgets(2));
    expect(find.byIcon(Icons.save_outlined), findsNWidgets(2));

    // Summaries that changed no memory still draw no memory row: a skill-only
    // review, and a consolidation the host staged for approval.
    for (final text in const [
      "💾 Self-improvement review: Skill 'x' created",
      '💾 Self-improvement review: Background review may not delete memory '
          'entries unattended. The proposed batch was staged for your approval',
    ]) {
      gateway.debugEmit(
        StreamEvent(
          type: 'review.summary',
          data: {'text': text},
          sessionId: '511e3787',
        ),
      );
    }
    // A summary for another chat never lands here.
    gateway.debugEmit(
      StreamEvent(
        type: 'review.summary',
        data: const {'text': '💾 Self-improvement review: Memory updated'},
        sessionId: 'other',
      ),
    );
    await tester.pump();
    expect(find.text('Memory updated'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });

  // A current host adds `kinds` (locale-independent, ordered memory, user,
  // skill) next to its localized `text`. The row follows `kinds`; the English
  // label match is only for older hosts that send no `kinds` at all.
  testWidgets('review summaries are classified by kinds, not display text', (
    tester,
  ) async {
    final gateway = NextGenGateway(_conn());
    final chat = NgChatController(gateway, sessionId: 'stored');
    addTearDown(gateway.dispose);
    addTearDown(chat.dispose);
    chat.runtimeId = '511e3787';
    chat.debugApplyHistory([
      {'role': 'assistant', 'content': 'Done'},
    ]);
    await _pumpChat(tester, chat);

    var rows = 0;
    Future<void> emit(Map<String, dynamic> data, {required bool row}) async {
      gateway.debugEmit(
        StreamEvent(type: 'review.summary', data: data, sessionId: '511e3787'),
      );
      await tester.pump();
      await tester.pump();
      if (row) rows++;
      expect(
        chat.items.whereType<NgMemoryUpdatedItem>(),
        hasLength(rows),
        reason: '$data',
      );
      expect(
        find.text('Memory updated'),
        rows == 0 ? findsNothing : findsNWidgets(rows),
        reason: '$data',
      );
    }

    // Hungarian host text (locales/hu.yaml display.review.*) with memory or
    // user kinds: the English matcher would miss these.
    await emit(const {
      'text': '💾 Önfejlesztési áttekintés: Memória frissítve',
      'kinds': ['memory'],
    }, row: true);
    await emit(const {
      'text': '💾 Önfejlesztési áttekintés: Felhasználói profil frissítve',
      'kinds': ['user'],
    }, row: true);
    // Mixed kinds: any memory or user write draws one row.
    await emit(const {
      'text':
          '💾 Önfejlesztési áttekintés: Memória frissítve · '
          'Felhasználói profil frissítve · '
          "A(z) 'x' skill létrehozva",
      'kinds': ['memory', 'user', 'skill'],
    }, row: true);
    await emit(const {
      'text':
          "💾 Önfejlesztési áttekintés: A(z) 'x' skill létrehozva · "
          'Felhasználói profil frissítve',
      'kinds': ['user', 'skill'],
    }, row: true);

    // Skill-only and explicitly empty kinds never draw a memory row, even
    // when the text reads like an English memory update: present kinds are
    // authoritative and never fall back to the text.
    await emit(const {
      'text': "💾 Önfejlesztési áttekintés: A(z) 'x' skill létrehozva",
      'kinds': ['skill'],
    }, row: false);
    await emit(const {
      'text': '💾 Self-improvement review: Memory updated',
      'kinds': ['skill'],
    }, row: false);
    await emit(const {
      'text': '💾 Self-improvement review: User profile updated',
      'kinds': <String>[],
    }, row: false);
    await emit(const {
      'text': '💾 Önfejlesztési áttekintés: Memória frissítve',
      'kinds': <String>[],
    }, row: false);
    // An unreadable kinds value is present, so it does not fall back either.
    await emit(const {
      'text': '💾 Self-improvement review: Memory updated',
      'kinds': 'memory',
    }, row: false);

    // Older hosts send no kinds: the English label match still applies, and
    // localized text without kinds stays unrecognised as before.
    await emit(const {
      'text': '💾 Self-improvement review: User profile updated',
    }, row: true);
    await emit(const {
      'text': '💾 Self-improvement review: Memory updated',
      'kinds': null,
    }, row: true);
    await emit(const {
      'text': "💾 Self-improvement review: Skill 'x' created",
    }, row: false);
    await emit(const {
      'text': '💾 Önfejlesztési áttekintés: Memória frissítve',
    }, row: false);

    // Routing is unchanged: a kinds summary for another chat never lands here.
    gateway.debugEmit(
      StreamEvent(
        type: 'review.summary',
        data: const {
          'text': '💾 Önfejlesztési áttekintés: Memória frissítve',
          'kinds': ['memory'],
        },
        sessionId: 'other',
      ),
    );
    await tester.pump();
    expect(find.text('Memory updated'), findsNWidgets(rows));
    expect(find.byIcon(Icons.save_outlined), findsNWidgets(rows));
    // The localized host text itself is never drawn as a notice.
    expect(find.textContaining('Önfejlesztési'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('completed turns show elapsed time when known', (tester) async {
    final gateway = NextGenGateway(_conn());
    final chat = NgChatController(gateway, sessionId: 'stored');
    addTearDown(chat.dispose);
    addTearDown(gateway.dispose);
    chat.debugApplyHistory([
      {'role': 'assistant', 'content': 'Unknown timing'},
      {'role': 'user', 'content': 'Try again'},
      {'role': 'assistant', 'content': 'Done', 'duration_s': 64},
    ]);
    await _pumpChat(tester, chat);
    expect(find.text('Worked for 1m 4s'), findsOneWidget);
    expect(find.textContaining('Worked for'), findsOneWidget);

    gateway.debugEmit(
      StreamEvent(type: 'message.start', data: const {}, sessionId: 'stored'),
    );
    await tester.pump();
    expect(find.textContaining('Worked for'), findsOneWidget);
    gateway.debugEmit(
      StreamEvent(
        type: 'message.complete',
        data: const {'text': 'Live reply'},
        sessionId: 'stored',
      ),
    );
    await tester.pump();
    expect(find.text('Worked for 0s'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  group('Markdown chunks', () {
    test('short text stays whole', () {
      expect(ngMarkdownChunks('one\n\ntwo'), ['one\n\ntwo']);
    });

    test('long text splits at paragraphs and rejoins exactly', () {
      final text = List.generate(
        40,
        (i) => 'Paragraph $i ${'w' * 200}',
      ).join('\n\n');
      final chunks = ngMarkdownChunks(text);
      expect(chunks.length, greaterThan(2));
      expect(chunks.join('\n\n'), text);
    });

    test('never splits before an indented continuation', () {
      final text = List.generate(
        30,
        (i) => '- item $i ${'w' * 200}\n\n    continued $i',
      ).join('\n\n');
      for (final chunk in ngMarkdownChunks(text)) {
        expect(chunk.startsWith(' '), isFalse);
      }
    });
  });

  test('a full page drops the partial turn at its start', () {
    final page = [
      {'role': 'tool', 'content': 'tail of an older turn'},
      {'role': 'assistant', 'content': 'older reply'},
      {'role': 'user', 'content': 'Prompt'},
      {'role': 'assistant', 'content': 'Reply'},
    ];
    expect(ngFromFirstTurn(page).first['content'], 'Prompt');
    final oneTurn = [
      {'role': 'assistant', 'content': 'a'},
      {'role': 'tool', 'content': 'b'},
    ];
    expect(ngFromFirstTurn(oneTurn), oneTurn);
  });

  test('structured text parts are skipped, keeping readable ones', () {
    final gateway = NextGenGateway(_conn());
    final chat = NgChatController(gateway, sessionId: 'stored');
    chat.debugApplyHistory([
      {
        'role': 'user',
        'content': [
          {'text': 'Hello'},
          {
            'text': {'value': 'unsupported'},
          },
        ],
      },
      {
        'role': 'assistant',
        'content': 'Raw',
        'display_content': [
          {'text': []},
          {'text': 'Welcome'},
        ],
      },
    ]);
    expect(chat.items.whereType<NgUserItem>().single.text, 'Hello');
    expect(chat.items.whereType<NgAssistantItem>().single.text, 'Welcome');
    chat.dispose();
    gateway.dispose();
  });

  group('slim rows', () {
    test('tool output and arguments are capped, previews kept', () {
      final rows = ngSlimHistoryRows([
        {
          'role': 'assistant',
          'content': 'ok',
          'reasoning_details': [
            {'text': 'x' * 100000},
          ],
          'tool_calls': [
            {
              'id': 'c',
              'function': {
                'name': 'write_file',
                'arguments': jsonEncode({
                  'path': '/tmp/big.txt',
                  'content': 'y' * 100000,
                }),
              },
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'c', 'content': 'z' * 100000},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'look'},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,${'A' * 100000}'},
            },
          ],
        },
      ]);
      final call = (rows[0]['tool_calls'] as List).single as Map;
      expect(call['ng_args_preview'], '/tmp/big.txt');
      expect(
        ((call['function'] as Map)['arguments'] as String).length,
        lessThanOrEqualTo(ngRowToolChars + 1),
      );
      expect(rows[0].containsKey('reasoning_details'), isFalse);
      expect(
        (rows[1]['content'] as String).length,
        lessThanOrEqualTo(ngRowToolChars + 1),
      );
      expect(jsonEncode(rows[2]).length, lessThan(1000));
    });

    test('a large page decodes on a background isolate', () async {
      final body = Uint8List.fromList(
        utf8.encode(jsonEncode({'messages': _turns(10)})),
      );
      expect(body.length, greaterThan(ngIsolateDecodeBytes));
      final rows = await ngDecodeHistory(body);
      expect(rows, hasLength(40));
      expect(
        (rows[2]['content'] as String).length,
        lessThanOrEqualTo(ngRowToolChars + 1),
      );
    });
  });

  group('history paging', () {
    late NextGenGateway gateway;
    late NgChatController chat;
    late _PagedApi api;

    setUp(() {
      gateway = NextGenGateway(_conn());
      api = _PagedApi(gateway.dashboard, _turns(40)); // 160 rows
      gateway.api = api;
      chat = NgChatController(gateway, sessionId: 'stored');
    });
    tearDown(() {
      chat.dispose();
      gateway.dispose();
    });

    List<String> prompts() => [
      for (final i in chat.items)
        if (i is NgUserItem) i.text,
    ];

    test(
      'opens on the latest page and pages back to the first prompt',
      () async {
        unawaited(chat.open());
        await _until(() => chat.items.isNotEmpty);
        expect(api.calls.first, (ngHistoryPage, 0));
        expect(chat.hasOlder, isTrue);
        expect(prompts().first, 'Prompt 25', reason: '60 rows = 15 turns');
        expect(prompts().last, 'Prompt 39');

        var pages = 0;
        while (chat.hasOlder && pages < 10) {
          await chat.loadOlder();
          pages++;
        }
        expect(chat.hasOlder, isFalse);
        expect(prompts(), [for (var t = 0; t < 40; t++) 'Prompt $t']);
        // Every turn whole: one prompt, one reply with its tool.
        final replies = chat.items.whereType<NgAssistantItem>().toList();
        expect(replies, hasLength(40));
        expect(replies.every((r) => r.tools.length == 1), isTrue);
        expect(replies.first.text, 'Reply 0');
      },
    );

    test('a latest page with nothing to show reaches back, a few pages at '
        'most', () async {
      api.rows
        ..clear()
        ..addAll([
          {'id': 'u', 'role': 'user', 'content': 'Start'},
          {'id': 'a', 'role': 'assistant', 'content': 'On it'},
          for (var i = 0; i < 1000; i++)
            {
              'id': 'h$i',
              'role': 'assistant',
              'content': 'x',
              'display_kind': 'hidden',
            },
        ]);
      unawaited(chat.open());
      await _settle();
      await _settle();
      expect(chat.items, isEmpty, reason: '1000 hidden rows, 5 pages read');
      expect(api.calls, hasLength(5));
      expect(chat.loadingHistory, isFalse);
    });

    test('keeps only so much of a huge tool output in memory', () async {
      unawaited(chat.open());
      await _until(() => chat.items.isNotEmpty);
      final tool = chat.items.whereType<NgAssistantItem>().first.tools.single;
      expect(tool.output!.length, lessThanOrEqualTo(ngStoredToolChars + 1));
    });

    testWidgets('Load earlier messages keeps the visible transcript in place', (
      tester,
    ) async {
      // Small rows: fake-async widget tests can't wait on an isolate.
      api = _PagedApi(gateway.dashboard, _turns(40, toolChars: 100));
      gateway.api = api;
      final rows = api.rows;
      chat.debugApplyHistory(
        rows.sublist(rows.length - ngHistoryPage),
        pageLimit: ngHistoryPage,
      );
      await _pumpChat(tester, chat);
      await tester.pump(const Duration(milliseconds: 300));
      final load = find.text('Load earlier messages');
      final scrollable = find
          .descendant(
            of: find.byKey(const ValueKey('ng-transcript')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(load, 200, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(api.calls, isEmpty);
      final prompt = find.text('Prompt 25');
      final before = tester.getTopLeft(prompt);
      await tester.tap(load);
      await tester.pumpAndSettle();
      expect(api.calls.single, (ngHistoryPage, ngHistoryPage));
      expect(tester.getTopLeft(prompt), before);
      await tester.scrollUntilVisible(
        find.text('Prompt 10'),
        200,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('Prompt 10'), findsOneWidget);

      // Typing in the composer reuses the parsed replies.
      final first = tester
          .widgetList<MarkdownBody>(find.byType(MarkdownBody))
          .toList();
      await tester.enterText(find.byType(TextField).last, 'hello');
      await tester.pump();
      final after = tester
          .widgetList<MarkdownBody>(find.byType(MarkdownBody))
          .toList();
      expect(after, isNotEmpty);
      for (final widget in after) {
        expect(first.any((w) => identical(w, widget)), isTrue);
      }
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Paging across live growth', () {
    late NextGenGateway gateway;
    late NgChatController chat;
    late _PagedApi api;

    setUp(() {
      gateway = NextGenGateway(_conn());
      api = _PagedApi(gateway.dashboard, _turns(40)); // 160 rows
      gateway.api = api;
      chat = NgChatController(gateway, sessionId: 'stored');
    });
    tearDown(() {
      chat.dispose();
      gateway.dispose();
    });

    List<String> prompts() => [
      for (final i in chat.items)
        if (i is NgUserItem) i.text,
    ];

    test('a live turn growing the chat does not end pagination', () async {
      unawaited(chat.open());
      await _until(() => chat.items.isNotEmpty);
      expect(prompts().first, 'Prompt 25');
      // A running turn persists a full page of rows while the reader is
      // scrolled back: the newest end moves under the paging offset, so
      // the next page is entirely rows already shown.
      api.rows.addAll(_shift(_turns(15), 'g')); // 60 rows, exactly one page
      await chat.loadOlder();
      expect(
        chat.hasOlder,
        isTrue,
        reason: 'an all-known page must not latch pagination off',
      );
      await chat.loadOlder();
      expect(
        prompts().first,
        'Prompt 10',
        reason: 'paging continues past the shifted window',
      );
    });

    test('growth beside a tool-heavy turn loses no stored rows', () async {
      // 15 short turns, one 80-row turn (39 tool calls), 15 short turns.
      final long = <Map<String, dynamic>>[
        {'id': 'L-u', 'role': 'user', 'content': 'Prompt long'},
        for (var i = 0; i < 39; i++) ...[
          {
            'id': 'L-a$i',
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': 'L-call$i',
                'function': {
                  'name': 'terminal',
                  'arguments': '{"command":"step $i"}',
                },
              },
            ],
          },
          {
            'id': 'L-tool$i',
            'role': 'tool',
            'tool_call_id': 'L-call$i',
            'content': 'ok',
          },
        ],
        {'id': 'L-end', 'role': 'assistant', 'content': 'Reply long'},
      ];
      api.rows
        ..clear()
        ..addAll(_shift(_turns(15, toolChars: 10), 'early'))
        ..addAll(long)
        ..addAll(_shift(_turns(15, toolChars: 10), 'late'));
      unawaited(chat.open());
      await _until(() => chat.items.isNotEmpty);
      // Three short turns run after the chat was opened: 12 rows.
      api.rows.addAll(_shift(_turns(3, toolChars: 10), 'g'));
      for (var i = 0; i < 20 && chat.hasOlder; i++) {
        await chat.loadOlder();
      }
      final replies = [
        for (final i in chat.items)
          if (i is NgAssistantItem && i.text.isNotEmpty) i.text,
      ];
      final longTools = [
        for (final i in chat.items)
          if (i is NgAssistantItem)
            ...i.tools.where((t) => (t.input ?? '').contains('step')),
      ];
      expect(chat.hasOlder, isFalse);
      expect(replies, contains('Reply long'));
      expect(longTools, hasLength(39));
    });

    test('a growth burst never re-fetches an offset', () async {
      api.rows
        ..clear()
        ..addAll(_turns(50)); // 200 rows; the newest page shows 60.
      unawaited(chat.open());
      await _until(() => chat.items.isNotEmpty);
      // A live turn persists exactly one page of rows while the reader is
      // scrolled back. The overlap then repeats on every page: the floor
      // design fetched offsets 0, 60, 120, 120, 180, 180, 240 — one
      // redundant fetch of shown rows per page of new rows.
      api.rows.addAll(_shift(_turns(15), 'g'));
      for (var i = 0; i < 10 && chat.hasOlder; i++) {
        await chat.loadOlder();
      }
      expect(chat.hasOlder, isFalse);
      expect(prompts().first, 'Prompt 0', reason: 'paging must reach the end');
      final offsets = [for (final c in api.calls) c.$2];
      for (var i = 1; i < offsets.length; i++) {
        expect(
          offsets[i],
          greaterThan(offsets[i - 1]),
          reason: 'paging must never re-fetch an offset: $offsets',
        );
      }
    });

    test(
      'a live turn does not re-insert its stored rows as older items',
      () async {
        api.rows
          ..clear()
          ..addAll(_turns(50)); // 200 rows; the newest page shows 60.
        unawaited(chat.open());
        await _until(() => chat.items.isNotEmpty);
        // A running turn persists two pages of rows while the reader is back
        // in history — more than the shown window. The live aggregate already
        // shows the turn; paging must treat its stored rows as shown, not
        // re-insert them as older duplicates.
        api.rows.addAll(
          _shift(_turns(30), 'g'),
        ); // 120 rows > the 60-row window
        gateway.debugEmit(
          StreamEvent(
            type: 'message.start',
            data: const {},
            sessionId: 'stored',
          ),
        );
        gateway.debugEmit(
          StreamEvent(
            type: 'message.delta',
            data: const {'text': 'live reply'},
            sessionId: 'stored',
          ),
        );
        final beforeAdopt = api.calls.length;
        gateway.debugEmit(
          StreamEvent(type: 'turn.end', data: const {}, sessionId: 'stored'),
        );
        // The adopt walks newest pages until it reaches a known row: two
        // pages of live rows plus the window page that stops it. Without the
        // adopt no extra fetch ever happens and this wait just times out.
        await _until(() => api.calls.length >= beforeAdopt + 3);
        for (var i = 0; i < 12 && chat.hasOlder; i++) {
          await chat.loadOlder();
        }
        expect(chat.hasOlder, isFalse);
        expect(
          prompts().first,
          'Prompt 0',
          reason: 'paging must reach the end',
        );
        // The burst re-tags ids only, so its prompts repeat the base fixture's
        // text: a stored live row paging back in shows up as a duplicate
        // prompt. The live turn streamed as one reply — none of its stored
        // rows may re-insert as older items.
        final ps = prompts();
        expect(
          ps.toSet().length,
          ps.length,
          reason: 'live-persisted rows must not page back in: $ps',
        );
      },
    );

    test('paging across a turn end skips no stored rows', () async {
      api.rows
        ..clear()
        ..addAll(_turns(50)); // 200 rows; the newest page shows 60.
      unawaited(chat.open());
      await _until(() => chat.items.isNotEmpty);
      // A live turn persists one page while the reader pages back: the
      // first page is all-known (shift carries the growth), the second
      // fetches fresh older rows.
      api.rows.addAll(_shift(_turns(15), 'g')); // 60 rows
      await chat.loadOlder();
      await chat.loadOlder();
      expect(prompts().first, 'Prompt 20');
      // The turn ends: adoption learns the 60 live rows. The shift was
      // carrying exactly those rows, so it must shrink by the adopted
      // count — otherwise the next offset overshoots real coverage.
      final beforeAdopt = api.calls.length;
      gateway.debugEmit(
        StreamEvent(type: 'turn.end', data: const {}, sessionId: 'stored'),
      );
      await _until(() => api.calls.length >= beforeAdopt + 2);
      await _settle();
      for (var i = 0; i < 12 && chat.hasOlder; i++) {
        await chat.loadOlder();
      }
      expect(chat.hasOlder, isFalse);
      final ps = prompts();
      expect(
        ps,
        containsAll([for (var i = 0; i < 50; i++) 'Prompt $i']),
        reason: 'paging after adoption must skip no stored rows: $ps',
      );
      expect(ps.toSet().length, ps.length, reason: 'no duplicates: $ps');
    });

    test('adoption during an in-flight page does not overshoot', () async {
      final held = _HeldPagedApi(gateway.dashboard, _turns(50));
      api = held;
      gateway.api = held;
      unawaited(chat.open());
      await _until(() => chat.items.isNotEmpty);
      // Two pages of growth: the first loadOlder inserts one page of live
      // rows; the second (held) targets the shown window while adoption
      // learns the remaining live rows mid-fetch.
      held.rows.addAll(_shift(_turns(30), 'g')); // 120 rows
      await chat.loadOlder();
      final gate = Completer<void>();
      held.gates[held.calls.length] = gate;
      final inFlight = chat.loadOlder();
      await _settle();
      final beforeAdopt = held.calls.length;
      gateway.debugEmit(
        StreamEvent(type: 'turn.end', data: const {}, sessionId: 'stored'),
      );
      await _until(() => held.calls.length >= beforeAdopt + 2);
      await _settle();
      gate.complete();
      await inFlight;
      for (var i = 0; i < 12 && chat.hasOlder; i++) {
        await chat.loadOlder();
      }
      expect(chat.hasOlder, isFalse);
      final ps = prompts();
      expect(
        ps,
        containsAll([for (var i = 0; i < 50; i++) 'Prompt $i']),
        reason: 'a mid-fetch adoption must not overshoot the next offset: $ps',
      );
    });

    test('a turn longer than five pages adopts all its stored rows', () async {
      // Two extra rows put the newest page boundary mid-turn, so the shown
      // window trims below a full page.
      api.rows
        ..clear()
        ..addAll(_turns(50))
        ..addAll([
          {'id': 'x-a', 'role': 'assistant', 'content': 'partial'},
          {'id': 'x-t', 'role': 'tool', 'tool_call_id': 'x-a', 'content': 'ok'},
        ]);
      unawaited(chat.open());
      await _until(() => chat.items.isNotEmpty);
      // One live turn persists 360 rows — more than the old five-page
      // adoption cap. Its oldest rows (including its prompt) must be
      // adopted too, or they page back in as older items.
      final long = <Map<String, dynamic>>[
        {'id': 'L-u', 'role': 'user', 'content': 'Prompt long'},
        for (var i = 0; i < 179; i++) ...[
          {
            'id': 'L-a$i',
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': 'L-call$i',
                'function': {'name': 'terminal', 'arguments': '{}'},
              },
            ],
          },
          {
            'id': 'L-tool$i',
            'role': 'tool',
            'tool_call_id': 'L-call$i',
            'content': 'ok',
          },
        ],
        {'id': 'L-end', 'role': 'assistant', 'content': 'Reply long'},
      ];
      api.rows.addAll(long); // 360 rows
      gateway.debugEmit(
        StreamEvent(type: 'message.start', data: const {}, sessionId: 'stored'),
      );
      gateway.debugEmit(
        StreamEvent(
          type: 'message.delta',
          data: const {'text': 'live reply'},
          sessionId: 'stored',
        ),
      );
      final beforeAdopt = api.calls.length;
      gateway.debugEmit(
        StreamEvent(type: 'turn.end', data: const {}, sessionId: 'stored'),
      );
      // Six pages of live rows plus the known window page that stops the
      // walk; the capped walk stopped after five.
      await _until(() => api.calls.length >= beforeAdopt + 7);
      await _settle();
      for (var i = 0; i < 16 && chat.hasOlder; i++) {
        await chat.loadOlder();
      }
      expect(chat.hasOlder, isFalse);
      final ps = prompts();
      expect(ps.first, 'Prompt 0', reason: 'paging must reach the end');
      expect(
        ps,
        containsAll([for (var i = 0; i < 50; i++) 'Prompt $i']),
        reason: 'no stored rows skipped: $ps',
      );
      expect(
        ps.where((p) => p == 'Prompt long'),
        isEmpty,
        reason: 'the live turn\'s stored rows must not page back in: $ps',
      );
    });
  });

  group('History wire params', () {
    test('transcript pages ask the gateway to skip inline images', () async {
      final dash = _CapturingDashboard();
      final api = DashboardApiClient.withDashboard(dash);
      await api.getMessagesBytes('s1', limit: 60, latest: true);
      expect(
        dash.lastQuery!['inline_images'],
        'false',
        reason: 'stored data-URI images must not cross the wire to NextGen',
      );
    });
  });
}
