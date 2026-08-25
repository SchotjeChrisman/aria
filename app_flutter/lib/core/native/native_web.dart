import 'dart:convert';
import 'dart:typed_data';

/// Web half of the io seam — in-memory stand-ins for the `dart:io` types in
/// native_io.dart.
///
/// These are deliberately *coherent* rather than throwing: the download index
/// is written and read back, the log is appended and rotated, and the code
/// that does it is unchanged. Nothing survives a page reload, which is the
/// right lifetime for a component catalogue and no use at all for a real
/// music library — that is what the native build is for.

/// path -> contents. Directories are tracked separately so `create` and
/// `exists` behave, even though nothing here is hierarchical.
final Map<String, Uint8List> _files = {};
final Set<String> _dirs = {'/', '/tmp'};

int _tempCounter = 0;

String _dirname(String path) {
  final i = path.lastIndexOf('/');
  return i <= 0 ? '/' : path.substring(0, i);
}

Never _notFound(String path) =>
    throw FileSystemException('No such file or directory', path);

class FileSystemException implements Exception {
  FileSystemException(this.message, [this.path = '']);

  final String message;
  final String path;

  @override
  String toString() => 'FileSystemException: $message, path = \'$path\'';
}

abstract class FileSystemEntity {
  String get path;
}

class FileMode {
  const FileMode._(this.name);

  final String name;

  static const read = FileMode._('read');
  static const write = FileMode._('write');
  static const append = FileMode._('append');
  static const writeOnly = FileMode._('writeOnly');
  static const writeOnlyAppend = FileMode._('writeOnlyAppend');
}

class File implements FileSystemEntity {
  File(this.path);

  @override
  final String path;

  Directory get parent => Directory(_dirname(path));

  bool existsSync() => _files.containsKey(path);
  Future<bool> exists() async => existsSync();

  int lengthSync() => _files[path]?.length ?? _notFound(path);
  Future<int> length() async => lengthSync();

  Uint8List readAsBytesSync() => _files[path] ?? _notFound(path);
  Future<Uint8List> readAsBytes() async => readAsBytesSync();

  String readAsStringSync() => utf8.decode(readAsBytesSync());
  Future<String> readAsString() async => readAsStringSync();

  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
  }) async {
    final existing = mode == FileMode.append || mode == FileMode.writeOnlyAppend
        ? (_files[path] ?? Uint8List(0))
        : Uint8List(0);
    _files[path] = Uint8List.fromList([...existing, ...bytes]);
    _dirs.add(_dirname(path));
    return this;
  }

  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
  }) =>
      writeAsBytes(utf8.encode(contents), mode: mode);

  Future<File> create({bool recursive = false}) async {
    _files.putIfAbsent(path, () => Uint8List(0));
    _dirs.add(_dirname(path));
    return this;
  }

  Future<File> rename(String newPath) async {
    final bytes = _files.remove(path) ?? _notFound(path);
    _files[newPath] = bytes;
    return File(newPath);
  }

  Future<void> delete({bool recursive = false}) async => _files.remove(path);
  void deleteSync({bool recursive = false}) => _files.remove(path);

  IOSink openWrite({FileMode mode = FileMode.write}) => IOSink._(this, mode);

  Future<RandomAccessFile> open() async => RandomAccessFile._(this);
}

class Directory implements FileSystemEntity {
  Directory(this.path);

  @override
  final String path;

  static Directory get systemTemp => Directory('/tmp');

  bool existsSync() => _dirs.contains(path);
  Future<bool> exists() async => existsSync();

  Future<Directory> create({bool recursive = false}) async {
    _dirs.add(path);
    return this;
  }

  void createSync({bool recursive = false}) => _dirs.add(path);

  Future<Directory> createTemp([String prefix = '']) async {
    final d = Directory('$path/$prefix${_tempCounter++}');
    _dirs.add(d.path);
    return d;
  }

  Future<void> delete({bool recursive = false}) async {
    _dirs.remove(path);
    if (recursive) {
      _files.removeWhere((k, _) => k.startsWith('$path/'));
      _dirs.removeWhere((d) => d.startsWith('$path/'));
    }
  }
}

/// Buffers writes and commits on [close], which is all the app's one caller
/// (the download worker) needs.
class IOSink {
  IOSink._(this._file, this._mode);

  final File _file;
  final FileMode _mode;
  final List<int> _buffer = [];

  void add(List<int> data) => _buffer.addAll(data);
  void write(Object? obj) => _buffer.addAll(utf8.encode('$obj'));
  Future<void> flush() async {}

  Future<void> close() => _file.writeAsBytes(_buffer, mode: _mode);
}

/// Positioned reads, for the log uploader's cursor.
class RandomAccessFile {
  RandomAccessFile._(this._file);

  final File _file;
  int _position = 0;

  Future<RandomAccessFile> setPosition(int position) async {
    _position = position;
    return this;
  }

  Future<Uint8List> read(int count) async {
    final bytes = _file.readAsBytesSync();
    final end = (_position + count).clamp(0, bytes.length);
    final out = Uint8List.sublistView(bytes, _position.clamp(0, bytes.length), end);
    _position = end;
    return Uint8List.fromList(out);
  }

  Future<void> close() async {}
}

/// A browser is none of the hosts the app branches on. `operatingSystem` is
/// reported honestly so log lines say where they came from.
abstract final class Platform {
  static bool get isAndroid => false;
  static bool get isIOS => false;
  static bool get isLinux => false;
  static bool get isMacOS => false;
  static bool get isWindows => false;
  static bool get isFuchsia => false;
  static String get operatingSystem => 'web';
  static String get operatingSystemVersion => '';
}

class ProcessResult {
  ProcessResult(this.pid, this.exitCode, this.stdout, this.stderr);

  final int pid;
  final int exitCode;
  final dynamic stdout;
  final dynamic stderr;
}

/// There is no subprocess in a browser. The app's only caller is the
/// external-link opener, which already treats an unhandled platform as
/// "do nothing".
abstract final class Process {
  static Future<ProcessResult> run(
    String executable,
    List<String> arguments,
  ) async =>
      ProcessResult(0, 1, '', 'Process.run is unavailable on the web');
}

/// The one caller (the Wikipedia extract fetch) wraps this in `catch (_)` and
/// falls back to no extract, so throwing is the correct web behaviour — a
/// cross-origin request from the browser would fail anyway.
class HttpClient {
  Future<HttpClientRequest> getUrl(Uri url) =>
      throw UnsupportedError('HttpClient is unavailable on the web');

  void close({bool force = false}) {}
}

abstract class HttpClientRequest {
  Future<HttpClientResponse> close();
}

abstract class HttpClientResponse implements Stream<List<int>> {
  int get statusCode;
}
