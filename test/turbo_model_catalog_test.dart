import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/turbo_model_catalog.dart';

void main() {
  test('Turbo detection is based on advertised router provenance', () {
    expect(isTurboModelRoute('nous', 'ordinary-model'), isFalse);
    expect(isTurboModelRoute('vllm-sr', 'turbo'), isTrue);
    expect(isTurboModelRoute('nous', 'vllm-sr/free-reasoning'), isTrue);
    expect(isTurboModelRoute('not-vllm-sr', 'free-quality'), isFalse);
  });

  test('canonical and alias names have the same Turbo order', () {
    expect(turboModelAlias('vllm-sr/turbo'), 'turbo');
    expect(turboModelAlias('free-reasoning'), 'free-reasoning');
    final models = turboVirtualModelIds.reversed.toList()
      ..sort(compareTurboModelIds);
    expect(models, turboVirtualModelIds);
    final aliases = <String>[
      'free-longctx',
      'free-verify',
      'free-quality',
      'turbo',
      'free-reasoning',
    ]..sort(compareTurboModelIds);
    expect(aliases, <String>[
      'turbo',
      'free-quality',
      'free-reasoning',
      'free-verify',
      'free-longctx',
    ]);
  });
}
