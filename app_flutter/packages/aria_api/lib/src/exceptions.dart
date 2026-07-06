class AriaApiException implements Exception {
  AriaApiException(this.statusCode, this.message, {this.path});

  final int statusCode;
  final String message;
  final String? path;

  @override
  String toString() =>
      'AriaApiException($statusCode${path == null ? '' : ' $path'}): $message';
}
