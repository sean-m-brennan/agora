// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Spawns and supervises the standalone `agorad` AT daemon as a child process,
// so the Flutter GUI process never fork()s. The two AF_UNIX queue names are
// generated per-instance under the runtime dir.

import 'dart:io';

import '../ffi/native_paths.dart';

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
  AgoraDaemon({
    required this.queues,
    String? root,
    this.logLevel = 3,
    this.external = false,
  }) : root = root ?? defaultRoot();

  /// Attach to an `agorad` that is ALREADY running under [root] instead of
  /// spawning one. In this mode [start] and [stop] do not launch or kill any
  /// process — the app is a pure app-events client of the external daemon. Used
  /// when a daemon is managed separately (a system service, or a netns-isolated
  /// cohort node the GUI observes over its filesystem socket — see
  /// test/cohort/two_node_gui.sh). Toggled via $AGORA_EXTERNAL_DAEMON.
  final bool external;

  final AgoraQueues queues;

  /// $AUTONOMOUS_TRUST_ROOT for both the daemon and the in-process app-events
  /// client (they must agree to meet on the same sockets). Kept short so the
  /// full `$root/var/at/<socket>` path fits an AF_UNIX sun_path (108 bytes on
  /// Linux, 104 on macOS).
  final String root;

  /// 1=DEBUG 2=INFO 3=WARNING 4=ERROR 5=CRITICAL.
  final int logLevel;

  Process? _proc;

  bool get isRunning => _proc != null;

  /// A short, per-user config root. Honors an existing AUTONOMOUS_TRUST_ROOT,
  /// else $XDG_STATE_HOME/agora, else $HOME/.local/state/agora (on macOS,
  /// $HOME/Library/Application Support/Agora, the platform's place for it),
  /// else a temp dir. agorad.c defaults the same way when run on its own. A
  /// default whose socket paths would not fit falls back to the temp dir.
  static String defaultRoot() {
    final env = Platform.environment;
    final explicit = env['AUTONOMOUS_TRUST_ROOT'];
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final home = env['HOME'];
    final xdg = env['XDG_STATE_HOME'];
    final localAppData = env['LOCALAPPDATA'];
    final String? preferred;
    if (Platform.isWindows) {
      preferred = (localAppData != null && localAppData.isNotEmpty)
          ? '$localAppData\\Agora'
          : null;
    } else if (Platform.isMacOS && home != null && home.isNotEmpty) {
      preferred = '$home/Library/Application Support/Agora';
    } else if (xdg != null && xdg.isNotEmpty) {
      preferred = '$xdg/agora';
    } else if (home != null && home.isNotEmpty) {
      preferred = '$home/.local/state/agora';
    } else {
      preferred = null;
    }
    final queues = AgoraQueues.forThisInstance();
    if (preferred != null &&
        socketPathFits(preferred, queues.appToAt) &&
        socketPathFits(preferred, queues.atToApp)) {
      return preferred;
    }
    return '${Directory.systemTemp.path}/agora';
  }

  static String _daemonPath() {
    final override = Platform.environment['AGORA_DAEMON_PATH'];
    if (override != null && override.isNotEmpty) return override;
    // Bundled build: agorad ships in the app's lib/ dir on Linux, beside the
    // app executable on macOS (native_paths.dart). Its rpath finds the AT
    // libraries, so no LD_LIBRARY_PATH is needed. A Finder-launched macOS app
    // has a minimal PATH, so the bare-name fallback below is for dev only.
    final bundled = '${bundledDaemonDir()}/$daemonExeName';
    if (File(bundled).existsSync()) return bundled;
    // Dev default: rely on PATH / AGORA_DAEMON_PATH.
    return daemonExeName;
  }

  Future<void> start() async {
    // Attach mode: the daemon is managed elsewhere; nothing to spawn. The
    // app-events client (opened by the caller under our [root]) reaches its
    // sockets directly — an AF_UNIX pathname socket is not network-namespace
    // scoped, so this works even when the daemon runs inside a netns.
    if (external) return;
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
    // Attach mode owns no process: leave the external daemon and its sockets
    // alone (another owner manages its lifecycle).
    if (external) return;
    final p = _proc;
    if (p == null) return;
    _proc = null;
    if (Platform.isWindows) {
      // Windows has no SIGTERM to send: Process.kill is TerminateProcess,
      // which gives the node no chance to stop its subsystems or save its
      // stores. agorad stops when its stdin closes (agorad.c watch_stdin), so
      // close it, wait out AT's own 5 s shutdown, and only then terminate.
      await p.stdin.close();
      await p.exitCode.timeout(const Duration(seconds: 7), onTimeout: () {
        p.kill();
        return -1;
      });
    } else {
      p.kill(ProcessSignal.sigterm);
      await p.exitCode
          .timeout(const Duration(seconds: 5), onTimeout: () {
        p.kill(ProcessSignal.sigkill);
        return -1;
      });
    }
    _cleanupSockets();
  }

  void _cleanupSockets() {
    // The sockets live under $root/var/at/<name> (AT's data dir), not at the
    // bare name. Best-effort removal of the two app-facing ones; AT unlinks its
    // own on the next bind, so this is just tidiness.
    // `<name>.s` is the stream link's socket (Windows; AT_IPC_STREAM=1).
    for (final name in [queues.appToAt, queues.atToApp]) {
      for (final path in ['$root/var/at/$name', '$root/var/at/$name.s']) {
        try {
          final f = File(path);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {
          // best-effort
        }
      }
    }
  }
}
