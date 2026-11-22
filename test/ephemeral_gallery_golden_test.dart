// One golden per ephemeral-ui catalog kind, rendered with real fonts.
// Regenerate after re-vendoring the catalog or changing a layout:
//   flutter test test/ephemeral_gallery_golden_test.dart --update-goldens
// Output: test/goldens/ephemeral/<kind>.png (360 logical px wide, 2x).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/ephemeral/ephemeral_catalog.dart';
import 'package:hermes_android/core/ephemeral/ephemeral_gallery_screen.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';

const _goldenDir = 'test/goldens/ephemeral';

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(File(f).readAsBytes().then((b) => ByteData.sublistView(b)));
  }
  await loader.load();
}

void main() {
  final catalog = EphemeralCatalog.parse(
    File(EphemeralCatalogAssets.catalog).readAsStringSync(),
  );
  final sdkFonts =
      '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts';

  setUpAll(() async {
    // The app font is the platform default (Roboto on Android); tests have
    // no platform font, so load Roboto and map `monospace` to GeistMono.
    await _font('Roboto', [
      for (final w in ['Regular', 'Medium', 'Bold']) '$sdkFonts/Roboto-$w.ttf',
    ]);
    await _font('MaterialIcons', ['$sdkFonts/MaterialIcons-Regular.otf']);
    List<String> files(String prefix) => Directory('assets/fonts/geist')
        .listSync()
        .map((f) => f.path)
        .where((p) => p.split('/').last.startsWith('$prefix-'))
        .toList();
    await _font('Geist', files('Geist'));
    await _font('GeistMono', files('GeistMono'));
    await _font('monospace', files('GeistMono'));
    await _font('Nunito', [
      'assets/fonts/nunito/Nunito-VariableFont_wght.ttf',
      'assets/fonts/nunito/Nunito-Italic-VariableFont_wght.ttf',
    ]);
  });

  test(
    'a golden exists for exactly the catalog kinds',
    () {
      final kinds = {for (final k in catalog.kinds) '${k.kind}.png'};
      final dir = Directory(_goldenDir);
      final files = dir.existsSync()
          ? {
              for (final f in dir.listSync().whereType<File>())
                f.path.split('/').last,
            }
          : <String>{};
      // A fresh --update-goldens run writes the missing files before this
      // check matters; on CI a new uncovered kind fails here and below.
      expect(
        kinds.difference(files),
        isEmpty,
        reason: 'kinds without a golden (run --update-goldens)',
      );
      expect(
        files.difference(kinds),
        isEmpty,
        reason: 'goldens for kinds not in catalog-v${catalog.version}',
      );
    },
    skip: autoUpdateGoldenFiles ? 'writing goldens' : false,
  );

  for (final kind in catalog.kinds) {
    testWidgets('golden ${kind.kind}', (tester) async {
      tester.view.physicalSize = const Size(720, 8000);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: hermesTheme(Brightness.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: RepaintBoundary(
                key: const Key('golden'),
                child: Container(
                  width: 360,
                  color: HermesTokens.forBrightness(Brightness.dark).raised,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(fontFamily: 'Roboto'),
                    child: EphemeralKindSection(kind: kind),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const Key('golden')),
        matchesGoldenFile('goldens/ephemeral/${kind.kind}.png'),
      );
    });
  }
}
