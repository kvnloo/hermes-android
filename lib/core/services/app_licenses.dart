import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool _registered = false;

/// Adds local application and third-party notices without reading assets yet.
void registerAppLicenses({AssetBundle? assetBundle}) {
  if (_registered) return;
  _registered = true;

  LicenseRegistry.addLicense(() async* {
    final bundle = assetBundle ?? rootBundle;
    const notices = <String, String>{
      'LICENSE': 'z0 Agent, based on Ares by Sam Russell (MIT)',
      'NOTICE.md': 'z0 Agent, based on Ares by Sam Russell (MIT)',
      'assets/fonts/OFL.txt': 'Cinzel',
      'assets/fonts/geist/OFL.txt': 'Geist and Geist Mono',
      'third_party/licenses/kyllene-MIT.txt':
          'Kyllene (NextGen design and connection model, source material)',
      'third_party/embedded-push-notice.md': 'embedded-fcm-distributor (3.1.0)',
      'third_party/embedded-push-relink.md': 'embedded-fcm-distributor (3.1.0)',
      'third_party/licenses/embedded-fcm-distributor-LGPL-2.1.txt':
          'embedded-fcm-distributor (3.1.0)',
      'third_party/NOTICE.md': 'Third-party source/build materials (scope)',
      'third_party/licenses/graphify-MIT.txt':
          'Graphify viewer template (source material)',
      'third_party/licenses/hermes-agent-MIT.txt':
          'Hermes Agent message templates (source material)',
      'third_party/licenses/flutter-BSD-3-Clause.txt':
          'Flutter iOS scaffold (source material)',
      'third_party/licenses/Apache-2.0.txt':
          'Gradle wrapper (Library build material)',
      'third_party/licenses/gradle-NOTICE.txt':
          'Gradle wrapper (Library build material)',
      'third_party/elemental-ui/LICENSE':
          'elemental-ui materials and lighting (GPL-3.0-only)',
      'assets/fonts/nunito/OFL.txt': 'Nunito',
      'third_party/ai-elements-persona/LICENSE.ai-elements':
          'AI Elements Persona',
      'third_party/ai-elements-persona/LICENSE-2.0.txt': 'AI Elements Persona',
      'third_party/thinking-orbs/LICENSE': 'thinking-orbs',
      'third_party/syn-face/LICENSES.md': 'Syn face (Moodie and bloub)',
      'third_party/flutter_tts_android/LICENSE': 'flutter_tts (Android patch)',
      'third_party/voice/NOTICE.md': 'sherpa-onnx and wake model',
      'third_party/voice/licenses/sherpa-onnx-Apache-2.0.txt':
          'sherpa-onnx and wake model',
      'third_party/voice/licenses/onnxruntime-MIT.txt': 'ONNX Runtime',
    };
    for (final notice in notices.entries) {
      yield LicenseEntryWithLineBreaks([
        notice.value,
      ], await bundle.loadString(notice.key));
    }
  });
}
