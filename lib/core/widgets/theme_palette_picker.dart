import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../services/glass_window_service.dart';
import '../services/theme_preference.dart';
import '../theme/hermes_surface.dart';
import '../theme/hermes_theme.dart';
import 'hermes_glass_backdrop.dart';

String paletteLabel(BuildContext context, HermesPalette palette) {
  final l10n = context.l10n;
  return switch (palette) {
    HermesPalette.gold => l10n.theme_palette_gold,
    HermesPalette.purple => l10n.theme_palette_purple,
    HermesPalette.orange => l10n.theme_palette_orange,
    HermesPalette.green => l10n.theme_palette_green,
    HermesPalette.blue => l10n.theme_palette_blue,
    HermesPalette.red => l10n.theme_palette_red,
    HermesPalette.teal => l10n.theme_palette_teal,
    HermesPalette.pink => l10n.theme_palette_pink,
    HermesPalette.indigo => l10n.theme_palette_indigo,
    HermesPalette.cyan => l10n.theme_palette_cyan,
    HermesPalette.mono => l10n.theme_palette_mono,
  };
}

String materialLabel(BuildContext context, HermesMaterial material) {
  final l10n = context.l10n;
  return switch (material) {
    HermesMaterial.none => l10n.theme_material_none,
    HermesMaterial.water => l10n.theme_material_water,
    HermesMaterial.quartz => l10n.theme_material_quartz,
    HermesMaterial.slate => l10n.theme_material_slate,
    HermesMaterial.basalt => l10n.theme_material_basalt,
    HermesMaterial.limestone => l10n.theme_material_limestone,
  };
}

/// Reused by Settings and the connection screen; never needs a gateway.
class ThemeAppearanceSettings extends StatelessWidget {
  const ThemeAppearanceSettings({
    required this.preferences,
    this.onChanged,
    super.key,
  });

  final SharedPreferences preferences;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ThemeModePicker(preferences: preferences, onChanged: onChanged),
        const SizedBox(height: 8),
        ThemePalettePicker(preferences: preferences, onChanged: onChanged),
        const SizedBox(height: 8),
        SurfaceStylePicker(preferences: preferences, onChanged: onChanged),
      ],
    );
  }
}

/// Surface personalization: Solid or Glass, the glass recipe, an Elemental
/// material and quiet chrome. Changes apply live except Solid/Glass, which
/// needs the window recreated.
class SurfaceStylePicker extends StatefulWidget {
  const SurfaceStylePicker({
    required this.preferences,
    this.onChanged,
    this.window,
    super.key,
  });

  final SharedPreferences preferences;
  final VoidCallback? onChanged;

  /// Injected in tests; defaults to the shared platform bridge.
  final GlassWindowService? window;

  @override
  State<SurfaceStylePicker> createState() => _SurfaceStylePickerState();
}

class _SurfaceStylePickerState extends State<SurfaceStylePicker> {
  GlassWindowService get _window => widget.window ?? GlassWindowService.shared;

  // Slider positions while dragging; saved (and applied app-wide) on release.
  double? _tintDrag;
  double? _blurDrag;

  ThemePreferenceStore get _store => ThemePreferenceStore(widget.preferences);

