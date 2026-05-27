# llm_kit

A small LLM client for Flutter & Dart. Rebuilt from TinyAI with three goals:

1. **You inject the HTTP transport.** Cookies, interceptors, proxies, a shared
   Dio instance — whatever your app uses, the library uses. No more singleton
   `HttpService` you can't reach into.
2. **Providers are thin and pluggable.** OpenAI-compatible and Anthropic ship
   in the box; adding one is ~150 lines, not a fork.
3. **One typed event stream** models text, reasoning/thinking, and tool calls,
   so new model features (OpenAI's reasoning changes, Anthropic thinking
   blocks) are new event types — not rewrites.

The core has **no Flutter dependency**. It runs in CLIs, servers, and tests.

---

## Architecture

```
your app ──► LlmProvider (OpenAI / Anthropic)
                  │ talks only to ▼
              LlmTransport  ◄── you implement this (Dio, http, mock)
                  ▲ default ▼
              HttpTransport (package:http, shipped)

ChatSession (optional) ──► drives the multi-turn tool loop,
                           emits SessionEvents for your UI
```

---

## The thing you asked for: injecting Dio (cookies work)

The whole reason for the rewrite. Write this adapter **once** in your app and
every provider routes through your cookie-carrying Dio:

```dart
import 'package:dio/dio.dart';
import 'package:llm_kit/llm_kit.dart';

class DioTransport implements LlmTransport {
  DioTransport(this.dio);
  final Dio dio; // your configured instance: CookieManager, interceptors, etc.

  @override
  Future<LlmResponse> send(LlmRequest req) async {
    final res = await dio.request<List<int>>(
      req.url.toString(),
      data: req.body,
      options: Options(
        method: req.method,
        headers: req.headers,
        responseType: ResponseType.bytes,
        // Let llm_kit surface non-2xx as TransportException uniformly:
        validateStatus: (_) => true,
        sendTimeout: req.timeout,
        receiveTimeout: req.timeout,
      ),
    );
    final bytes = Uint8List.fromList(res.data ?? const []);
    final code = res.statusCode ?? 0;
    if (code < 200 || code >= 300) {
      throw TransportException('HTTP $code',
          statusCode: code, uri: req.url,
          responseBody: utf8.decode(bytes, allowMalformed: true));
    }
    return LlmResponse(
      statusCode: code,
      headers: res.headers.map.map((k, v) => MapEntry(k, v.join(','))),
      bodyBytes: bytes,
    );
  }

  @override
  Stream<List<int>> sendStream(LlmRequest req) async* {
    final res = await dio.request<ResponseBody>(
      req.url.toString(),
      data: req.body,
      options: Options(
        method: req.method,
        headers: req.headers,
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
      ),
    );
    final code = res.statusCode ?? 0;
    if (code < 200 || code >= 300) {
      final body = await res.data!.stream
          .map(utf8.decode).join();
      throw TransportException('HTTP $code', statusCode: code, uri: req.url,
          responseBody: body);
    }
    yield* res.data!.stream.map((chunk) => chunk.toList());
  }

  @override
  void close() => dio.close();
}
```

Wire it up:

```dart
final dio = Dio()..interceptors.add(CookieManager(cookieJar));
final provider = OpenAIProvider(
  transport: DioTransport(dio),
  apiKey: '...',
  baseUrl: 'https://your-gateway.example.com/v1', // cookie-gated endpoint
);
```

Nothing else changes. The cookie jar travels with every request and stream.

---

## Quick start (default transport)

```dart
final provider = OpenAIProvider(
  transport: HttpTransport(),
  apiKey: const String.fromEnvironment('OPENAI_KEY'),
  defaultModel: 'gpt-4o-mini',
);

// Non-streaming
final res = await provider.chat([
  Message.system('You are concise.'),
  Message.user('One sentence on why Dart isolates matter.'),
]);
print(res.content);

// Streaming, with typed events
await for (final ev in provider.chatStream([Message.user('Count to 3.')])) {
  switch (ev) {
    case TextDelta(:final text): stdout.write(text);
    case ReasoningDelta(:final text): /* show in a thinking panel */;
    case ToolCallStarted(:final name): print('\n[calling $name…]');
    case StreamDone(:final usage): print('\n[${usage?.totalTokens} tok]');
    default: break;
  }
}
```

## Reasoning / thinking

Both providers accept a neutral `reasoningEffort`; each maps it to its own
mechanism (OpenAI `reasoning_effort` + `max_completion_tokens`; Anthropic a
`thinking` budget). Reasoning text arrives as `ReasoningDelta`, separate from
visible `TextDelta`, so you can render it differently.

```dart
final opts = ChatOptions(model: 'gpt-5.1', reasoningEffort: ReasoningEffort.high);
await for (final ev in provider.chatStream(msgs, options: opts)) { /* ... */ }
```

> Note: some current OpenAI reasoning models default `reasoning_effort` to
> `none`, so you must pass it explicitly to get thinking. llm_kit only sends it
> when you set it.

## Anthropic

```dart
final claude = AnthropicProvider(
  transport: HttpTransport(),
  apiKey: '...',
  defaultModel: 'claude-opus-4-7',
);
```

System messages are lifted into the top-level `system` field automatically;
tool results are coalesced into the user turn Anthropic expects.

## Tools + the session layer

```dart
final session = ChatSession(provider, tools: [
  Tool(
    name: 'get_weather',
    description: 'Current weather for a city',
    parameters: {
      'type': 'object',
      'properties': {'city': {'type': 'string'}},
      'required': ['city'],
    },
    execute: (args) async => '{"temp":22,"sky":"clear"}',
  ),
]);

await for (final ev in session.send('Weather in Tokyo?')) {
  switch (ev) {
    case SessionToolCallStart(:final name): print('▶ $name');
    case SessionToolCallEnd(:final name): print('✓ $name');
    case SessionText(:final delta): stdout.write(delta);
    default: break;
  }
}
```

`ChatSession` runs the full request → tool calls → execute → re-request loop
for you, and is pure Dart — wrap it in a `ValueNotifier`, Bloc, or Riverpod
notifier as you like. (The old `ChatManager extends ChangeNotifier` is gone on
purpose; it forced one state solution onto everyone.)

## What was dropped from TinyAI

- **Singletons** (`TinyAIConfig.instance`, `HttpService.instance`) — replaced
  by explicit construction so you can run two providers at once.
- **MCP** — removed per your request.
- **Title generation inside the provider** — that's an app concern; do it with
  a normal `chat()` call.
- **`MessageStatus` on the message model** — UI state doesn't belong in the
  protocol layer.
