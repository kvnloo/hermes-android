// Fakes for the Work screens' transports: a dashboard that answers by
// "METHOD endpoint" and records every request, and a JSON-RPC recorder.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hermes_android/nextgen/nextgen_preferences.dart';
import 'package:hermes_android/nextgen/theme/nextgen_theme.dart';
import 'package:http/http.dart' as http;

class FakeCall {
  FakeCall(this.method, this.endpoint, this.body, this.query);
  final String method;
  final String endpoint;
  final Object? body;
  final Map<String, String>? query;

  @override
  String toString() => '$method $endpoint $query $body';
}

typedef FakeAnswer = (int, Object?);

class FakeDashboard {
  /// Answers keyed by "METHOD endpoint"; a value may be a function of the
  /// call so a test can change the answer after a write.
  final Map<String, Object> routes = {};
  final List<FakeCall> calls = [];

  void on(String key, int status, Object? body) => routes[key] = (status, body);

  Future<http.Response> call(
    String method,
    String endpoint, {
    Object? body,
    Map<String, String>? query,
  }) async {
    final call = FakeCall(method, endpoint, body, query);
    calls.add(call);
    final route = routes['$method $endpoint'];
    final FakeAnswer answer = switch (route) {
      final FakeAnswer Function(FakeCall) f => f(call),
      final FakeAnswer a => a,
      _ => (404, {'detail': 'Not Found'}),
    };
    return http.Response(
      jsonEncode(answer.$2 ?? {}),
      answer.$1,
      headers: {'content-type': 'application/json'},
    );
  }

  List<FakeCall> where(String method, String endpoint) => [
    for (final c in calls)
      if (c.method == method && c.endpoint == endpoint) c,
  ];
}

class FakeRpc {
  final Map<String, Object> answers = {};
  final List<(String, Map<String, dynamic>)> calls = [];

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    calls.add((method, params));
    final a = answers[method];
    if (a is Exception || a is Error) throw a!;
    if (a is Map<String, dynamic> Function(Map<String, dynamic>)) {
      return a(params);
    }
    if (a is Map<String, dynamic>) return a;
    throw StateError('no answer for $method');
  }

  List<Map<String, dynamic>> paramsOf(String method) => [
    for (final (m, p) in calls)
      if (m == method) p,
  ];
}

Widget workHost(Widget child) => MaterialApp(
  theme: nextGenTheme(Brightness.light, NextGenLook.instance),
  home: child,
);
