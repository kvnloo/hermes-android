import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/attachment_draft.dart';
import 'attachment_draft_service.dart';

class DocumentScanner {
  const DocumentScanner();

  static const channel = MethodChannel(
    'com.hermesagent.hermes_android/document_scanner',
  );

  Future<bool> isAvailable() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await channel.invokeMethod<bool>('isAvailable') == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Takes ownership of the native staging files until they have been copied
  /// to normal draft storage. A null result leaves the draft untouched.
  Future<({List<AttachmentDraft> drafts, int skipped})?> scanIntoDraft({
    required AttachmentDraftService service,
    required List<AttachmentDraft> existingDrafts,
    required AttachmentDraftMode mode,
    int maxTotalBytes = maxRemoteAttachmentDraftBytes,
  }) async {
    final singlePage = mode == AttachmentDraftMode.rest;
    final result = await channel.invokeListMethod<Map<Object?, Object?>>(
      'scan',
      {'singlePage': singlePage},
    );
    if (result == null) return null;

    final drafts = <AttachmentDraft>[];
    var skipped = 0;
    var page = 0;
    try {
      if (result.isEmpty) throw PlatformException(code: 'invalid_result');
      for (final item in result) {
        if (singlePage && drafts.isNotEmpty) break;
        final path = item['path'];
        final format = item['format'];
        if (format == 'pdf' && singlePage) continue;
        if (format == 'jpg') page++;
        try {
          if (path is! String || path.isEmpty) {
            throw PlatformException(code: 'invalid_result');
          }
          final existing = [...existingDrafts, ...drafts];
          switch (format) {
            case 'pdf':
              drafts.add(
                await service.prepareGenericFile(
                  sourcePath: path,
                  displayName: 'Document scan.pdf',
                  mediaType: 'application/pdf',
                  existingDrafts: existing,
                  maxTotalBytes: maxTotalBytes,
                ),
              );
            case 'jpg':
              drafts.add(
                await service.prepareImage(
                  sourcePath: path,
                  displayName: 'Scan page $page.jpg',
                  existingDrafts: existing,
                  mode: mode,
                  maxTotalBytes: maxTotalBytes,
                ),
              );
            default:
              skipped++;
          }
        } on AttachmentDraftException {
          skipped++;
        } on FileSystemException {
          skipped++;
        }
      }
      if (drafts.isEmpty) throw PlatformException(code: 'invalid_result');
      return (drafts: drafts, skipped: skipped);
    } catch (_) {
      await service.removeAll(drafts);
      rethrow;
    } finally {
      for (final item in result) {
        final path = item['path'];
        if (path is String && path.isNotEmpty) {
          try {
            await File(path).delete();
          } on FileSystemException {
            // The file may already have been evicted from cache.
          }
        }
      }
    }
  }
}
