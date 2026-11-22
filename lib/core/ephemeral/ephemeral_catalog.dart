/// The shared ephemeral-ui card catalog, vendored from kvnloo/ephemeral-ui.
///
/// `assets/ephemeral_ui/catalog.json` is a verbatim copy of the kit's
/// generated `catalog/catalog.json`; `PIN.json` beside it records the commit,
/// version and sha256 it came from. The app never edits either file.
library;

import 'dart:convert';

import 'package:flutter/services.dart';

/// Asset paths of the vendored catalog and its pin.
abstract final class EphemeralCatalogAssets {
  static const catalog = 'assets/ephemeral_ui/catalog.json';
  static const pin = 'assets/ephemeral_ui/PIN.json';
}

/// Fixture states the catalog defines (`fixtures[].state`).
enum EphemeralFixtureState { sample, example, input, unavailable }

EphemeralFixtureState _state(String value) => switch (value) {
  'sample' => EphemeralFixtureState.sample,
  'example' => EphemeralFixtureState.example,
  'input' => EphemeralFixtureState.input,
  'unavailable' => EphemeralFixtureState.unavailable,
  _ => throw FormatException('Unknown fixture state: $value'),
};

Map<String, Object?> _map(Object? value, String what) {
  if (value is! Map) throw FormatException('$what must be an object.');
  return value.cast<String, Object?>();
}

List<Object?> _list(Object? value, String what) {
  if (value is! List) throw FormatException('$what must be an array.');
  return value;
}

String _string(Object? value, String what) {
  if (value is! String) throw FormatException('$what must be a string.');
  return value;
}

final class EphemeralApp {
  const EphemeralApp({
    required this.id,
    required this.name,
    required this.inCatalog,
  });

  final String id;
  final String name;

  /// False for host apps (k3s, glide, ...) that draw a neutral monogram.
  final bool inCatalog;

  factory EphemeralApp.fromJson(Map<String, Object?> json) => EphemeralApp(
    id: _string(json['id'], 'apps[].id'),
    name: _string(json['name'], 'apps[].name'),
    inCatalog: json['inCatalog'] == true,
  );
}

final class EphemeralFixture {
  const EphemeralFixture({
    required this.id,
    required this.state,
    required this.seed,
    required this.card,
    required this.props,
  });

  final String id;
  final EphemeralFixtureState state;
  final String? seed;

  /// The card document a host receives: `kind`, `app`, optional `input`.
  final Map<String, Object?> card;

  /// The kit's `spec` for this fixture: the props contract for renderers.
  final Map<String, Object?> props;

  String get appId => card['app'] as String? ?? '';

  factory EphemeralFixture.fromJson(Map<String, Object?> json) =>
      EphemeralFixture(
        id: _string(json['id'], 'fixtures[].id'),
        state: _state(_string(json['state'], 'fixtures[].state')),
        seed: json['seed'] as String?,
        card: _map(json['card'], 'fixtures[].card'),
        props: _map(json['props'], 'fixtures[].props'),
      );
}

final class EphemeralKind {
  const EphemeralKind({
    required this.kind,
    required this.label,
    required this.group,
    required this.programmable,
    required this.input,
    required this.apps,
    required this.fixtures,
  });

  final String kind;
  final String label;
  final String group;

  /// In `card.v0.json`'s kind enum, so a model may emit it in a fence.
  final bool programmable;

  /// `none`, `appInput` or `data`.
  final String input;
  final List<EphemeralApp> apps;
  final List<EphemeralFixture> fixtures;

  EphemeralApp? app(String id) {
    for (final app in apps) {
      if (app.id == id) return app;
    }
    return null;
  }

