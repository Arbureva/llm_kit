import 'dart:convert';
import 'dart:math';

import '../core/message.dart';
import '../core/provider.dart';
import '../core/stream_event.dart';

/// How a requested tool gets executed.
///
/// Three outcomes, and a single session can mix them:
///
///  * **Local** — the [Tool] carries an [Tool.execute] handler and the session
///    runs it in-process. Good for trivial, synchronous-ish tools.
///
///  * **Dispatched (handled here)** — the [ToolDispatcher] returns a
///    [ToolResult]. Use this for tools the *client* fulfils interactively,
///    such as a form the user fills in. The result is fed back to the model
///    and the loop continues.
///
///  * **Dispatched (skipped)** — the [ToolDispatcher] returns `null`, meaning
///    "not my job". This is the case for backend tools in a setup where the
///    frontend posts messages to a backend that runs the tool and feeds the
///    result back itself. The session does NOT fabricate a result; it leaves
///    the unhandled tool call in the assistant turn and ends this `send`. Your
///    next request to the backend carries that pending call, and the backend
///    executes it and continues. See [ChatSession] docs for the full flow.
///
/// Resolution order per call: a matching [Tool.execute] wins; otherwise the
/// [ToolDispatcher] is consulted. A null dispatcher, or a dispatcher that
/// returns null, means the call is left for something downstream to handle.
typedef ToolDispatcher = Future<ToolResult?> Function(ToolCall call);

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

  /// The turn ended with one or more tool calls the frontend does not handle
  /// (the dispatcher returned null for them, or there was no dispatcher).
  /// Those calls remain in the assistant turn; the expectation is that the
  /// next request to your backend carries this history, the backend executes
  /// the pending tool(s), feeds the result(s) back, and continues. Call
  /// [ChatSession.resume] when control returns to the frontend.
  handedOffToBackend,
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
    // 前端是否参与工具循环。
    //   有 execute 或有 dispatcher = 前端跑循环：本地工具就地执行，
    //   表单类前端工具由 dispatcher 返回结果，后端工具由 dispatcher 返回 null
    //   「跳过」——把它原样留在 assistant 轮里、不回填，然后结束本次 send，
    //   交由后端在下一次请求时执行并续跑（见 handedOffToBackend）。
    //   两者皆无 = 纯展示直通：后端已跑完循环、把最终文本随流返回，
    //   流里的 tool_calls 仅供展示，绝不落进历史（否则会得到
    //   「assistant(tool_calls) 后面没有 tool 消息」→ 400）。
    final canExecuteTools = _tools.any((t) => t.execute != null) || dispatcher != null;

    for (var round = 0; round < maxToolRounds; round++) {
      final textBuf = StringBuffer();
      final reasoningBuf = StringBuffer();
      String? reasoningSignature;
      final pending = <ToolCall>[];
      Usage? usage;

      try {
        await for (final ev in provider.chatStream(
          _messages,
          options: options,
          tools: _tools.isEmpty ? null : _tools,
        )) {
          switch (ev) {
            /// 普通
            case TextDelta(:final text):
              textBuf.write(text);
              yield SessionText(text);

            /// 深度思考
            case ReasoningDelta(:final text):
              reasoningBuf.write(text);
              yield SessionReasoning(text);

            /// 深度思考签名
            case ReasoningSignature(:final signature):
              reasoningSignature = signature; // 回传 thinking 块所必需

            /// 工具调用开始
            case ToolCallStarted(:final id, :final name):
              yield SessionToolCallStarted(id: id, name: name); // 仍可显示「正在调用…」

            /// 工具调用结束
            case ToolCallCompleted(:final toolCall):
              pending.add(toolCall);

            /// 权威消息
            case ChunkMessage(:final message):
              _messages.add(message);

            /// 流停止
            case StreamDone(usage: final u):
              usage = u;

            /// 工具参数
            case ToolCallArgumentsDelta():

            /// 流提醒
            case StreamNotice():
              break;
          }
        }
      } catch (e, st) {
        yield SessionError(e, st);
        return;
      }

      // —— 展示直通模式：后端已执行工具，流里的文本就是完整答案 ——
      if (!canExecuteTools) {
        if (textBuf.isNotEmpty || reasoningBuf.isNotEmpty) {
          _messages.add(Message(
            role: Role.assistant,
            content: textBuf.isEmpty ? null : textBuf.toString(),
            reasoning: reasoningBuf.isEmpty ? null : reasoningBuf.toString(),
            // 注意：不带 toolCalls
          ));
        }
        if (title == null) yield* _ensureTitle(options);
        yield SessionDone(usage: usage, reason: SessionStopReason.completed);
        return;
      }

      // —— 以下是前端自跑工具循环的原逻辑，仅当确有执行能力时才进入 ——
      if (textBuf.isNotEmpty || pending.isNotEmpty) {
        _messages.add(Message(
          role: Role.assistant,
          content: textBuf.isEmpty ? null : textBuf.toString(),
          toolCalls: pending.isEmpty ? null : pending,
          reasoning: reasoningBuf.isEmpty ? null : reasoningBuf.toString(),
          reasoningSignature: reasoningSignature, // 下一轮回传 thinking 块所必需
        ));
      }

      if (pending.isEmpty) {
        if (title == null) yield* _ensureTitle(options);
        yield SessionDone(usage: usage, reason: SessionStopReason.completed);
        return;
      }

      // Resolve and run each requested tool, feeding results back.
      var handedOff = false;
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

        if (hasLocal) {
          yield SessionToolCallExecuting(
            id: call.id,
            name: call.name,
            dispatched: false,
          );
          String resultText;
          var isError = false;
          try {
            resultText = await tool!.execute!(parsed ?? <String, dynamic>{});
          } catch (e) {
            resultText = 'Tool execution failed: $e';
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
          continue;
        }

        // No local handler. Ask the dispatcher — but it may decline (null),
        // meaning "not the frontend's job; leave it for the backend".
        ToolResult? dispatched;
        if (dispatcher != null) {
          yield SessionToolCallExecuting(
            id: call.id,
            name: call.name,
            dispatched: true,
          );
          try {
            dispatched = await dispatcher!(call);
          } catch (e) {
            // A dispatcher that throws is treated as a handled error result,
            // not a hand-off — the frontend tried and failed.
            dispatched = ToolResult(
              toolCallId: call.id,
              name: call.name,
              content: 'Tool dispatch failed: $e',
              isError: true,
            );
          }
        }

        if (dispatched != null) {
          // Frontend handled it (e.g. a form). Feed the result back.
          _messages.add(Message.tool(dispatched));
          yield SessionToolCallEnd(
            id: call.id,
            name: call.name,
            result: dispatched.content,
            isError: dispatched.isError,
          );
        } else {
          // Unhandled: leave the tool call in the assistant turn with NO
          // tool result. The backend will execute it on the next request.
          // Do not fabricate a result — that would consume the pending call
          // and break the backend's "is this call still pending?" check.
          handedOff = true;
        }
      }

      // If any call this round was left for the backend, stop here: the
      // frontend's job is done until the backend executes it and we're driven
      // again (call resume() when control returns). Looping now would either
      // spin or resend an assistant turn whose tool calls have no results.
      if (handedOff) {
        if (title == null) yield* _ensureTitle(options);
        yield SessionDone(usage: usage, reason: SessionStopReason.handedOffToBackend);
        return;
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
