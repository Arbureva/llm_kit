import 'dart:async';
import 'dart:convert';

import '../core/message.dart';

/// A request for the UI to collect data from the user, raised when the model
/// calls a *frontend* tool (a form, a picker, a confirmation) that only the
/// client can fulfil interactively.
///
/// You don't construct this yourself — [FormBridge.collect] emits one. Your UI
/// listens, renders the form, then calls [submit] or [cancel]. The session's
/// dispatcher is `await`ing [future] the whole time, so the tool loop simply
/// pauses here until the user responds, then resumes. No suspend/resume
/// machinery, no timeout pressure.
class FormRequest {
  FormRequest({
    required this.id,
    required this.name,
    required this.arguments,
  });

  /// The originating tool call id (becomes the tool_result's id).
  final String id;

  /// The frontend tool name (e.g. 'collect_user_info').
  final String name;

  /// Decoded tool arguments — what the model asked you to collect, or seed
  /// values it passed. Empty map if the call carried no arguments or invalid
  /// JSON.
  final Map<String, dynamic> arguments;

  final _completer = Completer<ToolResult>();

  /// Completes when the UI resolves this request. The dispatcher returns it.
  Future<ToolResult> get future => _completer.future;

  bool get isResolved => _completer.isCompleted;

  /// Call when the user submits the form. [values] is JSON-encoded and handed
  /// back to the model as the tool result, continuing the loop.
  void submit(Map<String, dynamic> values) {
    if (_completer.isCompleted) return;
    _completer.complete(ToolResult(
      toolCallId: id,
      name: name,
      content: jsonEncode(values),
      isError: false,
    ));
  }

  /// Call when the user dismisses or cancels. The model is told the user
  /// declined so the conversation can recover instead of stalling. Marked as
  /// an error result so the model treats it as "didn't get the data".
  void cancel([String reason = 'User cancelled the form.']) {
    if (_completer.isCompleted) return;
    _completer.complete(ToolResult(
      toolCallId: id,
      name: name,
      content: reason,
      isError: true,
    ));
  }
}

/// Bridges a [ChatSession]'s tool loop and your UI for the tools the *client*
/// executes by asking the user — forms, date pickers, confirmations.
///
/// This is the seam that makes "AI sends a form to the frontend" work without
/// touching the session or the providers: a backend-registered tool's schema
/// reaches the model, the model emits a call, the dispatcher routes the
/// frontend ones here, and [collect] hands your UI a [FormRequest] while
/// pausing the loop on its future.
///
/// Wiring:
///
/// ```dart
/// final forms = FormBridge();
/// const frontendTools = {'collect_user_info', 'pick_date'};
///
/// final session = ChatSession(
///   provider,                 // transport pointed at your backend proxy
///   dispatcher: (call) async {
///     if (frontendTools.contains(call.name)) {
///       return forms.collect(call);            // pauses until the user submits
///     }
///     final r = await backend.executeTool(call); // backend MCP tool
///     return ToolResult(
///       toolCallId: call.id, name: call.name,
///       content: r.content, isError: r.isError,
///     );
///   },
/// );
///
/// // In your widget tree:
/// forms.requests.listen((req) => showFormSheet(req)); // call req.submit(...) on save
/// ```
class FormBridge {
  final _controller = StreamController<FormRequest>.broadcast();

  /// Emits a [FormRequest] each time the dispatcher routes a frontend tool
  /// here. Listen from your UI layer and render the form.
  Stream<FormRequest> get requests => _controller.stream;

  /// Call from the dispatcher for a frontend tool. Returns a future that
  /// completes once the matching [FormRequest] is resolved by the UI.
  Future<ToolResult> collect(ToolCall call) {
    Map<String, dynamic> args;
    try {
      args = call.arguments.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(call.arguments) as Map<String, dynamic>;
    } catch (_) {
      args = <String, dynamic>{};
    }
    final req = FormRequest(id: call.id, name: call.name, arguments: args);
    _controller.add(req);
    return req.future;
  }

  void dispose() => _controller.close();
}