  Future<void> _save(HermesSurfaceStyle next) async {
    final onChanged = widget.onChanged;
    try {
      await _store.saveSurface(next);
      await _window.applyStyle(next);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.failed(error))));
      }
    } finally {
      if (mounted) setState(() {});
      onChanged?.call();
    }
  }

  Future<void> _selectMode(HermesSurfaceMode mode) async {
    final current = _store.readSurface();
    if (current.mode == mode) return;
    final next = current.copyWith(mode: mode);
    if (!_window.needsRecreate(next)) return _save(next);
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.theme_surface_reload_title),
        content: Text(l10n.theme_surface_reload_body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            key: const Key('theme_surface_reload_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.theme_surface_reload_action),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _save(next);
    await _window.recreateWindow();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = HermesTokens.of(context);
    final style = _store.readSurface();
    final glass = style.isGlass;
    final blurOff = glass && _window.capabilities.crossWindowBlur == false;
    final floor = HermesSurface.tintFloor(tokens);
    final tint =
        (_tintDrag ??
                style.tint ??
                HermesSurface.presetTint(style.preset, tokens))
            .clamp(floor, HermesSurface.tintMax)
            .toDouble();
    final blur = _blurDrag ?? style.effectiveBlur;
    return Card(
      key: const Key('theme_surface_picker'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.theme_surface,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            SegmentedButton<HermesSurfaceMode>(
              key: const Key('theme_surface_mode'),
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: HermesSurfaceMode.solid,
                  icon: const Icon(Icons.crop_square_rounded, size: 18),
                  label: Text(l10n.theme_surface_solid),
                ),
                ButtonSegment(
                  value: HermesSurfaceMode.glass,
                  icon: const Icon(Icons.blur_on_rounded, size: 18),
                  label: Text(l10n.theme_surface_glass),
                ),
              ],
              selected: {style.mode},
              onSelectionChanged: (value) => _selectMode(value.first),
            ),
            if (glass) ...[
              const SizedBox(height: 8),
              Text(
                l10n.theme_surface_glass_hint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in HermesGlassPreset.values)
                    ChoiceChip(
                      key: Key('theme_glass_${preset.name}'),
                      label: Text(switch (preset) {
                        HermesGlassPreset.clear => l10n.theme_glass_clear,
                        HermesGlassPreset.frost => l10n.theme_glass_frost,
                        HermesGlassPreset.deep => l10n.theme_glass_deep,
                      }),
                      selected:
                          style.preset == preset &&
                          style.tint == null &&
                          style.blur == null,
                      showCheckmark: false,
                      onSelected: (_) => _save(
                        style.copyWith(preset: preset, clearCustom: true),
                      ),
                    ),
                ],
              ),
              _LabeledSlider(
                key: const Key('theme_glass_tint'),
                label: l10n.theme_glass_tint,
                value: tint,
                min: floor,
                max: HermesSurface.tintMax,
                display: '${(tint * 100).round()}%',
                onChanged: (v) => setState(() => _tintDrag = v),
                onChangeEnd: (v) {
                  _tintDrag = null;
                  _save(style.copyWith(tint: v));
                },
              ),
              _LabeledSlider(
                key: const Key('theme_glass_blur'),
                label: l10n.theme_glass_blur,
                value: blur,
                min: 0,
                max: HermesSurfaceStyle.maxBlur,
                divisions: 20,
                display: '${blur.round()} dp',
                onChanged: (v) => setState(() => _blurDrag = v),
                onChangeEnd: (v) {
                  _blurDrag = null;
                  _save(style.copyWith(blur: v));
                },
              ),
              if (blurOff)
                Text(
                  l10n.theme_glass_blur_off,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: tokens.warning),
                ),
              const SizedBox(height: 12),
              Text(
                l10n.theme_material,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final material in HermesMaterial.values)
                    _MaterialSwatch(
                      material: material,
                      selected: style.material == material,
                      onTap: () => _save(style.copyWith(material: material)),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('theme_quiet_chrome'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.theme_quiet_chrome),
              subtitle: Text(l10n.theme_quiet_chrome_hint),
              value: style.quietChrome,
              onChanged: (v) => _save(style.copyWith(quietChrome: v)),
            ),
            if (glass)
              SwitchListTile(
                key: const Key('theme_liquid_chrome'),
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.theme_liquid_chrome),
                subtitle: Text(l10n.theme_liquid_chrome_hint),
                value: style.liquidChrome,
                onChanged: (v) => _save(style.copyWith(liquidChrome: v)),
              ),
          ],
        ),
      ),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
    this.onChangeEnd,
    this.divisions,
    super.key,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        SizedBox(width: 56, child: Text(label, style: textTheme.labelLarge)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            semanticFormatterCallback: (_) => display,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            display,
            textAlign: TextAlign.end,
            style: textTheme.labelMedium,
          ),
        ),
      ],
    );
  }
}

/// A live, lit sample of the material over a dusk gradient, so the swatch
/// shows what the pane does to a wallpaper rather than a flat colour chip.
class _MaterialSwatch extends StatelessWidget {
  const _MaterialSwatch({
    required this.material,
    required this.selected,
    required this.onTap,
  });

