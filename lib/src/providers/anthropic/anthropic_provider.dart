import 'dart:convert';

import '../../core/message.dart';
import '../../core/provider.dart';
import '../../core/sse.dart';
import '../../core/stream_event.dart';
import '../../transport/transport.dart';

/// Provider for the Anthropic Messages API.
///
/// Anthropic differs from OpenAI in several ways this maps over: the system
/// prompt is a top-level field (not a message), assistant turns are arrays of
/// typed content blocks, tool calls are `tool_use` blocks and results are
/// `tool_result` blocks nested in a user turn, and extended thinking streams
/// as `thinking_delta` events inside a thinking content block. The block's
/// `signature` must be preserved to feed thinking back in later turns, so we
/// retain it on the reasoning text when present.
class AnthropicProvider implements LlmProvider {
  AnthropicProvider({
    required this.transport,
    required this.apiKey,
    this.baseUrl = 'https://api.anthropic.com/v1',
    this.defaultModel = 'claude-sonnet-4-6',
    this.version = '2023-06-01',
    this.defaultMaxTokens = 4096,
    this.defaultHeaders = const {},
    this.timeout,
  });

  final LlmTransport transport;
  final String apiKey;
  final String baseUrl;
  final String defaultModel;
  final String version;

  /// Anthropic requires max_tokens; this is used when the caller omits it.
  final int defaultMaxTokens;
  final Map<String, String> defaultHeaders;
  final Duration? timeout;

  Map<String, String> _headers() => {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': version,
        ...defaultHeaders,
      };

  /// Map the neutral ReasoningEffort to a thinking token budget. Rough but
  /// reasonable defaults; override precisely via ChatOptions.extra['thinking'].
  int _thinkingBudget(ReasoningEffort effort) => switch (effort) {
        ReasoningEffort.minimal => 1024,
        ReasoningEffort.low => 4096,
        ReasoningEffort.medium => 10000,
        ReasoningEffort.high => 24000,
      };

  Map<String, dynamic> _buildBody(
    List<Message> messages, {
    required ChatOptions? options,
    required List<Tool>? tools,
    required bool stream,
  }) {
    // Pull system messages out into the top-level system field.
    final systemParts = messages.where((m) => m.role == Role.system && m.content != null).map((m) => m.content!).toList();
    final convo = messages.where((m) => m.role != Role.system).toList();

    final body = <String, dynamic>{
      'model': options?.model ?? defaultModel,
      'max_tokens': options?.maxTokens ?? defaultMaxTokens,
      'messages': _buildMessages(convo),
      if (systemParts.isNotEmpty) 'system': systemParts.join('\n\n'),
      if (stream) 'stream': true,
    };

    if (options?.temperature != null) body['temperature'] = options!.temperature;
    if (options?.topP != null) body['top_p'] = options!.topP;
    if (options?.stop != null) body['stop_sequences'] = options!.stop;

    if (options?.reasoningEffort != null && (options?.extra?['thinking'] == null)) {
      body['thinking'] = {
        'type': 'enabled',
        'budget_tokens': _thinkingBudget(options!.reasoningEffort!),
      };
    }

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools
          .map((t) => {
                'name': t.name,
                'description': t.description,
                'input_schema': t.parameters,
              })
          .toList();
      if (options?.toolChoice != null) {
        body['tool_choice'] = _toolChoice(options!.toolChoice!);
      }
    }

