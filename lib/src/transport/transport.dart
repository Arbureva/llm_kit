import 'dart:typed_data';

/// A single HTTP request, transport-agnostic.
///
/// This is intentionally a plain data class. It carries everything a transport
/// needs and nothing tied to a particular HTTP package, which is what lets you
/// swap in Dio, package:http, or a mock without touching provider code.
class LlmRequest {
  LlmRequest({
    required this.method,
    required this.url,
    Map<String, String>? headers,
    this.body,
    this.timeout,
  }) : headers = headers ?? const {};

  final String method;
  final Uri url;
  final Map<String, String> headers;

  /// JSON-encoded request body (already a String). Null for GET-style calls.
  final String? body;

  /// Per-request timeout override. When null the transport's default applies.
  final Duration? timeout;

  LlmRequest copyWith({
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
  }) {
    return LlmRequest(
      method: method,
      url: url,
      headers: headers ?? this.headers,
      body: body ?? this.body,
      timeout: timeout ?? this.timeout,
    );
  }
}

/// A non-streaming HTTP response.
class LlmResponse {
  LlmResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List bodyBytes;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// The injection seam.
///
/// Implement this once with whatever HTTP client your app already uses
/// (Dio with a cookie jar, package:http, a Cronet-backed client, a test
/// double...). Every provider in this library talks only to this interface,
/// so the transport you pass in is the transport that carries your cookies,
/// interceptors, proxies, and TLS config.
///
/// Two methods, because streaming (SSE) and unary requests have genuinely
/// different lifecycles and forcing them through one signature is what made
/// the old design awkward.
abstract class LlmTransport {
  /// Perform a single request and return the full response.
  Future<LlmResponse> send(LlmRequest request);

  /// Perform a request whose body streams back as raw byte chunks.
  ///
  /// The transport is responsible only for delivering bytes in order and
  /// surfacing a non-2xx status as an error (ideally [TransportException]).
  /// SSE framing and decoding happen in a layer above this, so a transport
  /// implementation never needs to understand event-stream semantics.
  Stream<List<int>> sendStream(LlmRequest request);

  /// Release any resources (connection pools, etc). Optional to override.
  void close() {}
}

/// Raised by transports (or the layers above them) for HTTP-level failures.
class TransportException implements Exception {
  TransportException(
    this.message, {
    this.statusCode,
    this.uri,
    this.responseBody,
  });

  final String message;
  final int? statusCode;
  final Uri? uri;
  final String? responseBody;

  @override
  String toString() {
    final parts = <String>[
      'TransportException: $message',
      if (statusCode != null) 'status=$statusCode',
      if (uri != null) 'uri=$uri',
    ];
    return parts.join(' ');
  }
}
