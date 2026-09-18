// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Mint a REAL Ethne staff polity for the live staff cohort
// (test/cohort/staff_cohort.sh) and write one `agora.polity.json` per node, in
// the shape lib/src/model/staff_identity.dart reads.
//
// The roster it builds, and why it is this size:
//
//   keeper, ada, bob, cal   founding members, and ALL FOUR RATIFY — ratifying a
//                           founding is that founder's own induction, so the
//                           polity starts with four SEASONED members rather than
//                           four on the roll and nobody able to decide.
//   ada                     holds the envoy office, so the cohort can later show
//                           it lapsing when she departs.
//   dee                     NOT a founder. She is admitted over the wire in the
//                           cohort's first phase and then inducted, taking the
//                           polity to five seasoned.
//
// Five seasoned is not arbitrary. An expulsion needs majority+1 and bars its
// target from deciding, so at five it needs four deciders drawn from exactly the
// four eligible — the bar is exactly reachable. At four seasoned it would need
// four from three and could never close, whatever anyone agreed.
//
// ONLY THE KEEPER GETS THE ROOT KEY. Publishing a roll is signing under the
// polity's own key, and the point of the cohort is that every other node signs
// with nothing but its own.
//
//   dart run tool/make_staff_polity.dart --out <run-dir> [--name N]
//
// Writes <run-dir>/<node>/etc/at/agora.polity.json for each node and prints
// {"polity","root_did","envoy","newcomer","members":{node:did}} on stdout.
//
// Needs the cdylib: AGORA_ETHNE_PATH, or native/build/libethne_agora.so.

import 'dart:convert';
import 'dart:io';

import 'package:agora/src/ffi/ethne_bindings.dart';

/// Founding members, in the order they are listed on the roll.
const founderNodes = ['keeper', 'ada', 'bob', 'cal'];

/// Admitted over the wire in the cohort's first phase, not at founding.
const newcomerNode = 'dee';

/// Holds the envoy office, and later departs so the cohort can watch it lapse.
const envoyNode = 'ada';

/// Holds the charter log and the polity root key. Every other node holds only
/// its own member key.
const keeperNode = 'keeper';

String _arg(List<String> a, String flag, String dflt) {
  final i = a.indexOf(flag);
  return (i >= 0 && i + 1 < a.length) ? a[i + 1] : dflt;
}

Map<String, dynamic> _key(EthneKeypair k) =>
    {'did': k.did, 'priv': k.priv, 'pub': k.pub};

void main(List<String> args) {
  final out = _arg(args, '--out', '');
  final name = _arg(args, '--name', 'Corner Cafe');
  if (out.isEmpty) {
    stderr.writeln('usage: make_staff_polity.dart --out <run-dir> [--name N]');
    exit(2);
  }

  final libPath = EthneFfi.resolveLibraryPath();
  if (libPath == null) {
    stderr.writeln('ethne_agora not found (set AGORA_ETHNE_PATH or build '
        'native/build/libethne_agora.so)');
    exit(2);
  }
  final ffi = EthneFfi.open(libPath);

  final polity = ffi.generateKeypair();
  final keys = <String, EthneKeypair>{
    for (final n in [...founderNodes, newcomerNode]) n: ffi.generateKeypair(),
  };

  final arc = ffi.newArchive();
  try {
    // ALL founders ratify. A listed founder who never signed is on the roll and
    // carries no deciding weight, which is a real state but not the one a cohort
    // wants to start from.
    arc.foundPolity(
      polityDid: polity.did,
      name: name,
      statement: 'A neighborhood business, run by its staff.',
      memberDids: founderNodes.map((n) => keys[n]!.did).toList(),
      ratifiers: founderNodes.map((n) => keys[n]!).toList(),
    );

    // The envoy is authorized by a majority of the roll, and co-signs: an office
    // is conferred, never conscripted.
    final authorizers =
        founderNodes.where((n) => n != envoyNode).map((n) => keys[n]!).toList();
    arc.authorizeEnvoy(
      polityDid: polity.did,
      envoy: keys[envoyNode]!,
      rationale: 'speaks for the shop',
      authorizers: authorizers,
    );

    // Refuse to emit a fixture that does not stand up, the way the business
    // minter refuses an unverifiable bundle: a cohort starting from a bad log
    // would fail somewhere far from the cause.
    if (!arc.verify()) {
      stderr.writeln('minted polity did not verify: ${arc.lastError()}');
      exit(3);
    }
    final st = arc.affirmationState(polity.did);
    if (st['seasoned'] != founderNodes.length) {
      stderr.writeln('expected ${founderNodes.length} seasoned, got '
          '${st['seasoned']} — the cohort\'s bars assume every founder ratified');
      exit(3);
    }

    // Each node gets its OWN key and a copy of the log as it stands now. Only
    // the keeper's copy advances during the run: there is no log replication in
    // this tier yet, so the others hold a founding snapshot and know it.
    final dump = jsonDecode(arc.dumpJson()) as Map<String, dynamic>;
    for (final node in [...founderNodes, newcomerNode]) {
      final identity = <String, dynamic>{
        'polity_did': polity.did,
        'self': _key(keys[node]!),
        if (node == keeperNode) 'root': _key(polity),
        'archive': dump,
      };
      final f = File('$out/$node/etc/at/agora.polity.json');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(identity));
    }

    stdout.writeln(jsonEncode({
      'polity': polity.did,
      'root_did': polity.did,
      'envoy': keys[envoyNode]!.did,
      'newcomer': keys[newcomerNode]!.did,
      'seasoned': st['seasoned'],
      'members': {for (final n in keys.keys) n: keys[n]!.did},
    }));
  } finally {
    arc.dispose();
  }
}
