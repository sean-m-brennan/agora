// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// This device's cert (SOCIAL_APP_PLAN Phase 4, multi-device): the operator's
// signed word that this node is one of their devices. The operator key never
// enters a node or this app; the cert is issued out of band with AT's
// tools/device_cert.py, wherever the operator's keystore is, and lands in
// <root>/etc/at/device_cert.cfg.json. The node checks the signature and that
// the cert names it when it starts; this file only reads what is there, to say
// whether pairing and device linking can work here at all.

import 'dart:convert';
import 'dart:io';

enum DeviceCertState {
  /// No cert: this device links to nothing, and pairing is refused.
  none,

  /// A cert naming this node.
  ours,

  /// A cert naming some other node: the node ignores it.
  foreign,

  /// A file that is not a cert.
  unreadable,
}

class DeviceCertStatus {
  const DeviceCertStatus(this.state, {this.operator = '', this.uuid = ''});

  final DeviceCertState state;

  /// The operator's public key, hex, as the cert names it.
  final String operator;

  /// The node the cert names (lower-case, dashed).
  final String uuid;

  static const DeviceCertStatus unknown = DeviceCertStatus(DeviceCertState.none);

  /// Short operator fingerprint for display: the first 16 hex, in fours.
  String get operatorShort {
    if (operator.length < 16) return operator;
    final s = operator.substring(0, 16);
    return [for (var i = 0; i < 16; i += 4) s.substring(i, i + 4)].join(' ');
  }

  /// Read [root]'s cert and compare it with [ownUuidHex] (32 hex, no dashes).
  static Future<DeviceCertStatus> load(String root, String ownUuidHex) async {
    final f = File(path(root));
    try {
      if (!await f.exists()) return const DeviceCertStatus(DeviceCertState.none);
      return parse(await f.readAsString(), ownUuidHex);
    } on Object {
      return const DeviceCertStatus(DeviceCertState.unreadable);
    }
  }

  /// The status of cert file text [text] for the node [ownUuidHex].
  static DeviceCertStatus parse(String text, String ownUuidHex) {
    try {
      final outer = jsonDecode(text);
      if (outer is! Map || outer['body'] is! String || outer['sig'] is! String) {
        return const DeviceCertStatus(DeviceCertState.unreadable);
      }
      final body = jsonDecode(outer['body'] as String);
      if (body is! Map || body['operator'] is! String || body['uuid'] is! String) {
        return const DeviceCertStatus(DeviceCertState.unreadable);
      }
      final op = body['operator'] as String;
      final uu = body['uuid'] as String;
      final mine = ownUuidHex.isNotEmpty &&
          uu.replaceAll('-', '').toLowerCase() == ownUuidHex.toLowerCase();
      return DeviceCertStatus(
          mine ? DeviceCertState.ours : DeviceCertState.foreign,
          operator: op,
          uuid: uu);
    } on FormatException {
      return const DeviceCertStatus(DeviceCertState.unreadable);
    }
  }

  static String path(String root) => '$root/etc/at/device_cert.cfg.json';

  /// The command that issues this node's cert, run from an AutonomousTrust
  /// checkout on the machine holding the operator keystore while Agora is
  /// stopped. Restart Agora afterwards: the node reads its cert at startup.
  static String issueCommand(String root) =>
      'AUTONOMOUS_TRUST_ROOT="$root" python3 tools/device_cert.py issue';
}
