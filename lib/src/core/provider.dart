import 'message.dart';
import 'stream_event.dart';

/// A tool the model may call.
///
/// Split deliberately into a *schema* ([name], [description], [parameters])
/// and an *executor* ([execute]). The schema is what gets serialized into the
/// request; the executor is local Dart that runs when the model calls it. The
/// old design conflated these on one abstract class, which made it awkward to
/// declare tools the host app executes elsewhere. Here, [execute] is optional:
/// omit it for tools you dispatch yourself.
class Tool {
  const Tool({
    required this.name,
    required this.description,
    required this.parameters,
    this.execute,
  });

  final String name;
  final String description;

  /// JSON Schema object describing the arguments.
  final Map<String, dynamic> parameters;

  /// Optional local handler. Receives decoded arguments, returns a string
  /// result. Leave null if your application routes execution itself.
  final Future<String> Function(Map<String, dynamic> args)? execute;
}

/// Knobs for a single request. Provider-neutral; each provider maps the
/// fields it understands and ignores the rest. [extra] is an escape hatch for
/// provider-specific parameters without subclassing.
class ChatOptions {
  const ChatOptions({
    this.model,
    this.temperature,
    this.maxTokens,
    this.topP,
    this.stop,
    this.toolChoice,
    this.reasoningEffort,
    this.extra,
    this.titlePrompt,
  });

  final String? model;
  final double? temperature;
  final int? maxTokens;
  final double? topP;
  final List<String>? stop;
  final String? titlePrompt;

  /// 'auto' | 'none' | 'required' | a specific tool name.
  final String? toolChoice;

  /// Controls reasoning depth on models that support it. Providers map this
  /// to their own field (OpenAI reasoning_effort; Anthropic thinking budget).
  final ReasoningEffort? reasoningEffort;

  /// Raw provider-specific fields merged into the request body verbatim.
  final Map<String, dynamic>? extra;
}

enum ReasoningEffort { minimal, low, medium, high }

/// The full result of a non-streaming completion.
class ChatResult {
  const ChatResult({
    required this.content,
    this.reasoning,
    this.toolCalls,
    this.finishReason,
    this.usage,
    this.raw,
  });

  final String content;
  final String? reasoning;
  final List<ToolCall>? toolCalls;
  final FinishReason? finishReason;
  final Usage? usage;

  /// The undecoded provider response, for debugging / advanced use.
  final Map<String, dynamic>? raw;

  bool get hasToolCalls => toolCalls != null && toolCalls!.isNotEmpty;
}

/// What every provider implements.
///
/// Just two operations. Tool execution, multi-turn orchestration, and session
/// state are NOT here — they are higher-level concerns built on top of this in
/// the session layer, so a provider stays a thin protocol translator.
abstract class LlmProvider {
  /// Single completion, fully buffered.
  Future<ChatResult> chat(List<Message> messages, {ChatOptions? options, List<Tool>? tools});

  /// Streaming completion as typed [StreamEvent]s.
  Stream<StreamEvent> chatStream(List<Message> messages, {ChatOptions? options, List<Tool>? tools});
}