  final HermesMaterial material;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final label = materialLabel(context, material);
    return Semantics(
      key: Key('theme_material_${material.name}'),
      label: label,
      button: true,
      selected: selected,
      onTap: onTap,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 76,
            child: Column(
              children: [
                Container(
                  height: 56,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: selected ? tokens.accent : tokens.border,
                      width: selected ? 2 : 1,
                    ),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: HermesGlassInk.dusk,
                    ),
                  ),
                  child: material.visible
                      ? ElementalPane(material: material, strength: 2.2)
                      : null,
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: selected ? tokens.accent : tokens.onSurface,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Labeled swatches remain identifiable without color vision or a touch screen.
class ThemePalettePicker extends StatefulWidget {
  const ThemePalettePicker({
    required this.preferences,
    this.onChanged,
    super.key,
  });

  final SharedPreferences preferences;

  /// Called after the saved preference, or a failed save's rollback, settles.
  final VoidCallback? onChanged;

  @override
  State<ThemePalettePicker> createState() => _ThemePalettePickerState();
}

class _ThemePalettePickerState extends State<ThemePalettePicker> {
  Future<void> _select(HermesPalette palette) async {
    final onChanged = widget.onChanged;
    try {
      await ThemePreferenceStore(widget.preferences).savePalette(palette);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.failed(error))));
      }
    } finally {
      if (mounted) setState(() {});
      // The app outlives this picker and still needs the settled save/rollback.
      onChanged?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final selected = ThemePreferenceStore(widget.preferences).readPalette();
    return Card(
      key: const Key('theme_palette_picker'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.theme_palette,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final palette in HermesPalette.values)
                  Semantics(
                    key: Key('theme_palette_${palette.name}'),
                    label: paletteLabel(context, palette),
                    button: true,
                    selected: palette == selected,
                    onTap: () => _select(palette),
                    child: ExcludeSemantics(
                      child: SizedBox(
                        width: 104,
                        child: Material(
                          color: palette == selected
                              ? tokens.accentContainer
                              : tokens.raised,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            onTap: () => _select(palette),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: palette == selected
                                      ? tokens.accent
                                      : tokens.border,
                                  width: palette == selected ? 2 : 1,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: palette.seedColor,
                                      border: Border.all(
                                        color: foregroundFor(palette.seedColor),
                                      ),
                                    ),
                                    child: palette == selected
                                        ? Icon(
                                            Icons.check,
                                            color: foregroundFor(
                                              palette.seedColor,
                                            ),
                                            size: 22,
                                          )
                                        : null,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    paletteLabel(context, palette),
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(
                                          color: palette == selected
                                              ? tokens.onAccentContainer
                                              : tokens.onSurface,
                                          fontWeight: palette == selected
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ThemeModePicker extends StatefulWidget {
  const ThemeModePicker({required this.preferences, this.onChanged, super.key});

  final SharedPreferences preferences;
  final VoidCallback? onChanged;

  @override
  State<ThemeModePicker> createState() => _ThemeModePickerState();
}

class _ThemeModePickerState extends State<ThemeModePicker> {
  Future<void> _select(ThemeMode mode) async {
    final onChanged = widget.onChanged;
    try {
      await ThemePreferenceStore(widget.preferences).saveMode(mode);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.failed(error))));
      }
    } finally {
      if (mounted) setState(() {});
      onChanged?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = ThemePreferenceStore(widget.preferences).readMode();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final mode in ThemeMode.values)
          ChoiceChip(
            key: Key('theme_mode_${mode.name}'),
            avatar: Icon(switch (mode) {
              ThemeMode.system => Icons.brightness_auto,
              ThemeMode.light => Icons.light_mode,
              ThemeMode.dark => Icons.dark_mode,
            }, size: 18),
            label: Text(switch (mode) {
              ThemeMode.system => context.l10n.system,
              ThemeMode.light => context.l10n.light,
              ThemeMode.dark => context.l10n.dark,
            }),
            selected: selected == mode,
            showCheckmark: false,
            onSelected: (_) => _select(mode),
          ),
      ],
    );
  }
}
