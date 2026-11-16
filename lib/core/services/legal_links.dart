import 'package:url_launcher/url_launcher.dart';

/// Public policy and safety pages for both distribution channels.
final Uri aresPrivacyPolicyUri = Uri.https(
  'github.com',
  '/kvnloo/hermes-android/blob/z0/play-release/PRIVACY.md',
);

/// Opens a blank safety report. Chat text, credentials and attachment paths are
/// deliberately not added to the URL; the user chooses what to post publicly.
final Uri aresAiOutputReportUri = Uri.https(
  'github.com',
  '/kvnloo/hermes-android/issues/new',
  <String, String>{
    'title': 'z0 Agent AI output report',
    'body':
        'Describe the AI output and why it was unsafe or offensive. '
        'Do not include private chats, credentials, personal data or attachment paths.',
  },
);

Future<bool> openAresPrivacyPolicy() =>
    launchUrl(aresPrivacyPolicyUri, mode: LaunchMode.externalApplication);

Future<bool> reportAresAiOutput() =>
    launchUrl(aresAiOutputReportUri, mode: LaunchMode.externalApplication);
