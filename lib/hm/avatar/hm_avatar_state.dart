// The one contract every avatar style draws: what the bot is doing, and
// which look the person picked. No Flutter imports, so preferences can own it.

/// What a bot is doing right now. Every style shows all six.
enum HmAvatarState {
  /// Nothing in flight.
  idle,

  /// Hearing the person (dictation or voice mode).
  listening,

  /// A turn is running and no reply text has arrived yet.
  thinking,

  /// Reply text is streaming in.
  speaking,

  /// Shown when motion should stop (a settled list row, reduced motion).
  asleep,

  /// The last turn failed.
  error,
}

/// Which avatar library draws bots. Chosen in Settings → Look & Feel.
enum HmAvatarStyle {
  /// Syn faces (synergy.ai companion: Moodie + bloub).
  syn('Faces'),

  /// AI Elements Persona voice orbs (Rive).
  persona('Voice orb'),

  /// thinking-orbs dotted orbs.
  orbs('Thinking orb');

  const HmAvatarStyle(this.label);
  final String label;
}

/// The six AI Elements Persona looks, in upstream order.
enum HmPersonaVariant { opal, obsidian, mana, halo, glint, command }
