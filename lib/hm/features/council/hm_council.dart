// Council: one brief, each agent's report, and the verdict they reached,
// with every passage read aloud through the thinking orb of whoever wrote
// it. Behaviour follows Glide's council popup: the brief and constraints sit
// on top, each seat shows its stance and reply, Read all reads the brief,
// then each report, then the verdict. While a passage plays, a full-screen
// orb with a one-sentence caption replaces the card; a tap returns to the
// card and cancels the reading. Reduced motion keeps the orb still.
//
// The Hermes gateway has no council RPC, so the chat menu opens the
// recorded demo run under a visible DEMO tag. [CouncilSource] takes any
// `glide.council-run/v1` snapshot once one is available.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../avatar/hm_avatar_state.dart';
import '../../avatar/thinking_orb_view.dart';
import '../../hm_ui.dart';
import 'council_reader.dart';
import 'council_run.dart';

/// The council's own orb (brief and verdict): brass, like the brief boss.
const councilInk = Color(0xFFD7B986);

/// Opens the council screen; [voice] defaults to the app's TTS engine.
Future<void> openHmCouncil(
  BuildContext context, {
  CouncilSource? source,
  CouncilVoice? voice,
}) async {
  final speech = voice ?? ReadAloudCouncilVoice();
  try {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HmCouncilScreen(
          source: source ?? CouncilSource.demo(),
          voice: speech,
        ),
      ),
    );
  } finally {
    if (voice == null) speech.dispose();
  }
}

class HmCouncilScreen extends StatefulWidget {
  const HmCouncilScreen({super.key, required this.source, required this.voice});
  final CouncilSource source;
  final CouncilVoice voice;

  @override
  State<HmCouncilScreen> createState() => _HmCouncilScreenState();
}

class _HmCouncilScreenState extends State<HmCouncilScreen> {
  late final CouncilReader _reader = CouncilReader(
    widget.source.run,
    widget.voice,
  );

  CouncilRun get _run => widget.source.run;

  @override
  void dispose() {
    _reader.dispose();
    super.dispose();
  }

