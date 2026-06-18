import 'package:flutter/material.dart';
import 'package:llm_kit/llm_kit.dart';

import 'settings.dart';

/// 前端（表单）工具的名字集合。它们的 schema 在本文件里声明并随请求发给模型，
/// 但**没有本地 execute**——执行靠 dispatcher 路由到 FormBridge，弹表单收集用户输入。
/// 接真实后端时，这些 schema 应改由后端注入；前端只需保留这份名字集合用于路由。
const _frontendToolNames = {'collect_contact_info', 'pick_date'};

/// 前端表单工具的 schema。
///
/// 注意：在你的真实架构里，**所有工具的 schema 由后端在它的 /chat 端点注入**，
/// 前端发请求时不该再带 tools——前端只需保留上面那份 `_frontendToolNames`
/// 用于在 dispatcher 里认出哪些 tool_call 要弹表单。
///
/// 但这个 demo 是直连 LLM（没有你的后端代理），模型不会凭空知道这些表单工具，
/// 所以这里在前端声明一遍 schema 以便演示。接上后端后，删掉 `tools:` 传参、
/// 把这些 schema 挪到后端注入即可。
///
/// 这些工具都不带 execute —— 所以执行会走 dispatcher，由 FormBridge 弹表单。
final List<Tool> _formTools = [
  Tool(
    name: 'collect_contact_info',
    description: '当需要用户提供联系资料（如姓名、电话、邮箱）以继续任务时调用。'
        '会弹出一个表单让用户填写，填完后返回这些信息。',
    parameters: {
      'type': 'object',
      'properties': {
        'fields': {
          'type': 'array',
          'description': '需要收集的字段列表',
          'items': {
            'type': 'object',
            'properties': {
              'key': {'type': 'string', 'description': '字段标识，如 name / phone / email'},
              'label': {'type': 'string', 'description': '显示给用户的中文标签'},
              'required': {'type': 'boolean', 'description': '是否必填'},
            },
            'required': ['key', 'label'],
          },
        },
        'reason': {'type': 'string', 'description': '向用户说明为什么需要这些资料'},
      },
      'required': ['fields'],
    },
  ),
  Tool(
    name: 'pick_date',
    description: '当需要用户选择一个日期时调用，会弹出日期选择表单。',
    parameters: {
      'type': 'object',
      'properties': {
        'label': {'type': 'string', 'description': '让用户选什么日期，如「预约日期」'},
      },
    },
  ),
];

/// 一条要显示在屏幕上的内容。我们不直接用库里的 Message，
/// 而是用这个更适合「显示」的结构（带流式状态、思考内容、工具状态）。
class UiBubble {
  UiBubble({
    required this.role,
    this.text = '',
    this.reasoning = '',
    this.streaming = false,
  });

  final Role role; // user / assistant
  String text; // 正常回复文字
  String reasoning; // 思考过程文字
  bool streaming; // 是否正在打字中
}

/// 工具调用的一次记录（用来显示那个「正在调用…/执行中/完成」的小标签）。
class UiToolCall {
  UiToolCall({required this.id, required this.name});
  final String id;
  String name;

  /// 工具当前所处的阶段，驱动小标签的图标和文字。
  UiToolPhase phase = UiToolPhase.requesting;
  bool isError = false;

  /// 是否是交给后端（dispatcher）执行的。本地执行的工具为 false。
  bool dispatched = false;

  /// 是否是前端表单工具（用来给标签换个「等用户填表」的措辞和图标）。
  bool isForm = false;
}

/// 工具调用的生命周期阶段，和库里的 SessionEvent 一一对应。
enum UiToolPhase {
  /// 模型刚开始请求（SessionToolCallStarted）—— 参数可能还没传完。
  requesting,

  /// 参数已传完、正在执行（SessionToolCallExecuting）—— 后端跑工具、或等用户填表的「空档期」就在这里。
  executing,

  /// 执行完成（SessionToolCallEnd）。
  done,
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _settings = Settings();
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  // 显示用的气泡列表，和「这一轮的工具调用」列表。
  final List<UiBubble> _bubbles = [];
  final List<UiToolCall> _activeTools = [];

  ChatSession? _session;

  /// 前端表单桥：dispatcher 把前端工具交给它，它通过 requests 流把表单请求送到 UI。
  FormBridge? _forms;

  bool _busy = false;

