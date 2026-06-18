/// Who authored a message.
enum Role { system, user, assistant, tool }

/// A request to call a tool, as emitted by the model.
///
/// [arguments] is the raw JSON string exactly as the model produced it. It is
/// kept as a string (not decoded) because streaming deltas arrive as partial
/// JSON fragments, and only the caller knows when it is safe to decode.
class ToolCall {
  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final String arguments;

  ToolCall copyWith({String? id, String? name, String? arguments}) => ToolCall(
    id: id ?? this.id,
    name: name ?? this.name,
    arguments: arguments ?? this.arguments,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
  };

  /// Inverse of [toJson]. Also accepts a flat `{id, name, arguments}` shape so
  /// you can persist history however you like and still read it back.
  factory ToolCall.fromJson(Map<String, dynamic> json) {
    final fn = json['function'];
    if (fn is Map) {
      return ToolCall(
        id: json['id'] as String,
        name: fn['name'] as String,
        arguments: (fn['arguments'] as String?) ?? '',
      );
    }
    return ToolCall(
      id: json['id'] as String,
      name: json['name'] as String,
      arguments: (json['arguments'] as String?) ?? '',
    );
  }
}

/// The result of running a tool, fed back to the model.
class ToolResult {
  const ToolResult({
    required this.toolCallId,
    required this.name,
    required this.content,
    this.isError = false,
  });

  final String toolCallId;
  final String name;
  final String content;
  final bool isError;

  Map<String, dynamic> toJson() => {
    'tool_call_id': toolCallId,
    'name': name,
    'content': content,
    'is_error': isError,
  };

  factory ToolResult.fromJson(Map<String, dynamic> json) => ToolResult(
    toolCallId: json['tool_call_id'] as String,
    name: json['name'] as String,
    content: (json['content'] as String?) ?? '',
    isError: (json['is_error'] as bool?) ?? false,
  );
}

/// A single conversation turn.
///
/// Deliberately neutral: providers translate this to and from their own wire
/// formats. UI concerns like "status" that lived on the old ChatMessage are
/// intentionally gone — those belong to a UI layer, not the protocol model.
class Message {
  Message({
    required this.role,
    this.content,
    this.name,
    this.toolCalls,
    this.toolResult,
    this.reasoning,
    this.reasoningSignature,
  });

  final Role role;

  /// Plain text content. Null when the assistant only emitted tool calls.
  String? content;

  /// Optional name (used by some providers for tool/function attribution).
  final String? name;

  /// Tool calls the assistant requested in this turn.
  final List<ToolCall>? toolCalls;

  /// Present only on [Role.tool] messages: the output of a tool.
  final ToolResult? toolResult;

  /// Reasoning / thinking text, when the provider exposes it and the caller
  /// chose to retain it. Not all providers round-trip this back.
  final String? reasoning;

  /// Provider signature for the reasoning block (Anthropic). Must be retained
  /// and fed back with the thinking block on the next turn when thinking is
  /// used together with tools, or the request is rejected. Null for providers
  /// that don't sign thinking, or when it wasn't captured.
  final String? reasoningSignature;

  bool get hasToolCalls => toolCalls != null && toolCalls!.isNotEmpty;

  /// Serialize for history persistence. Snake_case keys to match the wire
  /// conventions and your backend's JSON tags.
  Map<String, dynamic> toJson() => {
    'role': role.name,
    if (content != null) 'content': content,
    if (name != null) 'name': name,
    if (hasToolCalls) 'tool_calls': toolCalls!.map((t) => t.toJson()).toList(),
    if (toolResult != null) 'tool_result': toolResult!.toJson(),
    if (reasoning != null) 'reasoning': reasoning,
    if (reasoningSignature != null) 'reasoning_signature': reasoningSignature,
  };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
    role: Role.values.byName(json['role'] as String),
    content: json['content'] as String?,
    name: json['name'] as String?,
    toolCalls: (json['tool_calls'] as List?)
        ?.map((e) => ToolCall.fromJson(e as Map<String, dynamic>))
        .toList(),
    toolResult: json['tool_result'] == null
        ? null
        : ToolResult.fromJson(json['tool_result'] as Map<String, dynamic>),
    reasoning: json['reasoning'] as String?,
    reasoningSignature: json['reasoning_signature'] as String?,
  );

  factory Message.system(String content) =>
      Message(role: Role.system, content: content);

  factory Message.user(String content) =>
      Message(role: Role.user, content: content);

  factory Message.assistant(String content) =>
      Message(role: Role.assistant, content: content);

  factory Message.tool(ToolResult result) => Message(
    role: Role.tool,
    content: result.content,
    name: result.name,
    toolResult: result,
  );
}
