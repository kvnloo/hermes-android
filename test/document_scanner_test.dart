import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/services/attachment_draft_service.dart';
import 'package:hermes_android/core/services/document_scanner.dart';
import 'package:image/image.dart' as image;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const scanner = DocumentScanner();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory directory;
  late AttachmentDraftService service;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    directory = await Directory.systemTemp.createTemp('document-scanner-test');
    service = AttachmentDraftService(
      cacheDirectoryProvider: () async {
        return Directory('${directory.path}/drafts').create(recursive: true);
      },
    );
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(DocumentScanner.channel, null);
    await directory.delete(recursive: true);
  });

  Future<({List<AttachmentDraft> drafts, int skipped})?> scan({
    AttachmentDraftMode mode = AttachmentDraftMode.remoteGateway,
    List<AttachmentDraft> existing = const [],
  }) => scanner.scanIntoDraft(
    service: service,
    mode: mode,
    existingDrafts: existing,
  );

  Future<List<Map<String, String>>> nativeResult() async {
    final pdf = await File(
      '${directory.path}/native.pdf',
    ).writeAsString('%PDF-1.7\n');
    final jpg = await File(
      '${directory.path}/native.jpg',
    ).writeAsBytes(image.encodeJpg(image.Image(width: 20, height: 20)));
    return [
      {'path': pdf.path, 'format': 'pdf'},
      {'path': jpg.path, 'format': 'jpg'},
    ];
  }

  test('availability is Android only and handles an absent channel', () async {
    expect(await scanner.isAvailable(), isFalse);
    messenger.setMockMethodCallHandler(DocumentScanner.channel, (call) async {
      expect(call.method, 'isAvailable');
      expect(call.arguments, isNull);
      return true;
    });
    expect(await scanner.isAvailable(), isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(await scanner.isAvailable(), isFalse);
  });

  test('cancellation returns null without staging any draft', () async {
    messenger.setMockMethodCallHandler(DocumentScanner.channel, (call) async {
      expect(call.method, 'scan');
      expect(call.arguments, {'singlePage': false});
      return null;
    });
    expect(await scan(), isNull);
    expect(directory.listSync(), isEmpty);
  });

  test('module error stays typed and stages nothing', () async {
    messenger.setMockMethodCallHandler(DocumentScanner.channel, (call) async {
      throw PlatformException(code: 'module_unavailable');
    });
    await expectLater(
      scan(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'module_unavailable',
        ),
      ),
    );
    expect(directory.listSync(), isEmpty);
  });

  test(
    'maps PDF and JPEG to independent standard drafts and deletes sources',
    () async {
      final result = await nativeResult();
      messenger.setMockMethodCallHandler(DocumentScanner.channel, (_) async {
        return result;
      });
      final staged = (await scan())!;
      expect(staged.skipped, 0);
      expect(staged.drafts.map((draft) => draft.name), [
        'Document scan.pdf',
        'Scan page 1.jpg',
      ]);
      expect(staged.drafts.map((draft) => draft.mediaType), [
        'application/pdf',
        'image/jpeg',
      ]);
      expect(staged.drafts.map((draft) => draft.kind), [
        AttachmentDraftKind.genericFile,
        AttachmentDraftKind.image,
      ]);
      expect(staged.drafts.last.sanitized, isTrue);
      for (final item in result) {
        expect(File(item['path']!).existsSync(), isFalse);
      }
      expect(
        File(staged.drafts.first.cachedPath).readAsStringSync(),
        '%PDF-1.7\n',
      );
    },
  );

  test(
    'REST requests one page, attaches only JPEG and deletes both sources',
    () async {
      final result = await nativeResult();
      messenger.setMockMethodCallHandler(DocumentScanner.channel, (call) async {
        expect(call.arguments, {'singlePage': true});
        return result;
      });
      final staged = (await scan(mode: AttachmentDraftMode.rest))!;
      expect(staged.drafts.single.mediaType, 'image/jpeg');
      expect(staged.skipped, 0);
      for (final item in result) {
        expect(File(item['path']!).existsSync(), isFalse);
      }
    },
  );

  test(
    'the last available slot goes to the PDF and the page is skipped',
    () async {
      final result = await nativeResult();
      final previous = await service.prepareGenericFile(
        sourcePath: result.first['path']!,
        displayName: 'previous.pdf',
        existingDrafts: [],
      );
      messenger.setMockMethodCallHandler(DocumentScanner.channel, (_) async {
        return result;
      });
      final staged = (await scan(
        existing: List.filled(maxRemoteAttachmentDrafts - 1, previous),
      ))!;
      expect(staged.drafts.single.mediaType, 'application/pdf');
      expect(staged.skipped, 1);
      expect(File(previous.cachedPath).existsSync(), isTrue);
    },
  );
}
