import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CardCatalog {
  static const asset = 'assets/shared_ui/catalog.json';
  final String version;
  final List<CatalogFixture> fixtures;

  CardCatalog._(this.version, this.fixtures);

  factory CardCatalog.parse(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    if (json['v'] != 0) {
      throw const FormatException('Unsupported card catalog format');
    }

    final fixtures = <CatalogFixture>[];
    final kinds = <String>{};
    final ids = <String>{};
    for (final kind in json['kinds'] as List) {
      final name = kind['kind'] as String;
      final entries = kind['fixtures'] as List;
      if (!kinds.add(name) || entries.isEmpty) {
        throw FormatException('Expected a unique kind with fixtures: $name');
      }
      for (final entry in entries) {
        final card = entry['card'] as Map<String, dynamic>;
        final id = entry['id'] as String;
        if (!ids.add(id) || card['kind'] != name) {
          throw FormatException('Duplicate or mismatched catalog fixture: $id');
        }
        fixtures.add(
          CatalogFixture(
            id: id,
            state: entry['state'] as String,
            card: Map.unmodifiable(card),
          ),
        );
      }
    }
    return CardCatalog._(
      json['version'] as String,
      List.unmodifiable(fixtures),
    );
  }
}

class CatalogFixture {
  final String id;
  final String state;

  /// The source fixture's card, including its optional input document.
  final Map<String, dynamic> card;
  String get kind => card['kind'] as String;
  String get app => card['app'] as String;

  const CatalogFixture({
    required this.id,
    required this.state,
    required this.card,
  });
}

/// No native ephemeral-ui v0 renderer is registered in this app yet. OpenUI
/// boards use a different schema; don't pass these fixtures to that renderer.
class CatalogFixtureCell extends StatelessWidget {
  const CatalogFixtureCell(this.fixture, {super.key});
  final CatalogFixture fixture;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(fixture.kind),
    subtitle: Text(
      '${fixture.app} · ${switch (fixture.state) {
        'unavailable' => 'Unavailable (no data)',
        'example' => 'Example · not supported',
        'input' => 'Input · not supported',
        _ => 'Sample · not supported',
      }}',
    ),
  );
}

class CardGallery extends StatefulWidget {
  const CardGallery({super.key});

  static const title = 'Shared card gallery';

  static void open(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const CardGallery()));
  }

  @override
  State<CardGallery> createState() => _CardGalleryState();
}

class _CardGalleryState extends State<CardGallery> {
  late final Future<CardCatalog> _catalog;

  @override
  void initState() {
    super.initState();
    _catalog = rootBundle.loadString(CardCatalog.asset).then(CardCatalog.parse);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<CardCatalog>(
    future: _catalog,
    builder: (context, snapshot) {
      final catalog = snapshot.data;
      return Scaffold(
        appBar: AppBar(
          title: Text(
            catalog == null
                ? CardGallery.title
                : '${CardGallery.title} · v${catalog.version}',
          ),
        ),
        body: catalog == null
            ? Center(
                child: snapshot.hasError
                    ? const Text('Could not load the shared card catalog.')
                    : const CircularProgressIndicator(),
              )
            : ListView.builder(
                itemCount: catalog.fixtures.length,
                itemBuilder: (context, index) {
                  final fixture = catalog.fixtures[index];
                  return CatalogFixtureCell(fixture, key: ValueKey(fixture.id));
                },
              ),
      );
    },
  );
}
