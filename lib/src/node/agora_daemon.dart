// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Spawns and supervises the standalone `agorad` AT daemon as a child process,
// so the Flutter GUI process never fork()s. The two AF_UNIX queue names are
// generated per-instance under the runtime dir.

import 'dart:io';

class AgoraQueues {
  AgoraQueues(this.appToAt, this.atToApp);

  /// app -> AT (run_autonomous_trust's `q_in`; at_node_config_t's `q_out`).
  final String appToAt;

  /// AT -> app (run_autonomous_trust's `q_out`; at_node_config_t's `q_in`).
  /// This is the queue the app opens to receive events.
  final String atToApp;

  /// The queue arguments are BARE names, not paths: AT roots each socket at
  /// `$AUTONOMOUS_TRUST_ROOT/var/at/<name>` (an absolute path would be wrongly
  /// concatenated under var/at and fail to bind). These are AT's own defaults,
  /// which the app-events client also uses. One daemon per app process, each
  /// under its own root, so fixed names are safe (distinct roots keep two
  /// same-host instances separate).
  factory AgoraQueues.forThisInstance() =>
      AgoraQueues('extern_to_at', 'at_to_extern');
}

int pid_() => pid;

class AgoraDaemon {
  AgoraDaemon({required this.queues, String? root, this.logLevel = 3})
      : root = root ?? defaultRoot();

  final AgoraQueues queues;

  /// $AUTONOMOUS_TRUST_ROOT for both the daemon and the in-process app-events
  /// client (they must agree to meet on the same sockets). Kept short so the
  /// full `$root/var/at/<socket>` path fits an AF_UNIX sun_path (108 bytes).
  final String root;

  /// 1=DEBUG 2=INFO 3=WARNING 4=ERROR 5=CRITICAL.
  final int logLevel;

  Process? _proc;

  bool get isRunning => _proc != null;

  /// A short, per-user config root. Honors an existing AUTONOMOUS_TRUST_ROOT,
  /// else $XDG_STATE_HOME/agora, else $HOME/.local/state/agora, else a temp dir.
  static String defaultRoot() {
    final env = Platform.environment;
    final explicit = env['AUTONOMOUS_TRUST_ROOT'];
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final xdg = env['XDG_STATE_HOME'];
    if (xdg != null && xdg.isNotEmpty) return '$xdg/agora';
    final home = env['HOME'];
    if (home != null && home.isNotEmpty) return '$home/.local/state/agora';
    return '${Directory.systemTemp.path}/agora';
  }

  static String _daemonPath() {
    final override = Platform.environment['AGORA_DAEMON_PATH'];
    if (override != null && override.isNotEmpty) return override;
    // Bundled build: agorad ships in the app's lib/ dir, next to the executable
    // (linux/CMakeLists.txt install rules). Its $ORIGIN rpath finds the AT core
    // in that same dir, so no LD_LIBRARY_PATH is needed.
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = '$exeDir/lib/agorad';
    if (File(bundled).existsSync()) return bundled;
    // Dev default: rely on PATH / AGORA_DAEMON_PATH.
    return 'agorad';
  }

  Future<void> start() async {
    if (_proc != null) return;
    _proc = await Process.start(
      _daemonPath(),
      [queues.appToAt, queues.atToApp, '$logLevel'],
      // Child inherits our env plus the shared config root, so it and the
      // in-process app-events client resolve the same $root/var/at/ sockets.
      environment: {'AUTONOMOUS_TRUST_ROOT': root},
    );
    // Surface daemon logs for visibility during development.
    _proc!.stdout.listen(stdout.add);
    _proc!.stderr.listen(stderr.add);
  }

  Future<void> stop() async {
    final p = _proc;
    if (p == null) return;
    _proc = null;
    p.kill(ProcessSignal.sigterm);
    await p.exitCode
        .timeout(const Duration(seconds: 5), onTimeout: () {
      p.kill(ProcessSignal.sigkill);
      return -1;
    });
    _cleanupSockets();
  }

  void _cleanupSockets() {
    // The sockets live under $root/var/at/<name> (AT's data dir), not at the
    // bare name. Best-effort removal of the two app-facing ones; AT unlinks its
    // own on the next bind, so this is just tidiness.
    for (final name in [queues.appToAt, queues.atToApp]) {
      try {
        final f = File('$root/var/at/$name');
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        // best-effort
      }
    }
  }
}
