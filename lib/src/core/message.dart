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

  bool get hasToolCalls => toolCalls != null && toolCalls!.isNotEmpty;

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
