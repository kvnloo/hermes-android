// A council run: one brief sent to several agents ("seats"), each seat's
// reply, and the verdict they converged on. The payload is Glide's
// `glide.council-run/v1` snapshot, so a run recorded by Glide reads here
// unchanged. This file parses and projects a run; it never invents a verdict
// or a reply the snapshot does not hold.
import 'package:flutter/painting.dart' show Color;

import '../../avatar/avatar_palette.dart';

const councilSchema = 'glide.council-run/v1';

enum CouncilStance { agree, dissent, abstain }

/// The mineral a seat is drawn in. Each one names a model family's look and
/// tints the seat's thinking orb.
enum CouncilMineral {
  citrine('Citrine'),
  rose('Rose quartz'),
  smoky('Smoky quartz'),
  clear('Clear quartz'),
  malachite('Malachite'),
  labradorite('Labradorite'),
  moonstone('Moonstone'),
  lapis('Lapis lazuli');

  const CouncilMineral(this.label);
  final String label;

  /// The ink this seat's orb is tinted with.
  Color get tint => AvatarPalette.councilMinerals[name]!;

  static CouncilMineral? byName(Object? name) {
    for (final m in values) {
      if (m.name == name) return m;
    }
    return null;
  }
}

/// A family's minerals, assigned in seat order when a seat names none.
const _family = <String, List<CouncilMineral>>{
  'anthropic': [
    CouncilMineral.citrine,
    CouncilMineral.rose,
    CouncilMineral.smoky,
  ],
  'openai': [
    CouncilMineral.labradorite,
    CouncilMineral.moonstone,
    CouncilMineral.lapis,
  ],
  'google': [CouncilMineral.malachite],
  'free': [CouncilMineral.clear],
};

class CouncilSeat {
  const CouncilSeat({
    required this.id,
    required this.name,
    required this.family,
    required this.mineral,
  });
  final String id, name, family;
  final CouncilMineral mineral;
}

class CouncilTurn {
  const CouncilTurn({
    required this.seat,
    required this.round,
    this.cites = const [],
  });
  final int seat, round;
  final List<int> cites;
}

class CouncilVerdict {
  const CouncilVerdict({
    required this.seat,
    required this.stance,
    required this.text,
  });
  final int seat;
  final CouncilStance stance;
  final String text;
}

class CouncilRun {
  const CouncilRun({
    required this.brief,
    required this.rounds,
    required this.seats,
    required this.turns,
    required this.verdicts,
    this.constraints = const [],
    this.outcome,
  });
  final String brief;
  final List<String> constraints;
  final int rounds;
  final List<CouncilSeat> seats;
  final List<CouncilTurn> turns;
  final List<CouncilVerdict> verdicts;
  final String? outcome;

  CouncilVerdict? verdictOf(int seat) {
    for (final v in verdicts) {
      if (v.seat == seat) return v;
    }
    return null;
  }

  int count(CouncilStance s) => verdicts.where((v) => v.stance == s).length;

  /// The seat's last turn that cited peers, as a receipt line, or null.
  String? receiptOf(int seat) {
    for (final t in turns.reversed) {
      if (t.seat == seat && t.cites.isNotEmpty) {
        return 'Round ${t.round}: ${seats[seat].name} cited '
            '${t.cites.map((c) => seats[c].name).join(', ')}.';
      }
    }
    return null;
  }
}

/// A run and where it came from. `live` only when a gateway supplied it.
class CouncilSource {
  const CouncilSource({
    required this.run,
    required this.live,
    this.note,
    this.sessionId,
  });
  final CouncilRun run;
  final bool live;
  final String? sessionId;

  /// Why a fixture is shown instead of a live run.
  final String? note;

  /// The recorded demo run, labelled DEMO on screen.
  factory CouncilSource.demo() => CouncilSource(
    run: demoCouncilRun(),
    live: false,
    note:
        'This gateway has no council RPC yet, so the screen shows a recorded '
        'demo run with invented seats.',
  );
}

class CouncilParseError implements Exception {
  CouncilParseError(this.message);
  final String message;
  @override
  String toString() => 'not a $councilSchema run ($message)';
}

final _seatId = RegExp(r'^[a-z0-9][a-z0-9._-]{0,39}$');

Never _fail(String where, String what) =>
    throw CouncilParseError('$where: $what');

Map<String, Object?> _obj(Object? v, String where, List<String> keys) {
  if (v is! Map) _fail(where, 'expected an object');
  for (final k in v.keys) {
    if (!keys.contains(k)) _fail(where, 'unknown field "$k"');
  }
  return v.cast<String, Object?>();
}

String _str(Object? v, String where, int max) =>
    v is String && v.trim().isNotEmpty && v.length <= max
    ? v
    : _fail(where, 'expected text of 1-$max characters');

int _int(Object? v, String where, int min, int max) =>
    v is int && v >= min && v <= max
    ? v
    : _fail(where, 'expected a whole number $min-$max');

