import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/ng_elemental.dart';
import 'package:hermes_android/nextgen/theme/ng_theme_spec.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:hermes_android/nextgen/ui/ng_elemental_pane.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final look = NextGenLook.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() async {
      SharedPreferences.setMockInitialValues({});
      NextGenPreferences.load(await SharedPreferences.getInstance());
    });
  });

  // A material must never push a role below AA that Solid keeps above it.
  void expectReadable(Color role, Color plain, Iterable<Color> extremes) {
    final floor = contrastRatio(role, plain) >= 4.5 ? 4.5 : 0.0;
    for (final bg in extremes) {
      expect(contrastRatio(role, bg), greaterThanOrEqualTo(floor));
    }
  }

  for (final brightness in Brightness.values) {
    for (final preset in ngThemePresets) {
      for (final material in NgMaterial.values.where((m) => m.visible)) {
        test(
          '${preset.id}/${brightness.name}/${material.name} keeps AA text',
          () {
            look
              ..themeId = preset.id
              ..material = material;
            final solid = NgColors.build(
              brightness,
              look.accent,
              false,
              true,
              preset,
            );
            final theme = nextGenTheme(brightness, look);
            final c = theme.extension<NgColors>()!;
            // The opaque background moves to the root scene.
            expect(theme.scaffoldBackgroundColor.a, 0);
            expect(c.glassScene, solid.background);
            final sceneDose = ngSceneDose(c, material);
            final chromeDose = ngChromeDose(c, material);
            // The material stays visible: the body or its light survives.
            expect(sceneDose.bodyOpacity + sceneDose.sheen, greaterThan(0));
            expect(
              sceneDose.bodyOpacity,
              lessThanOrEqualTo(material.bodyOpacity),
            );
            expect(sceneDose.sheen, lessThanOrEqualTo(material.sheen));
            final scene = ngMaterialExtremes(
              material,
              c.glassScene!,
              sceneDose,
            );
            for (final role in [c.text, c.text2, c.text3, c.textMuted]) {
              expectReadable(role, solid.background, scene);
            }
            // The composer's text and hint sit on the Liquid Glass lens, over
            // the lit scene, with its own slab of material.
            final tint = ngLiquidTint(c);
            final chrome = [
              for (final lit in scene)
                ...ngMaterialExtremes(
                  material,
                  Color.alphaBlend(tint, lit),
                  chromeDose,
                ),
            ];
            final lens = Color.alphaBlend(tint, solid.background);
            for (final role in [c.text, c.text2, c.text3]) {
              expectReadable(role, lens, chrome);
            }
          },
        );
      }
    }
  }

  test('no material leaves Solid exactly as before', () {
    look.material = NgMaterial.none;
    final theme = nextGenTheme(Brightness.dark, look);
    final c = theme.extension<NgColors>()!;
    expect(c.glassScene, isNull);
    expect(theme.scaffoldBackgroundColor.a, 1);
    expect(theme.drawerTheme.backgroundColor, c.sidebar);
  });

  test('a material keeps the opaque sidebar for the drawer', () {
    look.material = NgMaterial.basalt;
    final theme = nextGenTheme(Brightness.light, look);
    final c = theme.extension<NgColors>()!;
    expect(theme.drawerTheme.backgroundColor, c.sidebar);
    expect(c.sidebar.a, 1);
  });

  test('Glass with a material keeps the Glass tint and its floors', () {
    look
      ..surface = NgSurface.glass
      ..material = NgMaterial.water;
    final withMaterial = nextGenTheme(
      Brightness.dark,
      look,
      transparentWindow: true,
      blurredWindow: true,
    ).extension<NgColors>()!;
    look.material = NgMaterial.none;
    final plain = nextGenTheme(
      Brightness.dark,
      look,
      transparentWindow: true,
      blurredWindow: true,
    ).extension<NgColors>()!;
    expect(withMaterial.glassScene, plain.glassScene);
    expect(withMaterial.surface, plain.surface);
    expect(withMaterial.text, plain.text);
  });

  test('material and Liquid Glass round-trip through preferences', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(look.material, NgMaterial.none);
    expect(look.liquid, isFalse);
    await NextGenPreferences.setMaterial(prefs, NgMaterial.quartz);
    await NextGenPreferences.setLiquid(prefs, true);
    expect(prefs.getString(NextGenPreferences.materialKey), 'quartz');
    look
      ..material = NgMaterial.none
      ..liquid = false;
    NextGenPreferences.load(prefs);
    expect(look.material, NgMaterial.quartz);
    expect(look.liquid, isTrue);
  });

  test('damaged material and Liquid Glass values fall back to off', () async {
    SharedPreferences.setMockInitialValues({
      NextGenPreferences.materialKey: 7,
      NextGenPreferences.liquidKey: 'yes',
    });
    final prefs = await SharedPreferences.getInstance();
    NextGenPreferences.load(prefs);
    expect(look.material, NgMaterial.none);
    expect(look.liquid, isFalse);
    expect(NgMaterial.parse('obsidian'), NgMaterial.none);
  });

  test('Glass checks the material over dark, light and mid wallpapers', () {
    look
      ..surface = NgSurface.glass
      ..material = NgMaterial.quartz;
    final c = nextGenTheme(
      Brightness.dark,
      look,
      transparentWindow: true,
      blurredWindow: true,
    ).extension<NgColors>()!;
    final backdrops = ngSceneBackdrops(c);
    expect(backdrops, hasLength(3));
    final dose = ngSceneDose(c, NgMaterial.quartz);
    for (final backdrop in backdrops) {
      for (final role in [c.text, c.text2]) {
        expectReadable(
          role,
          backdrop,
          ngMaterialExtremes(NgMaterial.quartz, backdrop, dose),
        );
      }
    }
  });

  test('the dose solver drops glare before stone on dark themes', () {
    const background = Color(0xFF0B0B0D);
    const muted = Color(0xFF8A8A93);
    final dose = ngSafeMaterialDose(
      NgMaterial.basalt,
      [background],
      [Colors.white, muted],
    );
    expect(dose.bodyOpacity, NgMaterial.basalt.bodyOpacity);
    expect(dose.sheen, lessThan(NgMaterial.basalt.sheen));
    expect(
      ngSafeMaterialDose(NgMaterial.none, [background], [muted]),
      NgMaterialDose.none,
    );
  });

  test('shader uniforms follow elemental_glass.frag declaration order', () {
    final uniforms = ngElementalUniforms(
      size: const Size(360, 780),
      material: NgMaterial.limestone,
      dose: const NgMaterialDose(5, 9),
      time: 0,
      dark: true,
      origin: const Offset(4, 600),
    );
    // uSize(2) uTilePx uTime uLight(4) uBody(4) uParams(4) uOffset(2).
    expect(uniforms, hasLength(18));
    expect(uniforms.sublist(0, 2), [360, 780]);
    expect(uniforms[11], ngMaxBodyOpacity); // body opacity is clamped
    expect(uniforms[12], 0); // a pack
    expect(uniforms[14], 2); // sheen gain is clamped
    expect(uniforms.sublist(16), [4, 600]);
    final water = ngElementalUniforms(
      size: Size.zero,
      material: NgMaterial.water,
      dose: const NgMaterialDose(0.1, 0.3),
      time: 1,
      dark: false,
      origin: Offset.zero,
    );
    expect(water[2], 220);
    expect(water[12], 1);
    expect(water[15], 1.25);
  });

  testWidgets('the scene is plain until a material is chosen', (tester) async {
    await tester.pumpWidget(
      const NgScene(
        color: Color(0xFF101012),
        material: NgMaterial.none,
        child: SizedBox.expand(),
      ),
    );
    expect(find.byType(NgElementalPane), findsNothing);
    expect(
      tester.widget<ColoredBox>(find.byType(ColoredBox)).color,
      const Color(0xFF101012),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: nextGenTheme(Brightness.dark, look),
        home: const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: NgScene(
            color: Color(0xFF101012),
            material: NgMaterial.slate,
            child: SizedBox.expand(),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('ng-elemental-scene')), findsOneWidget);
    // The pane never takes touches from the app above it.
    expect(
      find.ancestor(
        of: find.byType(NgElementalPane),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
    );
  });

  testWidgets('Liquid Glass chrome falls back to the plain decoration', (
    tester,
  ) async {
    const decoration = BoxDecoration(color: Color(0xFF202024));
    Widget chrome(bool enabled) => MaterialApp(
      home: Center(
        child: NgLiquidChrome(
          enabled: enabled,
          material: NgMaterial.none,
          tint: const Color(0x99202024),
          rim: Colors.white,
          radius: 32,
          fallback: decoration,
          child: const Text('composer'),
        ),
      ),
    );
    await tester.pumpWidget(chrome(false));
    expect(find.byKey(const ValueKey('ng-liquid-chrome')), findsNothing);
    expect(
      tester.widget<Container>(find.byType(Container).last).decoration,
      decoration,
    );

    await tester.pumpWidget(chrome(true));
    await tester.pump();
    expect(find.byKey(const ValueKey('ng-liquid-chrome')), findsOneWidget);
    expect(find.text('composer'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
