// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// A best-effort JSON-file store for the reader's [CommunityBook] (Phase 4): the
// policies it follows and has heard, and which it has switched off. A
// structural copy of ModerationStore. Labels are NOT kept: they are a live
// stream, backfilled by followers after a split, like posts.
//
// The core keeps its own record of what this node follows (social.cfg.json),
// because it CARRIES those policies; this file is what the app needs to APPLY
// them, and every bundle in it is re-verified on load.

import 'dart:convert';
import 'dart:io';

import 'community_policy.dart';

class CommunityPolicyStore {
  CommunityPolicyStore(this.file);

  final File file;
  CommunityBook book = CommunityBook();

  /// Load from disk, re-verifying each bundle with [verify]. On any error,
  /// leaves [book] empty. Returns this for chaining.
  Future<CommunityPolicyStore> load(
      Map<String, dynamic>? Function(String bundle) verify) async {
    try {
      if (await file.exists()) {
        final obj = jsonDecode(await file.readAsString());
        if (obj is Map<String, dynamic>) {
          book = CommunityBook.fromJson(obj, verify);
        }
      }
    } catch (_) {
      // keep empty
    }
    return this;
  }

  /// Persist the current book. Best-effort; never throws.
  Future<void> save() async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(book.toJson()));
    } catch (_) {
      // best-effort
    }
  }
}
