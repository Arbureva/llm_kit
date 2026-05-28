import 'dart:convert';
import 'dart:math';

import '../core/message.dart';
import '../core/provider.dart';
import '../core/stream_event.dart';

/// How a requested tool gets executed.
///
/// Most apps fall into one of two modes, and a single session can mix them:
///
///  * **Local** — the [Tool] carries an [Tool.execute] handler and the session
///    runs it in-process. Good for trivial, synchronous-ish tools.
///
///  * **Dispatched** — the tool is executed *elsewhere* (your backend running
///    MCP servers, a CLI, skills, a remote worker) and the result is handed
///    back to the session to continue the loop. This is the common case when
///    the Flutter client itself never touches the tool. Provide a
///    [ToolDispatcher] for it.
///
/// Resolution order per call: a matching [Tool.execute] wins; otherwise the
/// [ToolDispatcher] is used; if neither exists the call is reported as an
/// error result and fed back to the model so the conversation can recover
/// instead of silently stalling.
typedef ToolDispatcher = Future<ToolResult> Function(ToolCall call);

/// Lifecycle events a UI can observe to render rich, interactive chat.
///
/// This is the seam that lets you reproduce the kind of interface you see on
/// the web: a "thinking" panel that fills in live, a tool chip that appears
/// the moment a call starts, shows a spinner while it runs, and resolves when
/// it finishes — plus streaming text and a final settled message. The session
/// emits these as plain Dart objects so you can map them to any UI framework —
/// no ChangeNotifier dependency baked into the core.
///
/// The tool lifecycle is deliberately split into distinct phases so the gap
/// between "the model asked for a tool" and "the tool came back" is never an
/// unexplained blank on screen:
///
///   [SessionToolCallStarted]   — model began emitting the call (id + name)
///   [SessionToolCallReady]     — arguments fully streamed and parsed
///   [SessionToolCallExecuting] — handed off to local handler or dispatcher
///   [SessionToolCallEnd]       — result (or error) is back
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

class SessionTitleGenerated extends SessionEvent {
  const SessionTitleGenerated(this.title);
  final String title;
}

/// The model has begun requesting a tool call. Fires as soon as id + name are
/// known, before the arguments finish streaming. This is the instant to show
/// a "calling get_weather…" chip so the page never looks frozen.
class SessionToolCallStarted extends SessionEvent {
  const SessionToolCallStarted({required this.id, required this.name});
  final String id;
  final String name;
}

/// The tool call's arguments are fully streamed and parsed. Carries the raw
/// JSON string and the decoded map (null if the model emitted invalid JSON).
/// Useful if you want to show *what* the model is about to call the tool with.
class SessionToolCallReady extends SessionEvent {
  const SessionToolCallReady({
    required this.id,
    required this.name,
    required this.arguments,
    required this.parsedArguments,
  });
  final String id;
  final String name;

  /// Raw arguments JSON exactly as the model produced it.
  final String arguments;

  /// Decoded arguments, or null if [arguments] was not valid JSON.
  final Map<String, dynamic>? parsedArguments;
}

/// The tool is now actually running — either via a local [Tool.execute] or
/// handed off to the [ToolDispatcher] (your backend). [dispatched] tells the
/// UI which path was taken; for a backend-executed MCP/CLI/skill call this is
/// the event that fills the "what is it doing right now" gap.
class SessionToolCallExecuting extends SessionEvent {
  const SessionToolCallExecuting({
    required this.id,
    required this.name,
    required this.dispatched,
  });
  final String id;
  final String name;

  /// True when execution was handed to the [ToolDispatcher]; false when a
  /// local [Tool.execute] handler ran in-process.
  final bool dispatched;
}

/// A tool finished running; [result] is its output (or error message).
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

/// Terminal event. [reason] distinguishes a clean finish from a loop that was
/// cut off because [ChatSession.maxToolRounds] was reached — the latter used
/// to end silently, leaving the UI unsure whether the turn was complete.
class SessionDone extends SessionEvent {
  const SessionDone({this.usage, this.reason = SessionStopReason.completed});
  final Usage? usage;
  final SessionStopReason reason;
}

/// An error surfaced while running the turn (transport failure, etc). The
/// stream ends after this; [error] is whatever was thrown.
class SessionError extends SessionEvent {
  const SessionError(this.error, [this.stackTrace]);
  final Object error;
  final StackTrace? stackTrace;
}

/// Why a [SessionDone] was emitted.
enum SessionStopReason {
  /// The model finished without requesting more tools.
  completed,

  /// [ChatSession.maxToolRounds] was hit before the model stopped calling
  /// tools. The last assistant turn may be incomplete.
  maxRoundsReached,
}

/// A lightweight, framework-agnostic conversation manager.
///
/// Holds message history, runs the multi-turn tool loop automatically, and
/// streams [SessionEvent]s. It deliberately does NOT extend ChangeNotifier or
/// import Flutter — wrap it in a ValueNotifier, a Bloc, a Riverpod notifier, or
/// nothing at all.
///
/// Tool execution is resolved per call: a [Tool] with an [Tool.execute] runs
/// locally; otherwise the [dispatcher] (if provided) is invoked — this is how
/// you let a backend run MCP servers, a CLI, or skills and feed the result
/// back without the client ever executing the tool itself.
class ChatSession {
  ChatSession(
    this.provider, {
    List<Tool> tools = const [],
    this.dispatcher,
    this.maxToolRounds = 5,
    String? id,
  })  : _tools = List.of(tools),
        id = id ?? _uuidV4();

