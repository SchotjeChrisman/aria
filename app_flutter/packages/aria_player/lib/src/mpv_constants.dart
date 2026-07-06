/// mpv client API constants (client.h). Only the subset aria_player uses.
abstract final class MpvEventId {
  static const int none = 0;
  static const int shutdown = 1;
  static const int logMessage = 5;
  static const int startFile = 6;
  static const int endFile = 7;
  static const int fileLoaded = 8;
  static const int idle = 11;
  static const int audioReconfig = 18;
  static const int playbackRestart = 21;
  static const int propertyChange = 22;
}

abstract final class MpvFormat {
  static const int none = 0;
  static const int string = 1;
  static const int flag = 3;
  static const int int64 = 4;
  static const int doubleValue = 5;
}

abstract final class MpvEndFileReason {
  static const int eof = 0;
  static const int stop = 2;
  static const int quit = 3;
  static const int error = 4;
  static const int redirect = 5;
}