  // 是否展开思考面板（每条助手消息一个开关，简单起见用 index 记）。
  final Set<int> _expandedReasoning = {};

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _forms?.dispose();
    super.dispose();
  }

  /// 把当前配置应用上：新建一个 session（带上表单工具 + 表单桥 + dispatcher）。
  void _rebuildSession() {
    final provider = _settings.buildProvider();

    // 旧的表单桥先关掉，避免泄漏 StreamController。
    _forms?.dispose();
    final forms = FormBridge();
    _forms = forms;

    _session = ChatSession(
      provider,
      // 把前端表单工具的 schema 交给模型；它们没有 execute，所以执行会走 dispatcher。
      // 接真实后端时，把后端工具 schema 也一起注入（通常由后端代理 /chat 端点完成）。
      tools: _formTools,
      dispatcher: (call) => _dispatchTool(call, forms),
    );
    _session!.setSystem(
      '你是一个简洁友好的中文助手。当任务需要用户提供资料时，'
      '请调用 collect_contact_info 收集联系方式，或调用 pick_date 让用户选日期，'
      '不要自己编造用户的资料。',
    );

    // 监听表单请求：模型一旦调用前端工具，这里就会收到一个 FormRequest，弹出表单。
    forms.requests.listen(_onFormRequested);
  }

  /// 工具派发：按工具名分流。
  ///   - 前端表单工具 → 交给 FormBridge，弹表单、挂起循环、等用户提交。
  ///   - 其余（后端工具）→ 返回 null「跳过」：这个 tool_call 原样留在 assistant 轮里、
  ///     不回填任何结果。本次 send 会以 handedOffToBackend 结束；
  ///     你把当前 messages 再发一次给后端时，后端发现末尾的 tool_call 还没结果，
  ///     就自己执行、把结果拼回去、再发起 AI 请求。前端全程不碰这个工具。
  Future<ToolResult?> _dispatchTool(ToolCall call, FormBridge forms) async {
    if (_frontendToolNames.contains(call.name)) {
      // collect() 返回的 Future 会一直挂着，直到用户在表单上提交或取消。
      // 循环就停在这一步，不需要任何额外的暂停/恢复机制。
      return forms.collect(call);
    }
    // 后端工具：不归前端管，跳过。
    return null;
  }

  /// 收到表单请求时弹出底部表单。用户提交→req.submit(values)，取消→req.cancel()。
  Future<void> _onFormRequested(FormRequest req) async {
    if (!mounted) {
      req.cancel('页面已关闭。');
      return;
    }

    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      // 用户点空白关闭时返回 null，下面按取消处理。
      builder: (ctx) => _FormSheet(request: req),
    );

    if (req.isResolved) return; // 已在表单内部 submit/cancel 过

    if (result == null) {
      req.cancel('用户关闭了表单。');
    } else {
      req.submit(result);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _busy) return;

    if (_settings.apiKey.isEmpty) {
      _showSnack('请先在顶部填写 API Key');
      return;
    }

    // 第一次发消息、或改过配置时，重建 session（这样新配置能生效）。
    if (_session == null) _rebuildSession();

    _inputCtrl.clear();
    setState(() {
      _busy = true;
      _activeTools.clear();
      _bubbles.add(UiBubble(role: Role.user, text: text));
    });
    _scrollToBottom();

    // 给这一轮新建一个「助手」气泡，流式往里填。
    final assistant = UiBubble(role: Role.assistant, streaming: true);
    setState(() => _bubbles.add(assistant));
    _scrollToBottom();

    final options = ChatOptions(
      model: _settings.model,
      reasoningEffort: _settings.enableThinking ? ReasoningEffort.medium : null,
    );

    try {
      await for (final ev in _session!.send(text, options: options)) {
        // 这里就是「靠事件驱动界面」的核心：根据事件类型更新 UI。
        switch (ev) {
          case SessionTitleGenerated(:final title):
            _session?.title = title;
          case SessionText(:final delta):
            setState(() => assistant.text += delta);
            _scrollToBottom();

          case SessionReasoning(:final delta):
            setState(() => assistant.reasoning += delta);

          case SessionToolCallStarted(:final id, :final name):
            // 模型一开始请求工具就冒出标签（此时参数可能还没传完）。
            setState(() {
              final t = UiToolCall(id: id, name: name)..isForm = _frontendToolNames.contains(name);
              _activeTools.add(t);
            });
            _scrollToBottom();

          case SessionToolCallReady():
            // 参数已传完并解析好。这里不强制做 UI，
            // 如果想显示「将用什么参数调用」，可以读 ev.parsedArguments。
            break;

          case SessionToolCallExecuting(:final id, :final name, :final dispatched):
            // 真正开始执行（本地 / 后端 / 等用户填表）—— 之前的「空档期」就在这一阶段。
            setState(() {
              final t = _findOrAddTool(id, name);
              t.phase = UiToolPhase.executing;
              t.dispatched = dispatched;
            });
            _scrollToBottom();

          case SessionToolCallEnd(:final id, :final name, :final isError):
            setState(() {
              final t = _findOrAddTool(id, name);
              t.phase = UiToolPhase.done;
              t.isError = isError;
            });

          case SessionDone(:final reason):
            // 轮次用尽（而非正常结束）时给个提示，避免回复像是无故截断。
            if (reason == SessionStopReason.maxRoundsReached) {
              setState(() => assistant.text += '\n\n⚠️ 工具调用轮次已达上限，回复可能未完成。');
            } else if (reason == SessionStopReason.handedOffToBackend) {
              // 模型调了后端工具：当前 messages 里留着没结果的 tool_call。
              // 真实接入时，这里应把 _session!.messages 再发一次给后端，
              // 后端执行该工具、回填结果后，再用 _session!.resume() 续跑这一轮。
              // 本地直连 LLM 的 demo 没有后端，所以只做个提示。
              // setState(() => assistant.text += '\n\n🔁 模型请求了后端工具，已交给后端处理（demo 未接后端，'
              //     '真实环境请重发 messages 给后端并 resume）。');
            }

          case SessionError(:final error):
            setState(() => assistant.text += '\n\n⚠️ 出错了：$error\n（检查 Key / Base URL / 模型名是否正确，以及网络是否能访问该地址）');
        }
      }
    } catch (e) {
      // 兜底：理论上传输错误已由 SessionError 事件覆盖，这里防御未预期的异常。
      setState(() => assistant.text += '\n\n⚠️ 出错了：$e');
    } finally {
      setState(() {
        assistant.streaming = false;
        _busy = false;
      });
      _scrollToBottom();
    }
  }

  /// 按 id 找已有的工具记录，找不到就新建一条（防御事件乱序 / 漏掉 Started）。
  UiToolCall _findOrAddTool(String id, String name) {
    for (final t in _activeTools) {
      if (t.id == id) {
        t.name = name;
        return t;
      }
    }
    final t = UiToolCall(id: id, name: name)..isForm = _frontendToolNames.contains(name);
    _activeTools.add(t);
    return t;
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _clear() {
    setState(() {
      _bubbles.clear();
      _activeTools.clear();
      _expandedReasoning.clear();
    });
    _session?.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('llm_kit 测试'),
        actions: [
          IconButton(
            tooltip: '清空对话',
            onPressed: _busy ? null : _clear,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
        children: [
          _SettingsBar(
            settings: _settings,
            enabled: !_busy,
            onChanged: () => setState(() {
              // 配置变了，强制下次发消息时重建 session。
              _session = null;
            }),
          ),
          const Divider(height: 1),
          Expanded(child: _buildMessageList()),
          if (_busy && _activeTools.isNotEmpty) _buildToolStrip(),
          const Divider(height: 1),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    if (_bubbles.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            '在顶部填好 Key 和模型，然后发条消息试试。\n'
            '想看工具调用效果，可以问："东京天气怎么样？"\n'
            '想看表单效果，可以说："帮我预约，需要我的联系方式"',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.all(12),
      itemCount: _bubbles.length,
      itemBuilder: (context, i) => _buildBubble(i, _bubbles[i]),
    );
  }

  Widget _buildBubble(int index, UiBubble b) {
    final isUser = b.role == Role.user;
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final color = isUser ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.surfaceContainerHighest;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: align,
        children: [
          // 思考面板（有思考内容才显示）。
          if (!isUser && b.reasoning.isNotEmpty) _buildReasoning(index, b.reasoning),
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(14),
            ),
            child: SelectableText(
              b.text.isEmpty && b.streaming ? '…' : b.text,
              style: const TextStyle(fontSize: 15, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReasoning(int index, String reasoning) {
    final expanded = _expandedReasoning.contains(index);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.78,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() {
              if (expanded) {
                _expandedReasoning.remove(index);
              } else {
                _expandedReasoning.add(index);
              }
            }),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: Colors.black45,
                ),
                const Text(
                  '思考过程',
                  style: TextStyle(fontSize: 13, color: Colors.black45),
                ),
              ],
            ),
          ),
          if (expanded)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                reasoning,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: Colors.black54,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 底部那条「正在调用工具」的横幅。
  Widget _buildToolStrip() {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: _activeTools.map(_buildToolChip).toList(),
      ),
    );
  }

  Widget _buildToolChip(UiToolCall t) {
    // 根据阶段决定图标和文字。
    final Widget avatar;
    final String label;
    switch (t.phase) {
      case UiToolPhase.requesting:
        avatar = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
        label = '请求调用：${t.name}…';
      case UiToolPhase.executing:
        if (t.isForm) {
          // 等用户填表：用一个明确的「待填写」图标，而不是转圈。
          avatar = const Icon(Icons.edit_note, size: 18, color: Colors.indigo);
          label = '请填写表单：${t.name}…';
        } else {
          avatar = const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
          // 区分本地执行 / 后端执行，让「空档期」有明确说明。
          label = t.dispatched ? '后端执行中：${t.name}…' : '执行中：${t.name}…';
        }
      case UiToolPhase.done:
        avatar = Icon(
          t.isError ? Icons.error_outline : Icons.check_circle,
          size: 18,
          color: t.isError ? Colors.red : Colors.green,
        );
        label = t.isError ? '失败：${t.name}' : '已完成：${t.name}';
    }

    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: avatar,
      label: Text(label, style: const TextStyle(fontSize: 13)),
    );
  }

  Widget _buildInputBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputCtrl,
                enabled: !_busy,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: '输入消息…',
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _busy
                ? const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                : IconButton.filled(
                    onPressed: _send,
                    icon: const Icon(Icons.arrow_upward),
                  ),
          ],
        ),
      ),
    );
  }
}