List<Object?> _list(Object? v, String where, int min, int max) =>
    v is List && v.length >= min && v.length <= max
    ? v.cast<Object?>()
    : _fail(where, 'expected a list of $min-$max');

/// Reads a `glide.council-run/v1` snapshot; throws [CouncilParseError].
CouncilRun parseCouncilRun(Object? raw) {
  final d = _obj(raw, 'run', const [
    'schema',
    'brief',
    'constraints',
    'rounds',
    'seats',
    'events',
    'verdicts',
    'outcome',
  ]);
  if (d['schema'] != councilSchema) {
    _fail('schema', 'expected "$councilSchema"');
  }
  final rounds = _int(d['rounds'], 'rounds', 1, 8);
  final index = <String, int>{};
  final used = <String, int>{};
  final seatsRaw = _list(d['seats'], 'seats', 2, 6);
  final seats = <CouncilSeat>[];
  for (var i = 0; i < seatsRaw.length; i++) {
    final s = _obj(seatsRaw[i], 'seats.$i', const [
      'id',
      'name',
      'family',
      'mineral',
      'crew',
    ]);
    final id = _str(s['id'], 'seats.$i.id', 40);
    if (!_seatId.hasMatch(id)) _fail('seats.$i.id', 'expected a lowercase id');
    if (index.containsKey(id)) _fail('seats.$i.id', 'two seats share an id');
    index[id] = i;
    final family = _str(s['family'], 'seats.$i.family', 24);
    final key = family.trim().toLowerCase();
    final pool = _family[key] ?? const [CouncilMineral.clear];
    final n = used[key] ?? 0;
    used[key] = n + 1;
    final named = s['mineral'];
    final mineral = named == null
        ? pool[n % pool.length]
        : CouncilMineral.byName(named) ??
              _fail('seats.$i.mineral', 'not a known mineral');
    if (s['crew'] != null) _list(s['crew'], 'seats.$i.crew', 0, 12);
    seats.add(
      CouncilSeat(
        id: id,
        name: _str(s['name'], 'seats.$i.name', 24),
        family: family,
        mineral: mineral,
      ),
    );
  }
  int seat(Object? v, String where) =>
      index[v is String ? v : ''] ?? _fail(where, 'names an unknown seat');

  final turns = <CouncilTurn>[];
  final events = _list(d['events'], 'events', 0, 400);
  for (var i = 0; i < events.length; i++) {
    final e = events[i];
    final type = e is Map ? e['type'] : null;
    if (type == 'spawn') {
      final spawn = _obj(e, 'events.$i', const ['type', 'seat']);
      seat(spawn['seat'], 'events.$i.seat');
      continue;
    }
    if (type != 'turn') _fail('events.$i.type', 'expected "turn" or "spawn"');
    final t = _obj(e, 'events.$i', const ['type', 'seat', 'round', 'cites']);
    final cites = t['cites'] == null
        ? const <int>[]
        : [
            for (final (k, c) in _list(
              t['cites'],
              'events.$i.cites',
              0,
              6,
            ).indexed)
              seat(c, 'events.$i.cites.$k'),
          ];
    turns.add(
      CouncilTurn(
        seat: seat(t['seat'], 'events.$i.seat'),
        round: _int(t['round'], 'events.$i.round', 1, rounds),
        cites: cites,
      ),
    );
  }

  final heard = <int>{};
  final verdicts = <CouncilVerdict>[];
  final verdictsRaw = _list(d['verdicts'], 'verdicts', 0, 6);
  for (var i = 0; i < verdictsRaw.length; i++) {
    final v = _obj(verdictsRaw[i], 'verdicts.$i', const [
      'seat',
      'stance',
      'text',
    ]);
    final s = seat(v['seat'], 'verdicts.$i.seat');
    if (!heard.add(s)) _fail('verdicts.$i.seat', 'seat already has a verdict');
    final stance = switch (v['stance']) {
      'agree' => CouncilStance.agree,
      'dissent' => CouncilStance.dissent,
      'abstain' => CouncilStance.abstain,
      _ => _fail('verdicts.$i.stance', 'expected agree, dissent or abstain'),
    };
    verdicts.add(
      CouncilVerdict(
        seat: s,
        stance: stance,
        text: _str(v['text'], 'verdicts.$i.text', 240),
      ),
    );
  }

  return CouncilRun(
    brief: _str(d['brief'], 'brief', 280),
    constraints: d['constraints'] == null
        ? const []
        : [
            for (final (i, c) in _list(
              d['constraints'],
              'constraints',
              0,
              8,
            ).indexed)
              _str(c, 'constraints.$i', 160),
          ],
    rounds: rounds,
    seats: seats,
    turns: turns,
    verdicts: verdicts,
    outcome: d['outcome'] == null ? null : _str(d['outcome'], 'outcome', 160),
  );
}

