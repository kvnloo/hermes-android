// A bot's avatar: who it is (a fixed tone, from the profile's ui_meta or its
// name) drawn in the style the person picked (Settings → Look & Feel).
import 'package:flutter/material.dart';

import '../../nextgen/nextgen_preferences.dart';
import '../../nextgen/theme/nextgen_theme.dart';
import 'hm_avatar_state.dart';
import 'persona_orb.dart';
import 'syn_face.dart';
import 'thinking_orb_view.dart';

/// Who a bot is, visually. Stored per bot in the profile's `ui_meta` under
/// `character` (`{seed, color: "#RRGGBB"}`) so every client draws the same.
@immutable
class HmCharacterSpec {
  const HmCharacterSpec({required this.seed, this.color});

  final int seed;
  final Color? color;

  /// Mid tones that read on light and dark substrates alike.
  static const palette = [
    Color(0xFF2F4BD8),
    Color(0xFF7A3FD1),
    Color(0xFF0F8A7E),
    Color(0xFFD2552B),
    Color(0xFF6E8A1E),
    Color(0xFFC2357A),
    Color(0xFF3D6C9E),
    Color(0xFF8A5A2B),
  ];

  /// The bot's fixed body tone: its own colour, else one picked by seed.
  Color get tone => color ?? palette[seed % palette.length];

  factory HmCharacterSpec.forName(String name) =>
      HmCharacterSpec(seed: _stableHash(name));

  /// Reads `ui_meta.character`; anything missing falls back to the name.
  /// With [rank] (the bot's place on its host), a bot without its own
  /// colour takes palette[rank], so a host's first 8 bots never share one.
  factory HmCharacterSpec.fromMeta(Object? meta, String name, {int? rank}) {
    final fallback = HmCharacterSpec.forName(name);
    final raw = meta is Map ? meta['character'] : null;
    final seed = raw is Map ? raw['seed'] : null;
    final color = raw is Map ? raw['color'] : null;
    final own = color is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)
        ? Color(0xFF000000 | int.parse(color.substring(1), radix: 16))
        : null;
    return HmCharacterSpec(
      seed: seed is int ? seed : fallback.seed,
      color:
          own ??
          (rank == null || rank < 0 ? null : palette[rank % palette.length]),
    );
  }

  Map<String, Object?> toMeta() => {
    'seed': seed,
    if (color != null)
      'color':
          '#${(color!.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
  };

  static int _stableHash(String s) {
    var h = 0x811C9DC5;
    for (final u in s.codeUnits) {
      h = ((h ^ u) * 0x01000193) & 0x7FFFFFFF;
    }
    return h;
  }
}

/// The bot at [size], doing [state], in the chosen style. [style] overrides
/// the preference (the picker previews every style side by side).
class HmAvatar extends StatelessWidget {
  const HmAvatar({
    super.key,
    required this.spec,
    required this.size,
    this.state = HmAvatarState.idle,
    this.style,
    this.persona,
  });

  final HmCharacterSpec spec;
  final double size;
  final HmAvatarState state;
  final HmAvatarStyle? style;
  final HmPersonaVariant? persona;

  @override
  Widget build(BuildContext context) {
    final look = NextGenLook.instance;
    return ListenableBuilder(
      listenable: look,
      builder: (context, _) {
        final c = NgColors.of(context);
        final animate = !MediaQuery.of(context).disableAnimations;
        final dark = c.background.computeLuminance() < 0.5;
        return switch (style ?? look.avatarStyle) {
          HmAvatarStyle.syn => SynFace(
            state: state,
            size: size,
            color: spec.tone,
            seed: spec.seed,
            animate: animate,
          ),
          HmAvatarStyle.persona => PersonaOrb(
            variant: persona ?? look.personaVariant,
            state: state,
            size: size,
            color: spec.tone,
            animate: animate,
          ),
          HmAvatarStyle.orbs => ThinkingOrbView(
            state: state,
            size: size,
            dark: dark,
            tint: spec.tone,
            animate: animate,
          ),
        };
      },
    );
  }
}
