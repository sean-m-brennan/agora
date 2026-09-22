// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// A best-effort JSON-file store for [ModerationState] (Phase 4 P4.1). A
// structural copy of TieSettingsStore: load once at startup, mutate through the
// state, save. Every method swallows I/O errors — losing this file loses only
// the operator's own notes on why they reported someone and the advisory count,
// both of which the core's authority makes safe to lose.
//
// Blocks are NOT here. The core owns them (etc/at/social.cfg.json) because it
// enforces them, and an app-side copy would be a second truth to drift.

import 'dart:convert';
import 'dart:io';

import 'moderation.dart';

class ModerationStore {
  ModerationStore(this.file);

  final File file;
  ModerationState state = ModerationState();

  /// Load from disk. On any error (missing, unreadable, malformed), leaves
  /// [state] empty. Returns this for chaining.
  Future<ModerationStore> load() async {
    try {
      if (await file.exists()) {
        final obj = jsonDecode(await file.readAsString());
        if (obj is Map<String, dynamic>) {
          state = ModerationState.fromJson(obj);
        }
      }
    } catch (_) {
      // keep empty
    }
    return this;
  }

  /// Persist the current state. Best-effort; never throws.
  Future<void> save() async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(state.toJson()));
    } catch (_) {
      // best-effort
    }
  }
}
