// Settings → Look & Feel → Bot avatar: pick the library that draws bots
// (Syn faces, Persona voice orbs, thinking orbs), with live previews of
// every state.
import 'package:flutter/material.dart';

import '../../nextgen/nextgen_preferences.dart';
import '../../nextgen/theme/nextgen_theme.dart';
import '../../nextgen/ui/nextgen_scope.dart';
import '../avatar/hm_avatar.dart';
import '../avatar/hm_avatar_state.dart';
import '../hm_ui.dart';

class HmAvatarPicker extends StatefulWidget {
  const HmAvatarPicker({super.key, required this.sample});

  /// The bot the previews draw (the first on this host).
  final HmCharacterSpec sample;

  @override
  State<HmAvatarPicker> createState() => _HmAvatarPickerState();
}

class _HmAvatarPickerState extends State<HmAvatarPicker> {
  HmAvatarState _preview = HmAvatarState.thinking;

  static const _states = {
    HmAvatarState.idle: 'Idle',
    HmAvatarState.listening: 'Listening',
    HmAvatarState.thinking: 'Thinking',
    HmAvatarState.speaking: 'Speaking',
    HmAvatarState.error: 'Error',
  };

  static const _styleNotes = {
    HmAvatarStyle.syn: 'Syn · Moodie + bloub',
    HmAvatarStyle.persona: 'AI Elements Persona',
    HmAvatarStyle.orbs: 'thinking-orbs',
  };

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final prefs = NgScope.of(context).connManager.prefs;
    final look = NextGenLook.instance;
    return ListenableBuilder(
      listenable: look,
      builder: (context, _) => HmPage(
        title: 'Bot avatar',
        children: [
          Center(
            child: Semantics(
              label: 'Preview, ${_states[_preview]}',
              child: HmAvatar(spec: widget.sample, size: 132, state: _preview),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in _states.entries)
                ChoiceChip(
                  label: Text(e.value, style: HmType.value),
                  selected: _preview == e.key,
                  onSelected: (_) => setState(() => _preview = e.key),
                ),
            ],
          ),
          const HmSection('Style'),
          HmGroup(
            children: [
              for (final s in HmAvatarStyle.values)
                HmRow(
                  leading: HmAvatar(
                    spec: widget.sample,
                    size: 40,
                    state: _preview,
                    style: s,
                  ),
                  label: s.label,
                  value: _styleNotes[s],
                  tall: true,
                  chevron: false,
                  trailing: look.avatarStyle == s
                      ? Icon(Icons.check, color: c.accentText)
                      : null,
                  onTap: () => NextGenPreferences.setAvatarStyle(prefs, s),
                ),
            ],
          ),
          if (look.avatarStyle == HmAvatarStyle.persona) ...[
            const HmSection('Voice orb look'),
            HmGroup(
              children: [
                for (final v in HmPersonaVariant.values)
                  HmRow(
                    leading: HmAvatar(
                      spec: widget.sample,
                      size: 40,
                      state: _preview,
                      style: HmAvatarStyle.persona,
                      persona: v,
                    ),
                    label: '${v.name[0].toUpperCase()}${v.name.substring(1)}',
                    tall: true,
                    chevron: false,
                    trailing: look.personaVariant == v
                        ? Icon(Icons.check, color: c.accentText)
                        : null,
                    onTap: () => NextGenPreferences.setPersonaVariant(prefs, v),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
