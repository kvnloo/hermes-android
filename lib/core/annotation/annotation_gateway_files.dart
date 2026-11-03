import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/attachment_draft.dart';
import '../services/attachment_draft_service.dart';
import '../services/desktop_gateway_client.dart';
import 'annotation_compose.dart';
import 'annotation_voice_send.dart';

/// Uploads the actual ink-composited PNG and the parent's annotation JSON using
/// the app's existing sanitized attachment-draft lifecycle and file.attach RPC.
/// Snapshot capture owns the original PNG path; this class never redraws ink.
class AnnotationGatewayFiles {
  AnnotationGatewayFiles({
    required this.draftService,
    required this.gateway,
    required this.sessionId,
    required this.captureAnnotatedImage,
  });

  final AttachmentDraftService draftService;
  final DesktopGatewayClient gateway;
  final String sessionId;
  final Future<String> Function() captureAnnotatedImage;

  Future<String> preparePrompt(AnnotationSendEnvelope envelope) async {
    final names = attachmentNames(envelope.createdAt);
    final drafts = <AttachmentDraft>[];
    File? documentSource;
    try {
      // The screenshot producer composites the actual captured content and
      // the same strokes included in envelope.document.
      final screenshot = await captureAnnotatedImage();
      drafts.add(
        await draftService.prepareImage(
          sourcePath: screenshot,
          displayName: names['image']!,
          existingDrafts: drafts,
          mode: AttachmentDraftMode.remoteGateway,
        ),
      );

      final temp = await getTemporaryDirectory();
      documentSource = File(
        temp.path +
            Platform.pathSeparator +
            'annotation-document-' +
            const Uuid().v4() +
            '.json',
      );
      await documentSource.writeAsString(
        jsonEncode(envelope.document),
        flush: true,
      );
      drafts.add(
        await draftService.prepareGenericFile(
          sourcePath: documentSource.path,
          displayName: names['json']!,
          mediaType: 'application/json',
          existingDrafts: drafts,
        ),
      );

      final receipts = await draftService.uploadSequential(
        drafts: drafts,
        upload: ({required draft, required dataUrl}) async {
          final receipt = await gateway.attachFile(
            sessionId: sessionId,
            name: draft.name,
            dataUrl: dataUrl,
          );
          return AttachmentUploadReceipt(
            refText: receipt.refText,
            atlasIntakeAccepted: receipt.atlasIntakeAccepted,
          );
        },
      );
      if (receipts.length != 2 ||
          receipts.any((receipt) => receipt.refText.trim().isEmpty)) {
        throw StateError('Both annotation attachments require a gateway receipt.');
      }
      return [
        envelope.text,
        for (final receipt in receipts) receipt.refText,
      ].join('\n\n');
    } finally {
      // The source screenshot remains owned by the capture layer. Uploaded
      // sanitized draft copies and temporary JSON never leak into local files.
      await draftService.removeAll(drafts);
      if (documentSource != null && await documentSource.exists()) {
        await documentSource.delete();
      }
    }
  }
}
