import 'message.dart';

/// Token-usage accounting, when the provider reports it.
class Usage {
  const Usage({
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.reasoningTokens,
  });

  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;

  /// Tokens spent on hidden reasoning (o-series / thinking models).
  final int? reasoningTokens;
}

/// Why generation stopped.
enum FinishReason { stop, length, toolCalls, contentFilter, error, unknown }

/// A typed event in a streaming response.
///
/// This sealed hierarchy is the central abstraction of the library. Every
/// provider, no matter how different its wire format, decodes its stream into
/// these events. New model capabilities (reasoning summaries, redacted
/// thinking, audio) become new event subtypes rather than provider-specific
/// special cases leaking into your UI code.
///
/// A UI can switch over the event type to drive rich, interactive rendering:
/// show a "thinking" shimmer for [ReasoningDelta], a tool chip for
/// [ToolCallStarted], a spinner that resolves for [ToolCallCompleted], etc.
sealed class StreamEvent {
  const StreamEvent();
}

/// An incremental chunk of visible assistant text.
class TextDelta extends StreamEvent {
  const TextDelta(this.text);
  final String text;
}

/// An incremental chunk of reasoning / thinking text.
///
/// Emitted by reasoning models that stream their thinking (Anthropic extended
/// thinking; OpenAI reasoning summaries where exposed). Keeping this separate
/// from [TextDelta] lets the UI render it differently — collapsed, greyed,
/// behind a "show thinking" toggle — without guessing.
class ReasoningDelta extends StreamEvent {
  const ReasoningDelta(this.text);
  final String text;
}

/// Signals that the model has begun a tool call. Fires once per call as soon
/// as the id/name are known, *before* arguments finish streaming. This is the
/// hook for showing "Calling get_weather…" the instant it starts.
class ToolCallStarted extends StreamEvent {
  const ToolCallStarted({required this.index, required this.id, required this.name});
  final int index;
  final String id;
  final String name;
}

/// An incremental fragment of a tool call's JSON arguments.
class ToolCallArgumentsDelta extends StreamEvent {
  const ToolCallArgumentsDelta({required this.index, required this.delta});
  final int index;
  final String delta;
}

/// A tool call whose arguments are now complete and parseable.
class ToolCallCompleted extends StreamEvent {
  const ToolCallCompleted(this.toolCall);
  final ToolCall toolCall;
}

/// Terminal event. Carries the finish reason and usage if known.
class StreamDone extends StreamEvent {
  const StreamDone({this.finishReason, this.usage});
  final FinishReason? finishReason;
  final Usage? usage;
}

/// A non-fatal provider notice surfaced mid-stream (rate-limit warning, etc).
class StreamNotice extends StreamEvent {
  const StreamNotice(this.message);
  final String message;
}