/// The recorded demo run: invented seats and brief, no real council output.
/// Shown under a DEMO tag until the gateway offers a council run.
CouncilRun demoCouncilRun() {
  const ids = ['argon', 'astra', 'fable', 'opus'];
  final events = <Map<String, Object?>>[];
  for (var round = 1; round <= 4; round++) {
    for (var i = 0; i < ids.length; i++) {
      final peers = [
        for (final p in ids)
          if (p != ids[i]) p,
      ];
      events.add({
        'type': 'turn',
        'seat': ids[i],
        'round': round,
        'cites': round == 1
            ? <String>[]
            : round == 4
            ? [peers[i % 3]]
            : peers.sublist(0, round == 2 ? 3 : 2),
      });
    }
  }
  return parseCouncilRun({
    'schema': councilSchema,
    'brief': 'Should a small team ship a plugin before its launcher?',
    'constraints': [
      'Keep the first release small.',
      'Use installation receipts to decide what comes next.',
    ],
    'rounds': 4,
    'seats': [
      {'id': 'argon', 'name': 'Argon', 'family': 'Google'},
      {'id': 'astra', 'name': 'Astra', 'family': 'OpenAI'},
      {
        'id': 'fable',
        'name': 'Fable',
        'family': 'Anthropic',
        'mineral': 'rose',
      },
      {
        'id': 'opus',
        'name': 'Opus',
        'family': 'Anthropic',
        'mineral': 'citrine',
      },
    ],
    'events': events,
    'verdicts': [
      {
        'seat': 'argon',
        'stance': 'agree',
        'text': 'Ship the plugin; the launcher only wraps what already works.',
      },
      {
        'seat': 'astra',
        'stance': 'dissent',
        'text':
            'Without the launcher nobody finds the plugin; ship both together.',
      },
      {
        'seat': 'fable',
        'stance': 'agree',
        'text':
            'Ship it, and measure who installs it by hand before building more.',
      },
      {
        'seat': 'opus',
        'stance': 'agree',
        'text':
            'Agree with Fable: the plugin first, the launcher once installs '
            'prove demand.',
      },
    ],
    'outcome': 'Ship the plugin first',
  });
}

/// One thing the council screen can read aloud, voiced by one orb.
class CouncilPassage {
  const CouncilPassage({
    required this.key,
    required this.label,
    required this.text,
    this.seat,
  });
  final String key;
  final String label;
  final String text;

  /// The seat whose orb speaks; null for the council's own orb.
  final int? seat;
}

String stanceLabel(CouncilStance s) => switch (s) {
  CouncilStance.agree => 'Agrees',
  CouncilStance.dissent => 'Dissents',
  CouncilStance.abstain => 'Abstains',
};

/// "3 of 4 agree · 1 dissent".
String councilTally(CouncilRun run) {
  final dissent = run.count(CouncilStance.dissent);
  final abstain = run.count(CouncilStance.abstain);
  return [
    '${run.count(CouncilStance.agree)} of ${run.verdicts.length} agree',
    if (dissent > 0) '$dissent dissent',
    if (abstain > 0) '$abstain abstain',
  ].join(' · ');
}

/// The verdict line: the recorded outcome, never one this app made up.
String councilOutcome(CouncilRun run) =>
    run.outcome ??
    (run.verdicts.isEmpty ? 'No verdict recorded' : 'The council has spoken');

/// What Read all speaks, in order: the brief, each seat's report, the verdict.
List<CouncilPassage> councilPassages(CouncilRun run) {
  final brief = StringBuffer('The brief. ${_terminated(run.brief)}');
  if (run.constraints.isNotEmpty) {
    brief.write(' Constraints. ');
    brief.write(run.constraints.map(_terminated).join(' '));
  }
  return [
    CouncilPassage(key: 'brief', label: 'The brief', text: brief.toString()),
    for (var i = 0; i < run.seats.length; i++)
      if (run.verdictOf(i) case final v?)
        CouncilPassage(
          key: 'seat:${run.seats[i].id}',
          label: run.seats[i].name,
          seat: i,
          text:
              '${run.seats[i].name} ${stanceLabel(v.stance).toLowerCase()}. '
              '${_terminated(v.text)}',
        ),
    CouncilPassage(
      key: 'verdict',
      label: 'Verdict',
      text:
          '${_terminated(councilOutcome(run))} '
          '${_terminated(councilTally(run).replaceAll(' · ', ', '))}',
    ),
  ];
}

final _ends = RegExp(r'[.!?]["\x27]?$');
final _sentence = RegExp(r'[^.!?]+[.!?]+["\x27]?|[^.!?]+$');

String _terminated(String s) {
  final t = s.trim();
  return _ends.hasMatch(t) ? t : '$t.';
}

/// Splits text into sentences, each read and captioned on its own.
List<String> councilSentences(String text) => [
  for (final m in _sentence.allMatches(text))
    if (m.group(0)!.trim().isNotEmpty) m.group(0)!.trim(),
];
