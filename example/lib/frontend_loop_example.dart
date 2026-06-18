// Frontend-driven tool loop — end-to-end wiring.
//
// Loop owner = the frontend. The backend is a stateless two-endpoint service:
//   POST /v1/chat/completions  — injects ALL tool schemas, streams the model
//                                response back verbatim, does NOT run a loop.
//   POST /tool/execute         — runs ONE backend MCP tool, returns its result.
//
// The frontend sends no tool schemas (so backend tools stay invisible); it
// only knows the *names* of the frontend (form) tools to route them locally.
//
// This file is illustrative — copy the wiring into your app. `backendExecute`
// is a stand-in for your real HTTP call to /tool/execute.

import 'dart:convert';

import 'package:llm_kit/llm_kit.dart';

/// Names of tools the *client* fulfils by asking the user. Their schemas live
/// on the backend (single source of truth) and get injected into /chat; the
/// frontend only needs to recognise the names to route execution locally.
const frontendTools = {'collect_user_info', 'pick_date'};

Future<ChatSession> buildSession() async {
  final transport = HttpTransport(); // swap for your Dio-with-cookies adapter

  // baseUrl points at YOUR backend proxy, not api.openai.com. The proxy speaks
  // the OpenAI wire format and injects tools; nothing else changes here.
  final provider = OpenAIProvider(
    transport: transport,
    apiKey: 'handled-by-transport-or-token',
    baseUrl: 'https://your.api/v1',
  );

  final forms = FormBridge();

  final session = ChatSession(
    provider,
    // No `tools:` — the request carries no schemas, the backend injects them.
    maxToolRounds: 8,
    dispatcher: (call) async {
      // Frontend tool → pause the loop on a form, resume when the user submits.
      if (frontendTools.contains(call.name)) {
        return forms.collect(call);
      }
      // Backend MCP tool → blind-forward; the frontend never needs its schema.
      final result = await backendExecute(call);
      return ToolResult(
        toolCallId: call.id,
        name: call.name,
        content: result,
        isError: false,
      );
    },
  );

  // UI side: render a form whenever the model requests one.
  forms.requests.listen((req) {
    // showFormSheet(req): build inputs from req.arguments, then on save call
    //   req.submit({'name': '...', 'phone': '...'});
    // or on dismiss:
    //   req.cancel();
  });

  return session;
}

/// Stand-in for the real call to your backend's /tool/execute endpoint.
Future<String> backendExecute(ToolCall call) async {
  // final resp = await dio.post('/tool/execute', data: {
  //   'id': call.id, 'name': call.name, 'arguments': call.arguments,
  // });
  // return resp.data['content'] as String;
  return '{"ok": true}';
}

/// Drive one user turn and react to the streamed lifecycle events.
Future<void> runTurn(ChatSession session, String userText) async {
  await for (final ev in session.send(userText)) {
    switch (ev) {
      case SessionText(:final delta):
        // append visible assistant text
        break;
      case SessionReasoning(:final delta):
        // append to a "thinking" panel
        break;
      case SessionToolCallStarted(:final name):
        // show a chip; style it differently if frontendTools.contains(name)
        break;
      case SessionToolCallExecuting(:final dispatched):
        // dispatched == true → backend or form is running
        break;
      case SessionToolCallEnd(:final result, :final isError):
        // resolve the chip
        break;
      case SessionTitleGenerated(:final title):
        // update conversation title
        break;
      case SessionDone(:final reason):
        // reason == maxRoundsReached means the loop was cut off
        break;
      case SessionError(:final error):
        // surface the failure
        break;
      default:
        break;
    }
  }
}

/// History now lives on the frontend — persist and restore it via JSON.
String saveHistory(ChatSession session) => jsonEncode(session.messages.map((m) => m.toJson()).toList());

void loadHistory(ChatSession session, String json) {
  final list = (jsonDecode(json) as List).cast<Map<String, dynamic>>();
  session.importHistory(list.map(Message.fromJson).toList());
  // Then call session.resume() if the history ends on a tool result and you
  // want the model to keep going.
}
