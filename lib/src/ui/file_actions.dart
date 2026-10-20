// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// What a person can do with a file that arrived: open it, show it in its
// folder, or save a copy somewhere of their choosing. The received file itself
// stays where the core put it (var/agora/files under the node's root).

import 'dart:io';

import 'package:file_selector/file_selector.dart';

/// Open [path] with the desktop's default application.
Future<void> openWithSystem(String path) => _run(
      Platform.isMacOS
          ? ['open', path]
          : Platform.isWindows
              ? ['explorer.exe', path]
              : ['xdg-open', path],
    );

/// Show [path] in the desktop's file manager, selected where it can be.
Future<void> revealInFolder(String path) => _run(
      Platform.isMacOS
          ? ['open', '-R', path]
          : Platform.isWindows
              ? ['explorer.exe', '/select,$path']
              : ['xdg-open', File(path).parent.path],
    );

/// Ask where to save a copy of [path], then copy it there. Returns the copy's
/// path, or null if the person cancelled.
Future<String?> saveCopyAs(String path, String suggestedName) async {
  final loc = await getSaveLocation(suggestedName: suggestedName);
  if (loc == null) return null;
  await File(path).copy(loc.path);
  return loc.path;
}

/// Files the person picks to send, as paths ([] if cancelled).
Future<List<String>> pickFilesToSend() async {
  final files = await openFiles(confirmButtonText: 'Send');
  return [for (final f in files) f.path];
}

Future<void> _run(List<String> cmd) async {
  // Detached: the viewer outlives nothing of ours and owes us no exit code.
  await Process.start(cmd.first, cmd.sublist(1),
      mode: ProcessStartMode.detached);
}

/// "1.4 MB", "820 KB", "12 B".
String humanSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return u == 0
      ? '$bytes B'
      : '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[u]}';
}
