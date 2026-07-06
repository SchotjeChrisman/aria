/// Thrown when libmpv cannot be loaded or a handle cannot be created.
/// The app must survive this: AriaPlayer catches it and reports
/// `isAvailable == false` instead of crashing.
class PlayerUnavailableException implements Exception {
  PlayerUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'PlayerUnavailableException: $message';
}

/// One decoded mpv event. All pointer decoding happens in the FFI layer so
/// the facade — and every unit test — never touches dart:ffi.
class MpvEventData {
  const MpvEventData(
    this.eventId, {
    this.replyUserdata = 0,
    this.propertyName,
    this.propertyValue,
    this.endFileReason,
    this.logPrefix,
    this.logText,
  });

  final int eventId;
  final int replyUserdata;

  /// Set for MPV_EVENT_PROPERTY_CHANGE.
  final String? propertyName;

  /// double | int | bool | String | null, per the observed format.
  final Object? propertyValue;

  /// Set for MPV_EVENT_END_FILE (an MpvEndFileReason value).
  final int? endFileReason;

  /// Set for MPV_EVENT_LOG_MESSAGE, e.g. prefix "ao/pipewire".
  final String? logPrefix;
  final String? logText;
}

/// Minimal seam over the raw libmpv C API. The real implementation is
/// [FfiMpvRaw]; tests inject fakes. Handles are passed as raw addresses so
/// this interface stays dart:ffi-free.
abstract class MpvRaw {
  /// mpv_create — returns the handle address, 0 on failure.
  int create();

  /// mpv_initialize — mpv error code (0 == success, negative == failure).
  int initialize(int handle);

  /// mpv_set_option_string — must be called before [initialize].
  int setOptionString(int handle, String name, String value);

  /// mpv_set_property (MPV_FORMAT_STRING).
  int setPropertyString(int handle, String name, String value);

  /// mpv_set_property (MPV_FORMAT_DOUBLE).
  int setPropertyDouble(int handle, String name, double value);

  /// mpv_command with a null-terminated string array.
  int command(int handle, List<String> args);

  /// mpv_observe_property.
  int observeProperty(int handle, int replyUserdata, String name, int format);

  /// mpv_request_log_messages — minLevel per client.h ("error", "warn", ...).
  int requestLogMessages(int handle, String minLevel);

  /// mpv_wait_event — non-blocking when timeoutSeconds is 0. Returns null
  /// when the event queue is empty (MPV_EVENT_NONE).
  MpvEventData? waitEvent(int handle, double timeoutSeconds);

  /// mpv_terminate_destroy.
  void terminateDestroy(int handle);
}
