// A fake integrations transport: canned answers per JSON-RPC method or REST
// route, and a log of every request that went out.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/hm/features/integrations/integrations_api.dart';

class SentRequest {
  SentRequest(this.kind, this.name, this.params, {this.query, this.body});

  /// `rpc` or the HTTP verb.
  final String kind;

  /// JSON-RPC method or REST path under /api/.
  final String name;
  final Map<String, dynamic> params;
  final Map<String, String>? query;
  final Object? body;

  String get key => kind == 'rpc' ? name : '$kind $name';
}

typedef RpcHandler = Map<String, dynamic> Function(Map<String, dynamic> params);
typedef RestHandler = Object? Function(SentRequest request);

class FakeTransport implements HmIntegrationsTransport {
  final Map<String, RpcHandler> rpcs = {};
  final Map<String, RestHandler> rests = {};
  final List<SentRequest> sent = [];
  final List<Uri> opened = [];

  List<SentRequest> named(String key) =>
      sent.where((r) => r.key == key).toList();

  @override
  Future<Map<String, dynamic>> rpc(
    String method,
    Map<String, dynamic> params,
  ) async {
    sent.add(SentRequest('rpc', method, params));
    final h = rpcs[method];
    if (h == null) {
      throw const HmIntegrationsError(HmFailure.unsupported, 'method not found');
    }
    return h(params);
  }

  @override
  Future<Object?> rest(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final r = SentRequest(method, path, const {}, query: query, body: body);
    sent.add(r);
    final h = rests['$method $path'];
    if (h == null) {
      throw HmIntegrationsError.fromStatus(404, 'Not Found');
    }
    return h(r);
  }

  @override
  Future<bool> openExternal(Uri url) async {
    opened.add(url);
    return true;
  }
}

Never failWith(int status, [String message = 'boom']) =>
    throw HmIntegrationsError.fromStatus(status, message);

/// Pumps [page] on a phone-sized surface.
Future<void> pumpPage(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1200, 2800);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: page));
  await tester.pumpAndSettle();
}
