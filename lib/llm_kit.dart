/// llm_kit — a small, transport-injectable LLM client for Flutter & Dart.
///
/// Layers, bottom to top:
///   transport/  — you inject your HTTP client (Dio, http, mock). Cookies live here.
///   core/       — neutral message + typed streaming-event model.
///   providers/  — thin protocol translators (OpenAI-compatible, Anthropic).
///   session/    — optional, framework-agnostic chat + tool-loop manager.
library;

// Transport (the injection seam)
export 'src/transport/transport.dart';
export 'src/transport/http_transport.dart';

// Core model
export 'src/core/message.dart';
export 'src/core/stream_event.dart';
export 'src/core/provider.dart';
export 'src/core/sse.dart' show SseEvent, decodeSse;

// Providers
export 'src/providers/openai/openai_provider.dart';
export 'src/providers/anthropic/anthropic_provider.dart';

// Optional session layer
export 'src/session/chat_session.dart';
