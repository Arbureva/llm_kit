import 'package:flutter/material.dart';
import 'package:llm_kit/llm_kit.dart';

import 'demo_tools.dart';
import 'settings.dart';

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
}

/// 工具调用的生命周期阶段，和库里的 SessionEvent 一一对应。
enum UiToolPhase {
  /// 模型刚开始请求（SessionToolCallStarted）—— 参数可能还没传完。
  requesting,

  /// 参数已传完、正在执行（SessionToolCallExecuting）—— 后端跑工具的「空档期」就在这里。
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
  bool _busy = false;

  // 是否展开思考面板（每条助手消息一个开关，简单起见用 index 记）。
  final Set<int> _expandedReasoning = {};

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 把当前配置应用上：新建一个 session（带上示例工具）。
  void _rebuildSession() {
    final provider = _settings.buildProvider();
    _session = ChatSession(
      provider,
      // tools: [weatherTool],
      // 没有本地 execute 的工具会走到这里 —— 你的后端（MCP / CLI / skills）在此执行。
      // 示例工具 weatherTool 自带 execute，所以不会用到这个；
      // 接后端时把下面替换成真正的调用即可。
      dispatcher: _dispatchTool,
    );
    _session!.setSystem('你是一个简洁友好的中文助手。');
  }

  /// 后端工具派发：AI 请求一个没有本地 execute 的工具时被调用。
  /// 在这里调用你的后端（MCP / CLI / skills），拿到结果后返回 ToolResult，
  /// session 会自动把结果喂回模型并继续这一轮。
  Future<ToolResult> _dispatchTool(ToolCall call) async {
    // TODO: 换成你真正的后端调用，例如：
    //   final out = await backend.runTool(call.name, call.arguments);
    //   return ToolResult(toolCallId: call.id, name: call.name, content: out);
    return ToolResult(
      toolCallId: call.id,
      name: call.name,
      content: '（占位）后端尚未接入，工具 "${call.name}" 未执行。',
      isError: true,
    );
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
          case SessionText(:final delta):
            setState(() => assistant.text += delta);
            _scrollToBottom();

          case SessionReasoning(:final delta):
            setState(() => assistant.reasoning += delta);

          case SessionToolCallStarted(:final id, :final name):
            // 模型一开始请求工具就冒出标签（此时参数可能还没传完）。
            setState(() => _activeTools.add(UiToolCall(id: id, name: name)));
            _scrollToBottom();

          case SessionToolCallReady():
            // 参数已传完并解析好。这里不强制做 UI，
            // 如果想显示「将用什么参数调用」，可以读 ev.parsedArguments。
            break;

          case SessionToolCallExecuting(:final id, :final name, :final dispatched):
            // 真正开始执行（本地或交给后端）—— 之前的「空档期」就发生在这一阶段。
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
    final t = UiToolCall(id: id, name: name);
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
            '想看工具调用效果，可以问："东京天气怎么样？"',
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
        avatar = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
        // 区分本地执行 / 后端执行，让「空档期」有明确说明。
        label = t.dispatched ? '后端执行中：${t.name}…' : '执行中：${t.name}…';
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
