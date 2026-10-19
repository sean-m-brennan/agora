// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// A DECIDER's half of a co-signature exchange, for the live staff cohort
// (test/cohort/staff_cohort.sh). It is a separate tool from staff_govern.dart
// because the separation is the point: a decider signs with its own key and
// never touches the charter log. Nothing here opens an archive.
//
// WHAT IT REFUSES, AND WHY EACH REFUSAL EXISTS:
//
//   * Bytes that do not describe. `ethne_describe` reads the act out of the
//     bytes on THIS node. If they cannot be read as the record class they claim,
//     nothing here knows what would be signed, and signing anyway is the habit
//     the whole two-phase design exists to avoid teaching.
//   * A cid that does not match. The asker sends a cid alongside the bytes; this
//     recomputes it. A mismatch means the ask names one act and carries another.
//   * An act this node was not asked to decide. If our DID is not among the
//     required signers, a signature from us is a signature nobody wanted.
//
// NOTE WHAT DOES NOT ARRIVE: no description crosses the wire, by design. A node
// that chose both the bytes and the sentence describing them could put a
// friendly sentence over a hostile act and collect a real signature on the end
// of it. So the wording printed below is derived here and nowhere else.
//
//   dart run tool/cosign_sign.dart --node <dir> --received <file.json>
//
// <file.json> is what the cohort driver wrote from the received event:
// {"record","op","polity","cid","bytes",...}. Prints {"signer_did","sig",
// "description","op"} on stdout, or exits non-zero with the reason.
//
// Needs the cdylib: AGORA_ETHNE_PATH, or native/build/libethne_agora.{so,dylib}.

import 'dart:convert';
import 'dart:io';

import 'package:agora/src/ffi/ethne_bindings.dart';
import 'package:agora/src/model/staff_identity.dart';

String _arg(List<String> a, String flag, String dflt) {
  final i = a.indexOf(flag);
  return (i >= 0 && i + 1 < a.length) ? a[i + 1] : dflt;
}

Never _die(String msg, [int code = 1]) {
  stderr.writeln(msg);
  exit(code);
}

Future<void> main(List<String> args) async {
  final nodeDir = _arg(args, '--node', '');
  final receivedPath = _arg(args, '--received', '');
  if (nodeDir.isEmpty || receivedPath.isEmpty) {
    _die('usage: cosign_sign.dart --node <dir> --received <file.json>', 2);
  }

  final libPath = EthneFfi.resolveLibraryPath();
  if (libPath == null) {
    _die(
        'ethne_agora not found (set AGORA_ETHNE_PATH or build '
        'native/build/libethne_agora.{so,dylib})',
        2);
  }
  final ffi = EthneFfi.open(libPath);

  final store = await StaffIdentityStore(
          File('$nodeDir/etc/at/agora.polity.json'))
      .load();
  final me = store.identity;
  if (me == null) _die('no usable staff identity under $nodeDir');

  final received =
      jsonDecode(File(receivedPath).readAsStringSync()) as Map<String, dynamic>;
  final bytes = received['bytes'] as String? ?? '';
  final claimedCid = received['cid'] as String? ?? '';
  final record = received['record'] as String? ?? 'membership';
  if (bytes.isEmpty) _die('the ask carried no bytes; there is nothing to sign');

  // A signature must never be given for a private key, and none should have
  // arrived — say so loudly if one did, because it would mean the wire is
  // carrying something the design forbids.
  if (received.containsKey('priv') || received.containsKey('private')) {
    _die('the ask carried a private key: refusing, and this is a wire bug');
  }

  Map<String, dynamic> act;
  try {
    act = ffi.describe(record: record, bytesHex: bytes);
  } on EthneException catch (e) {
    _die('these bytes cannot be read as a $record act, so nothing here knows '
        'what would be signed: $e');
  }

  final derivedCid = act['cid'] as String? ?? '';
  if (claimedCid.isNotEmpty && derivedCid != claimedCid) {
    _die('the ask names $claimedCid but its bytes are $derivedCid: it names one '
        'act and carries another');
  }

  final deciders = (act['deciders'] as List?)?.cast<String>() ?? const <String>[];
  final target = act['member_did'] as String?;
  final required = <String>{
    ...deciders,
    // An admission takes the joiner's own consent as well as the deciders'.
    if (act['op'] == 'admit' && target != null) target,
  };
  if (required.isNotEmpty && !required.contains(me.self.did)) {
    _die('${me.self.did} is not among the signers this act requires');
  }

  final sig = ffi.signDetached(priv: me.self.priv, bytesHex: bytes);
  stdout.writeln(jsonEncode({
    'signer_did': me.self.did,
    'sig': sig,
    'op': act['op'],
    // Derived here, from the bytes. The asker sent no wording and could not have.
    'description': act['description'],
  }));
}