/// 表单底部弹窗：根据工具的参数动态生成输入项。
///
/// - collect_contact_info：按 arguments['fields'] 渲染若干文本框。
/// - pick_date：渲染一个日期选择按钮。
/// - 其它前端工具：兜底渲染一个「补充说明」文本框，避免无法继续。
///
/// 提交时把收集到的值组成 Map，由调用方 submit 回模型。
class _FormSheet extends StatefulWidget {
  const _FormSheet({required this.request});
  final FormRequest request;

  @override
  State<_FormSheet> createState() => _FormSheetState();
}

class _FormSheetState extends State<_FormSheet> {
  // 文本字段的控制器，key 与字段 key 一致。
  final Map<String, TextEditingController> _ctrls = {};
  // 哪些字段必填，用于校验。
  final Map<String, bool> _requiredFlags = {};
  // pick_date 选中的日期。
  DateTime? _pickedDate;

  @override
  void initState() {
    super.initState();
    if (widget.request.name == 'collect_contact_info') {
      for (final f in _fields) {
        final key = f['key'] as String;
        _ctrls[key] = TextEditingController();
        _requiredFlags[key] = (f['required'] as bool?) ?? false;
      }
    } else if (widget.request.name != 'pick_date') {
      // 兜底：未知前端工具，给一个自由文本框。
      _ctrls['value'] = TextEditingController();
      _requiredFlags['value'] = true;
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// collect_contact_info 的字段列表；模型没给就用一组默认。
  List<Map<String, dynamic>> get _fields {
    final raw = widget.request.arguments['fields'];
    if (raw is List && raw.isNotEmpty) {
      return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    return const [
      {'key': 'name', 'label': '姓名', 'required': true},
      {'key': 'phone', 'label': '电话', 'required': true},
      {'key': 'email', 'label': '邮箱', 'required': false},
    ];
  }

  String get _title {
    switch (widget.request.name) {
      case 'collect_contact_info':
        return '请填写联系资料';
      case 'pick_date':
        final label = widget.request.arguments['label'];
        return label is String && label.isNotEmpty ? label : '请选择日期';
      default:
        return '请补充信息';
    }
  }

  String? get _reason {
    final r = widget.request.arguments['reason'];
    return r is String && r.isNotEmpty ? r : null;
  }

  void _submit() {
    final name = widget.request.name;

    if (name == 'pick_date') {
      if (_pickedDate == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先选择一个日期')),
        );
        return;
      }
      final iso = _pickedDate!.toIso8601String().split('T').first;
      widget.request.submit({'date': iso});
      Navigator.of(context).pop({'date': iso}); // 关闭弹窗（pop 的值仅作冗余）
      return;
    }

    // 文本字段：校验必填。
    final values = <String, dynamic>{};
    for (final entry in _ctrls.entries) {
      final v = entry.value.text.trim();
      if ((_requiredFlags[entry.key] ?? false) && v.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「${_labelOf(entry.key)}」为必填项')),
        );
        return;
      }
      values[entry.key] = v;
    }
    widget.request.submit(values);
    Navigator.of(context).pop(values);
  }

  void _cancel() {
    widget.request.cancel();
    Navigator.of(context).pop(); // 返回 null
  }

  String _labelOf(String key) {
    if (widget.request.name == 'collect_contact_info') {
      for (final f in _fields) {
        if (f['key'] == key) return (f['label'] as String?) ?? key;
      }
    }
    return key;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _pickedDate ?? now,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 3)),
    );
    if (d != null) setState(() => _pickedDate = d);
  }

  @override
  Widget build(BuildContext context) {
    // 让弹窗在键盘弹出时往上顶，避免输入框被遮住。
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: 16 + bottomInset,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.assignment_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                onPressed: _cancel,
                icon: const Icon(Icons.close),
                tooltip: '取消',
              ),
            ],
          ),
          if (_reason != null) ...[
            const SizedBox(height: 4),
            Text(
              _reason!,
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ],
          const SizedBox(height: 12),
          ..._buildInputs(),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _cancel,
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _submit,
                  child: const Text('提交'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _buildInputs() {
    if (widget.request.name == 'pick_date') {
      return [
        InkWell(
          onTap: _pickDate,
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: '日期',
              isDense: true,
              border: OutlineInputBorder(),
              suffixIcon: Icon(Icons.calendar_today, size: 18),
            ),
            child: Text(
              _pickedDate == null ? '点击选择' : _pickedDate!.toIso8601String().split('T').first,
              style: TextStyle(
                color: _pickedDate == null ? Colors.black45 : Colors.black87,
              ),
            ),
          ),
        ),
      ];
    }

    // collect_contact_info / 兜底：文本框列表。
    return _ctrls.entries.map((e) {
      final required = _requiredFlags[e.key] ?? false;
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: e.value,
          decoration: InputDecoration(
            labelText: _labelOf(e.key) + (required ? ' *' : ''),
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
      );
    }).toList();
  }
}

