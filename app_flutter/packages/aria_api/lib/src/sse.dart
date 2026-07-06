import 'dart:convert';

/// One server-sent event. `data` is the raw payload (multi-line data fields
/// joined with '\n' per the SSE spec); [json] decodes it when it is JSON.
class AriaEvent {
  const AriaEvent({this.event = 'message', required this.data, this.id});

  final String event; // e.g. scan, enrich
  final String data;
  final String? id;

  Object? get json {
    try {
      return jsonDecode(data);
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => 'AriaEvent($event: $data)';
}

/// Minimal text/event-stream parser over a byte stream (the body of an
/// `Accept: text/event-stream` HTTP response). Handles `event:`, `data:`,
/// `id:` and comment lines; `retry:` is ignored — reconnection is the
/// caller's concern.
Stream<AriaEvent> parseSse(Stream<List<int>> bytes) async* {
  var event = '';
  String? id;
  final data = StringBuffer();
  var hasData = false;

  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (hasData) {
        var payload = data.toString();
        if (payload.endsWith('\n')) {
          payload = payload.substring(0, payload.length - 1);
        }
        yield AriaEvent(
          event: event.isEmpty ? 'message' : event,
          data: payload,
          id: id,
        );
      }
      event = '';
      data.clear();
      hasData = false;
      continue;
    }
    if (line.startsWith(':')) continue; // comment / keep-alive

    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);

    switch (field) {
      case 'event':
        event = value;
      case 'data':
        data.write(value);
        data.write('\n');
        hasData = true;
      case 'id':
        id = value;
    }
  }
}
