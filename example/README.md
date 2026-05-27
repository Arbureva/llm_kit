# llm_kit 测试页面

一个能直接跑的 Flutter 聊天页面，用来测试 llm_kit。

## 怎么跑

1. 确保装了 Flutter（建议 3.27 以上）。命令行检查：

   ```bash
   flutter --version
   ```

2. 进到这个 example 目录，拉依赖：

   ```bash
   cd example
   flutter pub get
   ```

3. 跑起来（手机、模拟器、或者直接 Chrome 都行）：

   ```bash
   flutter run
   ```

   想直接用浏览器跑：`flutter run -d chrome`

## 怎么用

- 打开后点开顶部的「设置」，选厂商（OpenAI 兼容 / Anthropic），填 **API Key**、**Base URL**、**模型名**。
- 直接发消息就能聊。
- 想看**工具调用**的效果，问一句：`东京天气怎么样？`
  会看到底部冒出「正在调用：get_weather…」转圈，1 秒后变成「已完成」。
  （天气是假数据，代码在 `lib/demo_tools.dart`，真实项目把里面换成你的网络请求即可。）
- 想看**思考过程**，打开设置里的「开启深度思考」开关，并用一个会思考的模型
  （比如 OpenAI 兼容填 DeepSeek-R1、或 gpt-5；Anthropic 用 Claude 思考版）。
  思考内容会以灰色「思考过程」折叠显示，点一下展开。

## 几个常见配置例子

OpenAI 官方：
- Base URL：`https://api.openai.com/v1`
- 模型：`gpt-4o-mini` 或 `gpt-5.1`

DeepSeek：
- Base URL：`https://api.deepseek.com/v1`
- 模型：`deepseek-chat` 或 `deepseek-reasoner`

本地 Ollama（OpenAI 兼容模式）：
- Base URL：`http://localhost:11434/v1`
- 模型：你本地拉的模型名，比如 `qwen2.5`
- Key 随便填（本地通常不校验）

Anthropic：
- Base URL：`https://api.anthropic.com/v1`
- 模型：`claude-opus-4-7`

## 换成你带 cookie 的 Dio

页面默认用自带的 `HttpTransport`。要换成 Dio，只改 `lib/settings.dart`
里 `buildProvider()` 那一行：

```dart
// 改之前
final transport = HttpTransport();
// 改之后（DioTransport 的完整代码在项目根目录 README.md 里）
final transport = DioTransport(yourConfiguredDio);
```

页面其它代码一个字都不用动。

## 注意（网页端 CORS）

如果你用 `flutter run -d chrome` 直接连各家官方接口，浏览器的 CORS 限制
可能会拦请求——这是浏览器的限制，不是这个库的问题。真机 / 模拟器 / 桌面端
不受影响。开发期想绕开，可以连你自己的中转服务，或用桌面端跑。
