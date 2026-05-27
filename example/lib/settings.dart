import 'package:llm_kit/llm_kit.dart';

/// 当前选哪个厂商。
enum ProviderKind { openai, anthropic }

/// 页面顶部那一栏的配置，集中放这里，方便改。
class Settings {
  Settings({
    this.kind = ProviderKind.openai,
    this.apiKey = 'ak_live_4e0fda97d63f587c28435709ed8f9b94',
    this.baseUrl = 'https://api.iceres.cn:8186/v1',
    this.model = 'deepseek-v4-pro',
    this.enableThinking = true,
  });

  ProviderKind kind;
  String apiKey;
  String baseUrl;
  String model;

  /// 是否开启「深度思考」（只对会思考的模型有用）。
  bool enableThinking;

  /// 根据当前配置，造一个 provider 出来。
  ///
  /// 这里用的是自带的 HttpTransport。要换成你带 cookie 的 Dio，
  /// 只要把下面这行的 transport 换成 DioTransport(yourDio) 就行，
  /// 页面其它代码一个字都不用动。
  LlmProvider buildProvider() {
    final transport = HttpTransport();
    switch (kind) {
      case ProviderKind.openai:
        return OpenAIProvider(
          transport: transport,
          apiKey: apiKey,
          baseUrl: baseUrl,
          defaultModel: model,
        );
      case ProviderKind.anthropic:
        return AnthropicProvider(
          transport: transport,
          apiKey: apiKey,
          baseUrl: baseUrl,
          defaultModel: model,
        );
    }
  }

  /// 切换厂商时，给一套合理的默认地址和模型名。
  void applyDefaultsForKind() {
    switch (kind) {
      case ProviderKind.openai:
        baseUrl = 'https://api.openai.com/v1';
        model = 'gpt-4o-mini';
      case ProviderKind.anthropic:
        baseUrl = 'https://api.anthropic.com/v1';
        model = 'claude-opus-4-7';
    }
  }
}