/// 顶部配置栏。
class _SettingsBar extends StatefulWidget {
  const _SettingsBar({
    required this.settings,
    required this.enabled,
    required this.onChanged,
  });

  final Settings settings;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  State<_SettingsBar> createState() => _SettingsBarState();
}

class _SettingsBarState extends State<_SettingsBar> {
  late final TextEditingController _keyCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _modelCtrl;

  @override
  void initState() {
    super.initState();
    _keyCtrl = TextEditingController(text: widget.settings.apiKey);
    _urlCtrl = TextEditingController(text: widget.settings.baseUrl);
    _modelCtrl = TextEditingController(text: widget.settings.model);
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final enabled = widget.enabled;
    return ExpansionTile(
      title: Text(
        '设置 · ${settings.kind == ProviderKind.openai ? "OpenAI 兼容" : "Anthropic"} · ${settings.model}',
        style: const TextStyle(fontSize: 14),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        Row(
          children: [
            const Text('厂商：'),
            const SizedBox(width: 8),
            SegmentedButton<ProviderKind>(
              segments: const [
                ButtonSegment(
                  value: ProviderKind.openai,
                  label: Text('OpenAI 兼容'),
                ),
                ButtonSegment(
                  value: ProviderKind.anthropic,
                  label: Text('Anthropic'),
                ),
              ],
              selected: {settings.kind},
              onSelectionChanged: enabled
                  ? (s) {
                      settings.kind = s.first;
                      settings.applyDefaultsForKind();
                      // 厂商切换后，地址和模型名也跟着变，同步到输入框。
                      _urlCtrl.text = settings.baseUrl;
                      _modelCtrl.text = settings.model;
                      widget.onChanged();
                    }
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          enabled: enabled,
          decoration: const InputDecoration(
            labelText: 'API Key',
            isDense: true,
          ),
          obscureText: true,
          controller: _keyCtrl,
          onChanged: (v) => settings.apiKey = v,
        ),
        const SizedBox(height: 8),
        TextField(
          enabled: enabled,
          decoration: const InputDecoration(
            labelText: 'Base URL',
            isDense: true,
          ),
          controller: _urlCtrl,
          onChanged: (v) => settings.baseUrl = v,
        ),
        const SizedBox(height: 8),
        TextField(
          enabled: enabled,
          decoration: const InputDecoration(
            labelText: '模型名',
            isDense: true,
          ),
          controller: _modelCtrl,
          onChanged: (v) => settings.model = v,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('开启深度思考', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            '只对会思考的模型有效（如 DeepSeek-R1 / gpt-5 / Claude 思考版）',
            style: TextStyle(fontSize: 12),
          ),
          value: settings.enableThinking,
          onChanged: enabled
              ? (v) {
                  settings.enableThinking = v;
                  widget.onChanged();
                }
              : null,
        ),
      ],
    );
  }
}
