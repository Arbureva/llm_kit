import 'dart:async';
import 'dart:convert';

/// One decoded Server-Sent Event.
class SseEvent {
  const SseEvent({required this.event, required this.data});

  /// The `event:` field, or 'message' if the stream omitted it (SSE default).
  final String event;

  /// The accumulated `data:` payload (multiple data lines joined by '\n').
  final String data;
}

/// Decodes a raw byte stream into [SseEvent]s.
///
/// This lives above [LlmTransport] on purpose: transports only move bytes, so
/// every provider shares one correct SSE implementation instead of each
/// re-deriving the framing rules (and getting multi-line `data:` wrong, as the
/// old line-splitter did).
Stream<SseEvent> decodeSse(Stream<List<int>> byteStream) {
  return byteStream
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .transform(_SseTransformer());
}

class _SseTransformer extends StreamTransformerBase<String, SseEvent> {
  @override
  Stream<SseEvent> bind(Stream<String> stream) {
    final controller = StreamController<SseEvent>();
    String eventName = 'message';
    final dataLines = <String>[];

    void dispatch() {
      if (dataLines.isEmpty) {
        eventName = 'message';
        return;
      }
      controller.add(SseEvent(event: eventName, data: dataLines.join('\n')));
      eventName = 'message';
      dataLines.clear();
    }

    stream.listen(
      (line) {
        // Blank line terminates an event.
        if (line.isEmpty) {
          dispatch();
          return;
        }
        // Comment line per SSE spec.
        if (line.startsWith(':')) return;

        final colon = line.indexOf(':');
        final field = colon == -1 ? line : line.substring(0, colon);
        var value = colon == -1 ? '' : line.substring(colon + 1);
        if (value.startsWith(' ')) value = value.substring(1);

        switch (field) {
          case 'event':
            eventName = value;
          case 'data':
            dataLines.add(value);
          // 'id' and 'retry' are ignored; not needed for LLM streams.
        }
      },
      onError: controller.addError,
      onDone: () {
        dispatch(); // flush any trailing event with no blank line after it
        controller.close();
      },
      cancelOnError: false,
    );

    return controller.stream;
  }
}
