/// The shared ephemeral-ui card catalog, vendored from kvnloo/ephemeral-ui.
///
/// `assets/shared_ui/catalog.json` is a byte-for-byte copy of the kit's
/// generated `catalog/catalog.json`; `PIN.json` beside it records the
/// upstream revision and versions. The app never edits either file;
/// `scripts/ephemeral_ui_catalog.py` checks both against upstream.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Asset paths of the vendored catalog and its pin.
abstract final class EphemeralCatalogAssets {
  static const catalog = 'assets/shared_ui/catalog.json';

  /// Read by tools and tests only; not bundled into the app.
  static const pin = 'assets/shared_ui/PIN.json';
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
  const EphemeralCatalogPin({required this.revision, required this.version});

  /// Full ephemeral-ui commit the copy was taken from.
  final String revision;

  /// `catalogVersion`: the catalog's semver at [revision].
  final String version;

  factory EphemeralCatalogPin.fromJson(Map<String, Object?> json) =>
      EphemeralCatalogPin(
        revision: _string(json['revision'], 'pin.revision'),
        version: _string(json['catalogVersion'], 'pin.catalogVersion'),
      );
}

final class EphemeralCatalog {
  EphemeralCatalog({
    required this.version,
    required this.generatedAt,
    required this.kinds,
  }) : _byKind = {for (final k in kinds) k.kind: k};

  /// The only file shape this app reads (`v`).
  static const supportedShape = 0;

  final String version;
  final String generatedAt;
  final List<EphemeralKind> kinds;
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
  static EphemeralCatalog parse(String source) {
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
  static EphemeralCatalog? _ready;

  /// The vendored catalog once [load] has finished, so a chat card that is
  /// rebuilt while scrolling draws in the first frame.
  static EphemeralCatalog? get loaded => _ready;

  /// The vendored catalog, loaded once per process.
  static Future<EphemeralCatalog> load([AssetBundle? bundle]) {
    if (bundle != null) return _read(bundle);
    return _loaded ??= _read(rootBundle).then((catalog) => _ready = catalog);
  }

  /// Makes [catalog] the loaded catalog (tests), or forgets it with null.
  @visibleForTesting
  static void debugUse(EphemeralCatalog? catalog) {
    _ready = catalog;
    _loaded = catalog == null ? null : Future.value(catalog);
  }

  static Future<EphemeralCatalog> _read(AssetBundle bundle) async =>
      parse(await bundle.loadString(EphemeralCatalogAssets.catalog));
}