    if (options?.extra != null) body.addAll(options!.extra!);
    return body;
  }

  dynamic _toolChoice(String choice) => switch (choice) {
        'auto' => {'type': 'auto'},
        'none' => {'type': 'none'},
        'required' => {'type': 'any'},
        _ => {'type': 'tool', 'name': choice},
      };

  /// Build Anthropic's content-block message array. Consecutive tool results
  /// are coalesced into a single user turn, as the API expects.
  List<Map<String, dynamic>> _buildMessages(List<Message> convo) {
    final out = <Map<String, dynamic>>[];

    for (final m in convo) {
      if (m.role == Role.tool && m.toolResult != null) {
        final block = {
          'type': 'tool_result',
          'tool_use_id': m.toolResult!.toolCallId,
          'content': m.toolResult!.content,
          if (m.toolResult!.isError) 'is_error': true,
        };
        // Append to a trailing user turn if one is open, else start a new one.
        if (out.isNotEmpty && out.last['role'] == 'user' && out.last['content'] is List) {
          (out.last['content'] as List).add(block);
        } else {
          out.add({
            'role': 'user',
            'content': [block]
          });
        }
        continue;
      }

      if (m.role == Role.assistant) {
        final blocks = <Map<String, dynamic>>[];
        // Thinking must come first, and only with its signature — Anthropic
        // rejects a thinking block without one, and rejects a thinking+tools
        // assistant turn fed back without the thinking block. So: include it
        // when we have both, skip it otherwise.
        if (m.reasoning != null && m.reasoning!.isNotEmpty && m.reasoningSignature != null && m.reasoningSignature!.isNotEmpty) {
          blocks.add({
            'type': 'thinking',
            'thinking': m.reasoning,
            'signature': m.reasoningSignature,
          });
        }
        if (m.content != null && m.content!.isNotEmpty) {
          blocks.add({'type': 'text', 'text': m.content});
        }
        if (m.hasToolCalls) {
          for (final tc in m.toolCalls!) {
            blocks.add({
              'type': 'tool_use',
              'id': tc.id,
              'name': tc.name,
              'input': tc.arguments.isEmpty ? <String, dynamic>{} : jsonDecode(tc.arguments),
            });
          }
        }
        out.add({'role': 'assistant', 'content': blocks});
        continue;
      }

      // Plain user turn.
      out.add({'role': 'user', 'content': m.content ?? ''});
    }
    return out;
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
      url: Uri.parse('$baseUrl/messages'),
      headers: _headers(),
      body: jsonEncode(body),
      timeout: timeout,
    ));

    final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final content = json['content'] as List? ?? const [];

    final textBuf = StringBuffer();
    final reasoningBuf = StringBuffer();
    String? reasoningSignature;
    final toolCalls = <ToolCall>[];

    for (final block in content) {
      switch (block['type']) {
        case 'text':
          textBuf.write(block['text'] ?? '');
        case 'thinking':
          reasoningBuf.write(block['thinking'] ?? '');
          final sig = block['signature'] as String?;
          if (sig != null && sig.isNotEmpty) reasoningSignature = sig;
        case 'tool_use':
          toolCalls.add(ToolCall(
            id: block['id'] as String,
            name: block['name'] as String,
            arguments: jsonEncode(block['input'] ?? {}),
          ));
      }
    }

    return ChatResult(
      content: textBuf.toString(),
      reasoning: reasoningBuf.isEmpty ? null : reasoningBuf.toString(),
      reasoningSignature: reasoningSignature,
      toolCalls: toolCalls.isEmpty ? null : toolCalls,
      finishReason: _stopReason(json['stop_reason'] as String?),
      usage: _parseUsage(json['usage']),
      raw: json,
    );
  }

  Usage? _parseUsage(dynamic raw) {
    if (raw is! Map) return null;
    final input = raw['input_tokens'] as int?;
    final output = raw['output_tokens'] as int?;
    return Usage(
      promptTokens: input,
      completionTokens: output,
      totalTokens: (input ?? 0) + (output ?? 0),
    );
  }

  FinishReason? _stopReason(String? r) => switch (r) {
        'end_turn' => FinishReason.stop,
        'stop_sequence' => FinishReason.stop,
        'max_tokens' => FinishReason.length,
        'tool_use' => FinishReason.toolCalls,
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
      url: Uri.parse('$baseUrl/messages'),
      headers: _headers(),
      body: jsonEncode(body),
      timeout: timeout,
    ));

    // index -> tool call accumulation (content blocks are addressed by index)
    final toolIds = <int, String>{};
    final toolNames = <int, String>{};
    final toolArgs = <int, StringBuffer>{};
    final isToolBlock = <int, bool>{};
    final sigBuf = <int, StringBuffer>{};
    FinishReason? finish;
    Usage? usage;

    await for (final sse in decodeSse(byteStream)) {
      final payload = sse.data.trim();
      if (payload.isEmpty) continue;

      Map<String, dynamic> obj;
      try {
        obj = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }

      switch (obj['type']) {
        case 'content_block_start':
          final index = obj['index'] as int? ?? 0;
          final block = obj['content_block'] as Map<String, dynamic>?;
          if (block?['type'] == 'tool_use') {
            isToolBlock[index] = true;
            toolIds[index] = block!['id'] as String;
            toolNames[index] = block['name'] as String;
            toolArgs[index] = StringBuffer();
            yield ToolCallStarted(
              index: index,
              id: toolIds[index]!,
              name: toolNames[index]!,
            );
          }

        case 'content_block_delta':
          final index = obj['index'] as int? ?? 0;
          final delta = obj['delta'] as Map<String, dynamic>?;
          if (delta == null) break;
          switch (delta['type']) {
            case 'text_delta':
              final t = delta['text'] as String?;
              if (t != null && t.isNotEmpty) yield TextDelta(t);
            case 'thinking_delta':
              final t = delta['thinking'] as String?;
              if (t != null && t.isNotEmpty) yield ReasoningDelta(t);
            case 'input_json_delta':
              final frag = delta['partial_json'] as String? ?? '';
              if (frag.isNotEmpty) {
                toolArgs[index]?.write(frag);
                yield ToolCallArgumentsDelta(index: index, delta: frag);
              }
            case 'signature_delta':
              // Accumulate the thinking block's signature; surfaced at
              // content_block_stop so it can be round-tripped next turn.
              final sig = delta['signature'] as String?;
              if (sig != null && sig.isNotEmpty) {
                (sigBuf[index] ??= StringBuffer()).write(sig);
              }
          }

        case 'content_block_stop':
          final index = obj['index'] as int? ?? 0;
          if (isToolBlock[index] == true) {
            yield ToolCallCompleted(ToolCall(
              id: toolIds[index] ?? 'tool_$index',
              name: toolNames[index] ?? '',
              arguments: toolArgs[index]?.toString() ?? '{}',
            ));
          } else if (sigBuf[index] != null && sigBuf[index]!.isNotEmpty) {
            yield ReasoningSignature(sigBuf[index]!.toString());
          }

        case 'message_delta':
          final d = obj['delta'] as Map<String, dynamic>?;
          final sr = _stopReason(d?['stop_reason'] as String?);
          if (sr != null) finish = sr;
          if (obj['usage'] is Map) {
            final u = obj['usage'] as Map;
            usage = Usage(
              completionTokens: u['output_tokens'] as int?,
              totalTokens: u['output_tokens'] as int?,
            );
          }

        case 'message_stop':
          // terminal; loop will end when the byte stream closes
          break;

        case 'error':
          final msg = (obj['error'] as Map?)?['message']?.toString() ?? 'stream error';
          throw TransportException(msg);
      }
    }

    yield StreamDone(finishReason: finish, usage: usage);
  }
}
