import 'dart:convert';

import '../core/message.dart';
import '../core/provider.dart';
import '../core/stream_event.dart';

/// Lifecycle events a UI can observe to render rich, interactive chat.
///
/// This is the seam that lets you reproduce the kind of interface you see on
/// the web: a "thinking" panel that fills in live, a tool chip that appears
/// the moment a call starts and resolves when it finishes, streaming text, and
/// a final settled message. The session emits these as plain Dart objects so
/// you can map them to any UI framework — no ChangeNotifier dependency baked
/// into the core.
sealed class SessionEvent {
  const SessionEvent();
}

class SessionText extends SessionEvent {
  const SessionText(this.delta);
  final String delta;
}

class SessionReasoning extends SessionEvent {
  const SessionReasoning(this.delta);
  final String delta;
}

/// A tool call has been requested and is about to run.
class SessionToolCallStart extends SessionEvent {
  const SessionToolCallStart({required this.id, required this.name});
  final String id;
  final String name;
}

/// A tool finished running; [result] is its output (or error).
class SessionToolCallEnd extends SessionEvent {
  const SessionToolCallEnd({
    required this.id,
    required this.name,
    required this.result,
    required this.isError,
  });
  final String id;
  final String name;
  final String result;
  final bool isError;
}

class SessionDone extends SessionEvent {
  const SessionDone({this.usage});
  final Usage? usage;
}

/// A lightweight, framework-agnostic conversation manager.
///
/// Holds message history, runs the multi-turn tool loop automatically, and
/// streams [SessionEvent]s. It deliberately does NOT extend ChangeNotifier or
/// import Flutter — wrap it in a ValueNotifier, a Bloc, a Riverpod notifier, or
/// nothing at all. The old ChatManager fused this logic to a specific state
/// solution; here you choose.
class ChatSession {
  ChatSession(this.provider, {List<Tool> tools = const [], this.maxToolRounds = 5})
      : _tools = List.of(tools);

  final LlmProvider provider;
  final int maxToolRounds;
  final List<Tool> _tools;
  final List<Message> _messages = [];

  List<Message> get messages => List.unmodifiable(_messages);
  List<Tool> get tools => List.unmodifiable(_tools);

  void addTool(Tool tool) => _tools.add(tool);
  void setSystem(String content) {
    _messages.removeWhere((m) => m.role == Role.system);
    _messages.insert(0, Message.system(content));
  }

  void addMessage(Message m) => _messages.add(m);
  void importHistory(List<Message> history) {
    _messages
      ..clear()
      ..addAll(history);
  }

  void clear() => _messages.removeWhere((m) => m.role != Role.system);

  /// Send a user message and stream the full interaction, including any tool
  /// rounds, as [SessionEvent]s. The tool loop runs until the model stops
  /// requesting tools or [maxToolRounds] is hit.
  Stream<SessionEvent> send(
    String content, {
    ChatOptions? options,
  }) async* {
    _messages.add(Message.user(content));

    for (var round = 0; round < maxToolRounds; round++) {
      final textBuf = StringBuffer();
      final reasoningBuf = StringBuffer();
      final pending = <ToolCall>[];
      Usage? usage;

      await for (final ev in provider.chatStream(
        _messages,
        options: options,
        tools: _tools.isEmpty ? null : _tools,
      )) {
        switch (ev) {
          case TextDelta(:final text):
            textBuf.write(text);
            yield SessionText(text);
          case ReasoningDelta(:final text):
            reasoningBuf.write(text);
            yield SessionReasoning(text);
          case ToolCallStarted(:final id, :final name):
            yield SessionToolCallStart(id: id, name: name);
          case ToolCallCompleted(:final toolCall):
            pending.add(toolCall);
          case StreamDone(usage: final u):
            usage = u;
          case ToolCallArgumentsDelta():
          case StreamNotice():
            break;
        }
      }

      // Record the assistant turn (text + any tool calls it requested).
      _messages.add(Message(
        role: Role.assistant,
        content: textBuf.isEmpty ? null : textBuf.toString(),
        toolCalls: pending.isEmpty ? null : pending,
        reasoning: reasoningBuf.isEmpty ? null : reasoningBuf.toString(),
      ));

      // No tools requested → conversation turn is complete.
      if (pending.isEmpty) {
        yield SessionDone(usage: usage);
        return;
      }

      // Execute each requested tool and feed results back.
      for (final call in pending) {
        final tool = _tools.where((t) => t.name == call.name).firstOrNull;
        String result;
        var isError = false;
        if (tool?.execute == null) {
          result = 'No executor registered for tool "${call.name}".';
          isError = true;
        } else {
          try {
            final args = call.arguments.isEmpty
                ? <String, dynamic>{}
                : jsonDecode(call.arguments) as Map<String, dynamic>;
            result = await tool!.execute!(args);
          } catch (e) {
            result = 'Tool execution failed: $e';
            isError = true;
          }
        }
        _messages.add(Message.tool(ToolResult(
          toolCallId: call.id,
          name: call.name,
          content: result,
          isError: isError,
        )));
        yield SessionToolCallEnd(
          id: call.id,
          name: call.name,
          result: result,
          isError: isError,
        );
      }
      // Loop again so the model can use the tool results.
    }

    yield const SessionDone();
  }
}

extension<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
