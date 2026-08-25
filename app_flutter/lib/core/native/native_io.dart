/// Native half of the io seam: the real thing, narrowed to what the app uses
/// so the web twin has a closed set to implement.
library;

export 'dart:io'
    show
        Directory,
        File,
        FileMode,
        FileSystemEntity,
        HttpClient,
        HttpClientRequest,
        HttpClientResponse,
        IOSink,
        Platform,
        Process,
        ProcessResult,
        RandomAccessFile;
