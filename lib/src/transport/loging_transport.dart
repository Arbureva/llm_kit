import 'package:llm_kit/llm_kit.dart';

class LoggingTransport implements LlmTransport {
  LoggingTransport(this.inner);
  final LlmTransport inner;

  void _log(LlmRequest r) {
    // ignore: avoid_print
    print('[LLM] ${r.method} ${r.url}\n${r.body}');
  }

  @override
  Future<LlmResponse> send(LlmRequest r) {
    _log(r);
    return inner.send(r);
  }

  @override
  Stream<List<int>> sendStream(LlmRequest r) {
    _log(r);
    return inner.sendStream(r);
  }

  @override
  void close() => inner.close();
}
