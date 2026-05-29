import 'dart:convert';

import '../../core/message.dart';
import '../../core/provider.dart';
import '../../core/sse.dart';
import '../../core/stream_event.dart';
import '../../transport/transport.dart';

/// Provider for the OpenAI Chat Completions API and any OpenAI-compatible
/// endpoint (DeepSeek, Qwen, Together, local vLLM/Ollama, OpenRouter...).
///
/// Reasoning handling reflects the current API: reasoning models read
/// `max_completion_tokens` rather than `max_tokens`, accept `reasoning_effort`
/// (which several models now default to "none", so it is only sent when you
/// ask for it), reject `temperature`/`top_p`/`stop`, and stream their thinking
/// as a `reasoning_content` delta field — the convention OpenAI-compatible
/// servers also adopted.
class OpenAIProvider implements LlmProvider {
  OpenAIProvider({
    required this.transport,
    required this.apiKey,
    this.baseUrl = 'https://api.openai.com/v1',
    this.defaultModel = 'gpt-4o-mini',
    this.defaultHeaders = const {},
    this.timeout,
  });

  final LlmTransport transport;
  final String apiKey;
  final String baseUrl;
  final String defaultModel;

  /// Static headers added to every request (e.g. OpenRouter attribution).
  final Map<String, String> defaultHeaders;
  final Duration? timeout;