  factory EphemeralKind.fromJson(Map<String, Object?> json) => EphemeralKind(
    kind: _string(json['kind'], 'kinds[].kind'),
    label: _string(json['label'], 'kinds[].label'),
    group: _string(json['group'], 'kinds[].group'),
    programmable: json['programmable'] == true,
    input: _string(json['input'], 'kinds[].input'),
    apps: List.unmodifiable(
      _list(
        json['apps'],
        'kinds[].apps',
      ).map((a) => EphemeralApp.fromJson(_map(a, 'kinds[].apps[]'))),
    ),
    fixtures: List.unmodifiable(
      _list(
        json['fixtures'],
        'kinds[].fixtures',
      ).map((f) => EphemeralFixture.fromJson(_map(f, 'kinds[].fixtures[]'))),
    ),
  );
}

/// Where the vendored copy came from (`PIN.json`).
final class EphemeralCatalogPin {
  const EphemeralCatalogPin({
    required this.source,
    required this.commit,
    required this.version,
    required this.sha256,
  });

  final String source;
  final String commit;
  final String version;
  final String sha256;

  String get shortCommit => commit.length > 7 ? commit.substring(0, 7) : commit;

  factory EphemeralCatalogPin.fromJson(Map<String, Object?> json) =>
      EphemeralCatalogPin(
        source: _string(json['source'], 'pin.source'),
        commit: _string(json['commit'], 'pin.commit'),
        version: _string(json['version'], 'pin.version'),
        sha256: _string(json['sha256'], 'pin.sha256'),
      );
}

final class EphemeralCatalog {
  EphemeralCatalog({
    required this.version,
    required this.generatedAt,
    required this.kinds,
    this.pin,
  }) : _byKind = {for (final k in kinds) k.kind: k};

  /// The only file shape this app reads (`v`).
  static const supportedShape = 0;

  final String version;
  final String generatedAt;
  final List<EphemeralKind> kinds;
  final EphemeralCatalogPin? pin;
  final Map<String, EphemeralKind> _byKind;

  int get fixtureCount =>
      kinds.fold(0, (sum, kind) => sum + kind.fixtures.length);

  EphemeralKind? kind(String id) => _byKind[id];

  /// Groups in catalog order, each with its kinds in catalog order.
  Map<String, List<EphemeralKind>> get groups {
    final out = <String, List<EphemeralKind>>{};
    for (final kind in kinds) {
      (out[kind.group] ??= []).add(kind);
    }
    return out;
  }

  /// Parses `catalog.json`. Throws [FormatException] for any shape other
  /// than `v == 0` or when the recorded counts disagree with the content.
  static EphemeralCatalog parse(String source, {EphemeralCatalogPin? pin}) {
    final json = _map(jsonDecode(source), 'catalog');
    if (json['v'] != supportedShape) {
      throw FormatException(
        'Unsupported ephemeral-ui catalog shape v=${json['v']}; '
        'this app reads v=$supportedShape.',
      );
    }
    final kinds = List<EphemeralKind>.unmodifiable(
      _list(
        json['kinds'],
        'kinds',
      ).map((k) => EphemeralKind.fromJson(_map(k, 'kinds[]'))),
    );
    final catalog = EphemeralCatalog(
      version: _string(json['version'], 'version'),
      generatedAt: _string(json['generatedAt'], 'generatedAt'),
      kinds: kinds,
      pin: pin,
    );
    final count = _map(json['count'], 'count');
    if (count['kinds'] != kinds.length ||
        count['fixtures'] != catalog.fixtureCount) {
      throw const FormatException(
        'ephemeral-ui catalog counts disagree with its kinds.',
      );
    }
    return catalog;
  }

  static Future<EphemeralCatalog>? _loaded;

  /// The vendored catalog, loaded once per process.
  static Future<EphemeralCatalog> load([AssetBundle? bundle]) {
    if (bundle != null) return _read(bundle);
    return _loaded ??= _read(rootBundle);
  }

  static Future<EphemeralCatalog> _read(AssetBundle bundle) async {
    final pinSource = await bundle.loadString(EphemeralCatalogAssets.pin);
    final pin = EphemeralCatalogPin.fromJson(
      _map(jsonDecode(pinSource), 'pin'),
    );
    final source = await bundle.loadString(EphemeralCatalogAssets.catalog);
    return parse(source, pin: pin);
  }
}
