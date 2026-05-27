import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'transport.dart';

/// Default transport backed by `package:http`.
///
/// Use this when you have no special networking needs. If your project needs
/// cookies, interceptors, or a shared connection pool, write a thin adapter
/// over your existing client instead (see the DioTransport example in the
/// README) and pass that to the provider — nothing else changes.
class HttpTransport implements LlmTransport {
  HttpTransport({
    http.Client? client,
    this.defaultTimeout = const Duration(seconds: 60),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration defaultTimeout;

  @override
  Future<LlmResponse> send(LlmRequest request) async {
    final r = http.Request(request.method, request.url)..headers.addAll(request.headers);
    if (request.body != null) r.body = request.body!;

    final streamed = await _client.send(r).timeout(request.timeout ?? defaultTimeout);
    final bytes = await streamed.stream.toBytes();

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw TransportException(
        'HTTP ${streamed.statusCode}',
        statusCode: streamed.statusCode,
        uri: request.url,
        responseBody: utf8.decode(bytes, allowMalformed: true),
      );
    }

    return LlmResponse(
      statusCode: streamed.statusCode,
      headers: streamed.headers,
      bodyBytes: bytes,
    );
  }

  @override
  Stream<List<int>> sendStream(LlmRequest request) {
    final controller = StreamController<List<int>>();

    Future<void> run() async {
      final r = http.Request(request.method, request.url)..headers.addAll(request.headers);
      if (request.body != null) r.body = request.body!;

      try {
        final streamed = await _client.send(r).timeout(request.timeout ?? defaultTimeout);

        if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
          final body = await streamed.stream.bytesToString();
          controller.addError(
            TransportException(
              'HTTP ${streamed.statusCode}',
              statusCode: streamed.statusCode,
              uri: request.url,
              responseBody: body,
            ),
          );
          await controller.close();
          return;
        }

        await controller.addStream(streamed.stream);
        await controller.close();
      } catch (e, st) {
        controller.addError(e, st);
        await controller.close();
      }
    }

    controller.onListen = run;
    return controller.stream;
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}