  Color? _tintOf(CouncilPassage? p) {
    final seat = p?.seat;
    return seat == null ? councilInk : _run.seats[seat].mineral.tint;
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return ListenableBuilder(
      listenable: _reader,
      builder: (context, _) {
        final passage = _reader.passage;
        return PopScope(
          // Back first returns from the orb to the card, then leaves.
          canPop: passage == null,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_reader.stop());
          },
          child: Scaffold(
            backgroundColor: c.background,
            body: Stack(
              children: [
                Column(
                  children: [
                    HmTopBar(
                      leading: const HmBackButton(),
                      title: 'Council',
                      trailing: [
                        HmRoundButton(
                          icon: _reader.reading
                              ? Icons.stop
                              : Icons.record_voice_over_outlined,
                          label: _reader.reading ? 'Stop reading' : 'Read all',
                          onPressed: _reader.reading
                              ? () => unawaited(_reader.stop())
                              : () => unawaited(_reader.readAll()),
                        ),
                      ],
                    ),
                    Expanded(child: _card(context, c)),
                  ],
                ),
                if (passage != null)
                  Positioned.fill(
                    child: _SpeakingOrb(
                      passage: passage,
                      caption: _reader.caption,
                      tint: _tintOf(passage),
                      onReturn: () => unawaited(_reader.stop()),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _card(BuildContext context, NgColors c) {
    final run = _run;
    final warning = _reader.warning;
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 4, 32, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Tag(
                widget.source.live ? 'LIVE' : 'DEMO',
                color: widget.source.live ? c.success : c.text2,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.source.note ??
                      '${run.seats.length} seats · ${run.rounds} rounds',
                  style: HmType.sub.copyWith(color: c.text3),
                ),
              ),
            ],
          ),
        ),
        if (warning != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 12, 32, 0),
            child: Text(
              warning,
              key: const ValueKey('council-warning'),
              style: HmType.sub.copyWith(color: c.warning),
            ),
          ),
        const HmSection('THE BRIEF'),
        HmGroup(
          children: [
            _PassageRow(
              passageKey: 'brief',
              reader: _reader,
              tint: councilInk,
              readLabel: 'Read the brief aloud',
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(run.brief, style: HmType.row.copyWith(color: c.text)),
                  for (final line in run.constraints)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '· $line',
                        style: HmType.value.copyWith(color: c.text2),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const HmSection('REPORTS'),
        HmGroup(
          children: [
            for (var i = 0; i < run.seats.length; i++) _seatRow(context, c, i),
          ],
        ),
        const HmSection('VERDICT'),
        HmGroup(
          children: [
            _PassageRow(
              passageKey: 'verdict',
              reader: _reader,
              tint: councilInk,
              readLabel: 'Read the verdict aloud',
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    councilOutcome(run),
                    style: HmType.display.copyWith(color: c.text),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    councilTally(run),
                    style: HmType.value.copyWith(color: c.text3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _seatRow(BuildContext context, NgColors c, int i) {
    final seat = _run.seats[i];
    final verdict = _run.verdictOf(i);
    final receipt = _run.receiptOf(i);
    final stanceColor = switch (verdict?.stance) {
      CouncilStance.agree => c.success,
      CouncilStance.dissent => c.danger,
      _ => c.text3,
    };
    return _PassageRow(
      passageKey: verdict == null ? null : 'seat:${seat.id}',
      reader: _reader,
      tint: seat.mineral.tint,
      readLabel: "Read ${seat.name}'s report aloud",
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  seat.name,
                  style: HmType.row.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _Tag(
                verdict == null
                    ? 'NO REPLY'
                    : stanceLabel(verdict.stance).toUpperCase(),
                color: stanceColor,
              ),
            ],
          ),
          Text(
            '${seat.family} · ${seat.mineral.label}',
            style: HmType.sub.copyWith(color: c.text3),
          ),
          const SizedBox(height: 6),
          Text(
            verdict?.text ?? 'No reply recorded.',
            style: HmType.value.copyWith(color: c.text),
          ),
          if (receipt != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(receipt, style: HmType.sub.copyWith(color: c.text3)),
            ),
        ],
      ),
    );
  }
}

/// A brief, report or verdict row: its orb, its text, its read button.
class _PassageRow extends StatelessWidget {
  const _PassageRow({
    required this.passageKey,
    required this.reader,
    required this.tint,
    required this.readLabel,
    required this.body,
  });
  final String? passageKey;
  final CouncilReader reader;
  final Color tint;
  final String readLabel;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final key = passageKey;
    final speaking = key != null && reader.isReading(key);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 12),
            child: ThinkingOrbView(
              key: key == null ? null : ValueKey('council-orb-$key'),
              // A still orb until it speaks: a list of moving orbs is noise.
              state: speaking ? HmAvatarState.speaking : HmAvatarState.asleep,
              size: 36,
              dark: Theme.of(context).brightness == Brightness.dark,
              tint: tint,
              animate: !MediaQuery.disableAnimationsOf(context),
            ),
          ),
          Expanded(child: body),
          if (key != null)
            IconButton(
              tooltip: speaking ? 'Stop reading' : readLabel,
              color: c.text2,
              icon: Icon(speaking ? Icons.stop : Icons.volume_up_outlined),
              onPressed: speaking
                  ? () => unawaited(reader.stop())
                  : () => unawaited(reader.readOne(key)),
            ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: 0.6)),
    ),
    child: Text(
      text,
      style: HmType.sub.copyWith(
        color: color,
        letterSpacing: 1.2,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

/// The full-screen orb that speaks a passage, captioned one sentence at a
/// time. Any tap returns to the card and cancels the reading.
class _SpeakingOrb extends StatelessWidget {
  const _SpeakingOrb({
    required this.passage,
    required this.caption,
    required this.tint,
    required this.onReturn,
  });
  final CouncilPassage passage;
  final String caption;
  final Color? tint;
  final VoidCallback onReturn;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final side = MediaQuery.sizeOf(context).shortestSide;
    return Semantics(
      button: true,
      label: 'Stop reading and return to the council',
      child: GestureDetector(
        key: const ValueKey('council-speaking'),
        behavior: HitTestBehavior.opaque,
        onTap: onReturn,
        child: ColoredBox(
          color: c.background,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ThinkingOrbView(
                    key: const ValueKey('council-speaking-orb'),
                    state: HmAvatarState.speaking,
                    size: (side * 0.6).clamp(120.0, 320.0),
                    dark: Theme.of(context).brightness == Brightness.dark,
                    tint: tint,
                    animate: !MediaQuery.disableAnimationsOf(context),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    passage.label.toUpperCase(),
                    style: HmType.section.copyWith(
                      color: c.text3,
                      letterSpacing: 1.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    caption,
                    key: const ValueKey('council-caption'),
                    textAlign: TextAlign.center,
                    style: HmType.display.copyWith(color: c.text),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Tap to return',
                    style: HmType.sub.copyWith(color: c.text3),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
