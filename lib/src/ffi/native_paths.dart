// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Where Agora's native artifacts (agorad, the shim, the AT libraries, Ethne's
// cdylib) live on each desktop platform, in one place. The loaders in
// at_events_bindings.dart, ethne_bindings.dart and agora_daemon.dart ask here
// rather than spelling a platform's layout themselves.
//
//   Linux  <exe dir>/lib/  holds agorad and every .so (linux/CMakeLists.txt
//          install rules); their $ORIGIN rpath finds each other.
//   macOS  Agora.app/Contents/Frameworks/ holds every .dylib, and agorad sits
//          beside the app executable in Contents/MacOS/ (macos/embed_native.sh);
//          their rpaths are @loader_path and @executable_path/../Frameworks.
//   Windows agorad.exe and every DLL sit beside the app's exe
//          (windows/CMakeLists.txt), where Windows looks for a DLL's DLLs.

import 'dart:io';

/// A library the native CMake build makes: `lib<stem>.so` on Linux,
/// `lib<stem>.dylib` on macOS, `lib<stem>.dll` on Windows (MinGW keeps the
/// prefix).
String nativeLibName(String stem) {
  if (Platform.isMacOS) return 'lib$stem.dylib';
  if (Platform.isWindows) return 'lib$stem.dll';
  return 'lib$stem.so';
}

/// A Rust cdylib Cargo makes: as [nativeLibName], except that on Windows Cargo
/// names it `<stem>.dll`, with no prefix.
String cargoLibName(String stem) =>
    Platform.isWindows ? '$stem.dll' : nativeLibName(stem);

/// agorad's file name: `agorad.exe` on Windows.
String get daemonExeName => Platform.isWindows ? 'agorad.exe' : 'agorad';

String get _exeDir => File(Platform.resolvedExecutable).parent.path;

/// The directory a bundled build ships its shared libraries in.
String bundledLibDir() {
  if (Platform.isMacOS) return '${Directory(_exeDir).parent.path}/Frameworks';
  if (Platform.isWindows) return _exeDir;
  return '$_exeDir/lib';
}

/// The directory a bundled build ships agorad in.
String bundledDaemonDir() =>
    Platform.isMacOS || Platform.isWindows ? _exeDir : '$_exeDir/lib';

/// The longest AF_UNIX socket path, in bytes, NUL included: `sun_path` is 108
/// bytes on Linux and Windows and 104 on macOS.
int get sunPathSize => Platform.isMacOS ? 104 : 108;

/// True when `<root>/var/at/<queue>` fits a socket path (AT's message.c builds
/// exactly that, and refuses a root that does not fit). The `.s` is the stream
/// link's suffix (utilities/message_stream.c), which Windows always uses.
bool socketPathFits(String root, String queue) =>
    '$root/var/at/$queue.s'.length < sunPathSize;