  final LlmProvider provider;
  final int maxToolRounds;
  final List<Tool> _tools;
  final List<Message> _messages = [];

  /// Invoked for any requested tool that has no local [Tool.execute] handler.
  /// Leave null if every tool executes locally; calls with no handler and no
  /// dispatcher are reported back to the model as errors.
  final ToolDispatcher? dispatcher;

  List<Message> get messages => List.unmodifiable(_messages);
  List<Tool> get tools => List.unmodifiable(_tools);

  /// Stable identifier, assigned at construction.
  final String id;

  /// Human-readable title. Null until the first turn completes and a summary
  /// is generated (falling back to the first user message on failure).
  String? title;

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
    yield* _run(options: options);
  }

  /// Continue the loop from the current message history without appending a
  /// new user turn. Useful when you've imported history that ends on a tool
  /// result and want the model to keep going.
  Stream<SessionEvent> resume({ChatOptions? options}) => _run(options: options);

  Stream<SessionEvent> _run({ChatOptions? options}) async* {
    for (var round = 0; round < maxToolRounds; round++) {
      final textBuf = StringBuffer();
      final reasoningBuf = StringBuffer();
      final pending = <ToolCall>[];
      Usage? usage;

      try {
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
              yield SessionToolCallStarted(id: id, name: name);
            case ToolCallCompleted(:final toolCall):
              pending.add(toolCall);
            case StreamDone(usage: final u):
              usage = u;
            case ToolCallArgumentsDelta():
            case StreamNotice():
              break;
          }
        }
      } catch (e, st) {
        yield SessionError(e, st);
        return;
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
        if (title == null) {
          yield* _ensureTitle(options);
        }
        yield SessionDone(usage: usage, reason: SessionStopReason.completed);
        return;
      }

      // Resolve and run each requested tool, feeding results back.
      for (final call in pending) {
        // Arguments are fully streamed by now; surface them before running.
        Map<String, dynamic>? parsed;
        try {
          parsed = call.arguments.isEmpty ? <String, dynamic>{} : jsonDecode(call.arguments) as Map<String, dynamic>;
        } catch (_) {
          parsed = null; // invalid JSON; handler/dispatcher may still cope
        }
        yield SessionToolCallReady(
          id: call.id,
          name: call.name,
          arguments: call.arguments,
          parsedArguments: parsed,
        );

        final tool = _tools.where((t) => t.name == call.name).firstOrNull;
        final hasLocal = tool?.execute != null;
        final canDispatch = !hasLocal && dispatcher != null;

        // Announce execution start so a backend round-trip isn't a blank gap.
        if (hasLocal || canDispatch) {
          yield SessionToolCallExecuting(
            id: call.id,
            name: call.name,
            dispatched: canDispatch,
          );
        }

        String resultText;
        var isError = false;

        if (hasLocal) {
          try {
            final args = parsed ?? <String, dynamic>{};
            resultText = await tool!.execute!(args);
          } catch (e) {
            resultText = 'Tool execution failed: $e';
            isError = true;
          }
        } else if (canDispatch) {
          try {
            final r = await dispatcher!(call);
            resultText = r.content;
            isError = r.isError;
          } catch (e) {
            resultText = 'Tool dispatch failed: $e';
            isError = true;
          }
        } else {
          resultText = 'No executor or dispatcher registered for tool "${call.name}".';
          isError = true;
        }

        _messages.add(Message.tool(ToolResult(
          toolCallId: call.id,
          name: call.name,
          content: resultText,
          isError: isError,
        )));
        yield SessionToolCallEnd(
          id: call.id,
          name: call.name,
          result: resultText,
          isError: isError,
        );
      }
      // Loop again so the model can use the tool results.
    }

    // Fell out of the loop without the model stopping: rounds exhausted.
    yield const SessionDone(reason: SessionStopReason.maxRoundsReached);
  }

  /// Generate a short title from the conversation so far. Asks the model for a
  /// summary; on any failure falls back to the first user message (trimmed).
  Stream<SessionEvent> _ensureTitle(ChatOptions? options) async* {
    final firstUser = _messages.where((m) => m.role == Role.user).map((m) => m.content).whereType<String>().firstOrNull;

    String fallback() {
      final t = (firstUser ?? '').trim();
      if (t.isEmpty) return 'New chat';
      return t.length <= 40 ? t : '${t.substring(0, 40)}…';
    }

    String? generated;
    try {
      final buf = StringBuffer();
      await for (final ev in provider.chatStream(
        [
          Message.system(
            options?.titlePrompt ?? '我是一个标题生成AI，我将会基于用户第一个提问，为当前话题生成一个标题，简短10个字以内，不需要进行任何查询操作，按照你的理解生成文本标题即可',
          ),
          Message.user(firstUser ?? ''),
        ],
        options: options,
        tools: null,
      )) {
        if (ev case TextDelta(:final text)) buf.write(text);
      }
      final s = buf.toString().trim().replaceAll('"', '');
      if (s.isNotEmpty) generated = s.length <= 60 ? s : s.substring(0, 60);
    } catch (_) {
      generated = null;
    }

    title = generated ?? fallback();
    yield SessionTitleGenerated(title!);
  }
}

extension<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}

String _uuidV4() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  final s = b.asMap().keys.map(h).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
      '-${s.substring(16, 20)}-${s.substring(20)}';
}
