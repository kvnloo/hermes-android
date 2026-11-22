// Terminal Connection settings: load, validate, save and remove through a
// fake encrypted store; private key paste/import checks.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/terminal/ssh_config.dart';
import 'package:hermes_android/hm/features/terminal/terminal_connection_page.dart';

import 'terminal_ssh_fakes.dart';

const _id = 'conn-1';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _Host {
  final mem = MemCredentialStore();
  late final store = HmSshStore(store: mem);
  bool? popped;
  String? pickedFile;

  void seed(HmSshConfig c) =>
      mem.values[HmSshStore.keyFor(_id)] = jsonEncode(c.toJson());

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  popped = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => HmTerminalConnectionPage(
                        connectionId: _id,
                        defaultHost: 'studio.local',
                        store: store,
                        pickKeyFile: () async => pickedFile,
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);
  }
}

Finder _field(String label) => find.byKey(ValueKey('hm-ssh-field:$label'));

void main() {
  testWidgets('empty: offers the instance host and port 22, validates, and '
      'saves to the encrypted store', (tester) async {
    final h = _Host();
    await h.pump(tester);

    expect(find.text('Terminal Connection'), findsOneWidget);
    expect(find.text('SSH host'), findsOneWidget);
    expect(find.text('studio.local'), findsOneWidget);
    expect(find.text('22'), findsOneWidget);
    expect(
      find.text(
        'Credentials are stored encrypted on this device. You’ll verify the server’s fingerprint on the first connection.',
      ),
      findsOneWidget,
    );
    expect(find.text('Mosh'), findsOneWidget);
    expect(find.text('Not supported'), findsOneWidget);
    expect(find.text('Remove Terminal Connection'), findsNothing);

    await tester.tap(find.text('Save Changes'));
    await _settle(tester);
    expect(
      find.text('Enter an SSH host, username and valid ports.'),
      findsOneWidget,
    );

    await tester.enterText(_field('SSH username'), 'kevin');
    await tester.tap(find.text('Save Changes'));
    await _settle(tester);
    expect(find.text('Choose an SSH password or private key.'), findsOneWidget);
    expect(h.mem.values, isEmpty);

    await tester.enterText(_field('SSH password'), 's3cret');
    await tester.tap(find.text('Save Changes'));
    await _settle(tester);
    expect(h.popped, isTrue);
    final saved = h.mem.saved(_id)!;
    expect(saved['host'], 'studio.local');
    expect(saved['port'], 22);
    expect(saved['username'], 'kevin');
    expect(saved['password'], 's3cret');
  });

  testWidgets('saved key connection: shows Saved private key, Remove clears '
      'it from the store', (tester) async {
    final h = _Host()
      ..seed(
        HmSshConfig(
          host: 'box',
          username: 'kevin',
          privateKey: testOpenSshKey(),
          hostKeyFingerprint: 'SHA256:x',
        ),
      );
    await h.pump(tester);
    expect(find.text('Saved private key'), findsOneWidget);
    expect(find.text('box'), findsOneWidget);
    // The key text itself is never put back on screen.
    expect(find.textContaining('BEGIN OPENSSH'), findsNothing);

    await tester.tap(find.text('Remove Terminal Connection'));
    await _settle(tester);
    expect(h.popped, isTrue);
    expect(h.mem.values, isEmpty);
  });

  testWidgets('pasted keys are checked with the official messages', (
    tester,
  ) async {
    final h = _Host();
    await h.pump(tester);
    await tester.enterText(_field('SSH username'), 'kevin');
    await tester.tap(find.text('Private Key'));
    await _settle(tester);
    expect(
      find.text('Add a private key: paste it or import the key file.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Save Changes'));
    await _settle(tester);
    expect(find.text('Choose an SSH password or private key.'), findsOneWidget);

    await tester.enterText(
      _field('Private key'),
      'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBc test@laptop',
    );
    await tester.tap(find.text('Save Changes'));
    await _settle(tester);
    expect(
      find.text(
        'This is a public key. Use the private key instead — the file without “.pub”, starting with “-----BEGIN”.',
      ),
      findsOneWidget,
    );

    await tester.enterText(_field('Private key'), 'hello');
    await tester.tap(find.text('Save Changes'));
    await _settle(tester);
    expect(find.textContaining('This isn’t a private key'), findsOneWidget);

    await tester.enterText(
      _field('Private key'),
      testOpenSshKey(passphrase: 'hunter2'),
    );
    await _settle(tester);
    expect(find.text('Private key pasted'), findsOneWidget);
    expect(
      find.text(
        'This key is encrypted. Its passphrase is kept encrypted on this device with it.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Save Changes'));
    await _settle(tester);
    expect(
      find.text('This private key is encrypted. Enter its passphrase.'),
      findsOneWidget,
    );

    await tester.enterText(_field('Key passphrase'), 'wrong');
    await tester.tap(find.text('Save Changes'));
    await _settle(tester);
    expect(
      find.text('The passphrase doesn’t unlock this private key.'),
      findsOneWidget,
    );

    await tester.enterText(_field('Key passphrase'), 'hunter2');
    await tester.tap(find.text('Save Changes'));
    await _settle(tester);
    expect(h.popped, isTrue);
    final saved = h.mem.saved(_id)!;
    expect(saved['privateKey'], contains('BEGIN OPENSSH PRIVATE KEY'));
    expect(saved['passphrase'], 'hunter2');
    expect(saved.containsKey('password'), isFalse);
  });

  testWidgets('Import Key File reads the picked key', (tester) async {
    final h = _Host()..pickedFile = testOpenSshKey();
    await h.pump(tester);
    await tester.enterText(_field('SSH username'), 'kevin');
    await tester.tap(find.text('Private Key'));
    await _settle(tester);
    await tester.tap(find.text('Import Key File'));
    await _settle(tester);
    expect(find.text('Private key imported'), findsOneWidget);
    await tester.tap(find.text('Save Changes'));
    await _settle(tester);
    expect(h.mem.saved(_id)!['privateKey'], contains('OPENSSH PRIVATE KEY'));
  });

  testWidgets('changing the server forgets the trusted fingerprint', (
    tester,
  ) async {
    final h = _Host()
      ..seed(
        const HmSshConfig(
          host: 'old',
          username: 'kevin',
          password: 'pw',
          hostKeyType: 'ssh-ed25519',
          hostKeyFingerprint: 'SHA256:x',
        ),
      );
    await h.pump(tester);
    await tester.enterText(_field('SSH host'), 'new');
    await tester.tap(find.text('Save Changes'));
    await _settle(tester);
    expect(h.mem.saved(_id)!['host'], 'new');
    expect(h.mem.saved(_id)!['hostKeyFingerprint'], isNull);
  });

  testWidgets('store errors show the official read and save messages', (
    tester,
  ) async {
    final h = _Host()..mem.failRead = true;
    await h.pump(tester);
    expect(
      find.text('The terminal settings could not be read. Try again.'),
      findsOneWidget,
    );

    h.mem.failRead = false;
    h.mem.failWrite = true;
    await tester.tap(find.text('Try Again'));
    await _settle(tester);
    await tester.enterText(_field('SSH username'), 'kevin');
    await tester.enterText(_field('SSH password'), 'pw');
    await tester.tap(find.text('Save Changes'));
    await _settle(tester);
    expect(
      find.text('The terminal settings could not be saved. Try again.'),
      findsOneWidget,
    );
    expect(h.popped, isNull);
  });

  testWidgets('instance settings Terminal row shows Add SSH or Mosh, then '
      'the saved user@host', (tester) async {
    final mem = MemCredentialStore();
    final store = HmSshStore(store: mem);
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              HmTerminalSettingsSection(
                store: store,
                instances: const [
                  HmTerminalInstance(
                    id: _id,
                    label: 'Studio',
                    defaultHost: 'studio.local',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.text('Terminal Connection'), findsOneWidget);
    expect(find.text('Add SSH or Mosh'), findsOneWidget);
    expect(
      find.text(
        'Open a terminal in each chat’s working folder. Your dashboard connection stays as configured.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Terminal Connection'));
    await _settle(tester);
    expect(find.text('SSH host'), findsOneWidget);
    await tester.enterText(_field('SSH username'), 'kevin');
    await tester.enterText(_field('SSH password'), 'pw');
    await tester.tap(find.text('Save Changes'));
    await _settle(tester);
    expect(find.text('kevin@studio.local'), findsOneWidget);
  });
}