  Map<String, String> _headers() => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
        ...defaultHeaders,
      };

  /// Heuristic: o-series and gpt-5+ are reasoning models with different
  /// parameter rules. Override by setting fields explicitly via ChatOptions.extra.
  bool _isReasoningModel(String model) {
    final m = model.toLowerCase();
    return m.startsWith('o1') || m.startsWith('o3') || m.startsWith('o4') || m.startsWith('gpt-5');
  }

  Map<String, dynamic> _buildBody(
    List<Message> messages, {
    required ChatOptions? options,
    required List<Tool>? tools,
    required bool stream,
  }) {
    final model = options?.model ?? defaultModel;
    final reasoning = _isReasoningModel(model);

    final body = <String, dynamic>{
      'model': model,
      'messages': messages.map(_messageToJson).toList(),
      if (stream) 'stream': true,
      if (stream) 'stream_options': {'include_usage': true},
    };

    // Reasoning models use max_completion_tokens and reject sampling knobs.
    if (options?.maxTokens != null) {
      body[reasoning ? 'max_completion_tokens' : 'max_tokens'] = options!.maxTokens;
    }
    if (!reasoning) {
      if (options?.temperature != null) body['temperature'] = options!.temperature;
      if (options?.topP != null) body['top_p'] = options!.topP;
      if (options?.stop != null) body['stop'] = options!.stop;
    }
    if (reasoning && options?.reasoningEffort != null) {
      body['reasoning_effort'] = options!.reasoningEffort!.name;
    }

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools.map(_toolToJson).toList();
      if (options?.toolChoice != null) {
        body['tool_choice'] = _toolChoice(options!.toolChoice!);
      }
    }

    if (options?.extra != null) body.addAll(options!.extra!);
    return body;
  }

  dynamic _toolChoice(String choice) {
    if (choice == 'auto' || choice == 'none' || choice == 'required') {
      return choice;
    }
    return {
      'type': 'function',
      'function': {'name': choice}
    };
  }

  Map<String, dynamic> _toolToJson(Tool t) => {
        'type': 'function',
        'function': {
          'name': t.name,
          'description': t.description,
          'parameters': t.parameters,
        },
      };

  Map<String, dynamic> _messageToJson(Message m) {
    final json = <String, dynamic>{'role': m.role.name};

    switch (m.role) {
      case Role.assistant:
        // 关键：content 必须是字符串、不能是 null。
        // eino/einobridge 把「带 tool_calls 的 assistant 轮」表示为 content="" + tool_calls，
        // 收到 content:null 会判定为「未设置」，于是报 content or tool_calls must be set。
        json['content'] = m.content ?? '';
        if (m.hasToolCalls) {
          json['tool_calls'] = m.toolCalls!.map((tc) => tc.toJson()).toList();
        }
      case Role.tool:
        json['content'] = m.content ?? '';
        if (m.toolResult != null) {
          json['tool_call_id'] = m.toolResult!.toolCallId;
        }
        if (m.name != null) json['name'] = m.name;
      default: // system / user
        if (m.content != null) json['content'] = m.content;
        if (m.name != null) json['name'] = m.name;
    }
    return json;
  }

  @override
  Future<ChatResult> chat(
    List<Message> messages, {
    ChatOptions? options,
    List<Tool>? tools,
  }) async {
    final body = _buildBody(messages, options: options, tools: tools, stream: false);
    final resp = await transport.send(LlmRequest(
      method: 'POST',
      url: Uri.parse('$baseUrl/chat/completions'),
      headers: _headers(),
      body: jsonEncode(body),
      timeout: timeout,
    ));

    final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final choice = (json['choices'] as List).first as Map<String, dynamic>;
    final msg = choice['message'] as Map<String, dynamic>;

    return ChatResult(
      content: (msg['content'] as String?) ?? '',
      reasoning: msg['reasoning_content'] as String?,
      toolCalls: _parseToolCalls(msg['tool_calls']),
      finishReason: _finishReason(choice['finish_reason'] as String?),
      usage: _parseUsage(json['usage']),
      raw: json,
    );
  }

  List<ToolCall>? _parseToolCalls(dynamic raw) {
    if (raw is! List || raw.isEmpty) return null;
    return raw.map((tc) {
      final fn = tc['function'] as Map<String, dynamic>;
      return ToolCall(
        id: tc['id'] as String,
        name: fn['name'] as String,
        arguments: (fn['arguments'] as String?) ?? '',
      );
    }).toList();
  }

  Usage? _parseUsage(dynamic raw) {
    if (raw is! Map) return null;
    final details = raw['completion_tokens_details'];
    return Usage(
      promptTokens: raw['prompt_tokens'] as int?,
      completionTokens: raw['completion_tokens'] as int?,
      totalTokens: raw['total_tokens'] as int?,
      reasoningTokens: details is Map ? details['reasoning_tokens'] as int? : null,
    );
  }

  FinishReason? _finishReason(String? r) => switch (r) {
        'stop' => FinishReason.stop,
        'length' => FinishReason.length,
        'tool_calls' => FinishReason.toolCalls,
        'content_filter' => FinishReason.contentFilter,
        null => null,
        _ => FinishReason.unknown,
      };

  @override
  Stream<StreamEvent> chatStream(
    List<Message> messages, {
    ChatOptions? options,
    List<Tool>? tools,
  }) async* {
    final body = _buildBody(messages, options: options, tools: tools, stream: true);
    final byteStream = transport.sendStream(LlmRequest(
      method: 'POST',
      url: Uri.parse('$baseUrl/chat/completions'),
      headers: _headers(),
      body: jsonEncode(body),
      timeout: timeout,
    ));

    // Accumulators for tool calls streamed as fragments.
    final names = <int, String>{};
    final ids = <int, String>{};
    final argsBuf = <int, StringBuffer>{};
    final started = <int>{};
    FinishReason? finish;
    Usage? usage;

    await for (final sse in decodeSse(byteStream)) {
      final payload = sse.data.trim();
      if (payload.isEmpty) continue;
      if (payload == '[DONE]') break;

      Map<String, dynamic> obj;
      try {
        obj = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }

      if (obj['usage'] != null) usage = _parseUsage(obj['usage']);

      final choices = obj['choices'] as List?;
      if (choices == null || choices.isEmpty) continue;
      final choice = choices.first as Map<String, dynamic>;

      final fr = _finishReason(choice['finish_reason'] as String?);
      if (fr != null) finish = fr;

      final delta = choice['delta'] as Map<String, dynamic>?;
      if (delta == null) continue;

      // Reasoning models stream thinking in a separate field.
      final reasoning = delta['reasoning_content'];
      if (reasoning is String && reasoning.isNotEmpty) {
        yield ReasoningDelta(reasoning);
      }

      final content = delta['content'];
      if (content is String && content.isNotEmpty) {
        yield TextDelta(content);
      }

      final tcs = delta['tool_calls'];
      if (tcs is List) {
        for (final t in tcs) {
          final index = (t['index'] as int?) ?? 0;
          final fn = (t['function'] as Map?) ?? const {};
          final name = fn['name'] as String?;
          final argFrag = fn['arguments'] as String?;
          final id = t['id'] as String?;

          if (id != null) ids[index] = id;
          if (name != null && name.isNotEmpty) names[index] = name;
          argsBuf.putIfAbsent(index, () => StringBuffer());

          // Fire "started" once we know id + name, before args complete.
          if (!started.contains(index) && ids.containsKey(index) && names.containsKey(index)) {
            started.add(index);
            yield ToolCallStarted(
              index: index,
              id: ids[index]!,
              name: names[index]!,
            );
          }

          if (argFrag != null && argFrag.isNotEmpty) {
            argsBuf[index]!.write(argFrag);
            yield ToolCallArgumentsDelta(index: index, delta: argFrag);
          }
        }
      }
    }

    // Emit completed tool calls.
    for (final index in argsBuf.keys.toList()..sort()) {
      yield ToolCallCompleted(ToolCall(
        id: ids[index] ?? 'call_$index',
        name: names[index] ?? '',
        arguments: argsBuf[index]!.toString(),
      ));
    }

    yield StreamDone(finishReason: finish, usage: usage);
  }
}
