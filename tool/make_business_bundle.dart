// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Mint a REAL, self-verifying Ethne business-page bundle and print
// {"polity","bundle","seq","name","locality"} as JSON on stdout.
//
// The live business cohort (test/cohort/business_cohort.sh) uses this so the
// page travelling between nodes is the genuine artifact — polity-root → envoy →
// page — and not a stub. That matters for the cohort's central claim: the page
// proves itself, so it stays good after the business node is gone.
//
//   dart run tool/make_business_bundle.dart [--name N] [--locality GEOHASH]
//
// Needs the cdylib: AGORA_ETHNE_PATH, or native/build/libethne_agora.{so,dylib}.

import 'dart:convert';
import 'dart:io';

import 'package:agora/src/ffi/ethne_bindings.dart';

String _arg(List<String> a, String flag, String dflt) {
  final i = a.indexOf(flag);
  return (i >= 0 && i + 1 < a.length) ? a[i + 1] : dflt;
}

void main(List<String> args) {
  final name = _arg(args, '--name', 'Corner Cafe');
  final locality = _arg(args, '--locality', 'u4pruy');
  final category = _arg(args, '--category', 'cafe');
  final seq = int.tryParse(_arg(args, '--seq', '1')) ?? 1;

  final libPath = EthneFfi.resolveLibraryPath();
  if (libPath == null) {
    stderr.writeln('ethne_agora not found (set AGORA_ETHNE_PATH or build '
        'native/build/libethne_agora.{so,dylib})');
    exit(2);
  }
  final ffi = EthneFfi.open(libPath);

  // Found the polity with three members, ratified by a majority, then give one
  // of them the envoy office — the only voice authorized to publish a page.
  final polity = ffi.generateKeypair();
  final founders = List.generate(3, (_) => ffi.generateKeypair());
  final arc = ffi.newArchive();
  try {
    arc.foundPolity(
      polityDid: polity.did,
      name: name,
      statement: 'A neighborhood business.',
      memberDids: founders.map((f) => f.did).toList(),
      ratifiers: [founders[0], founders[1]],
    );
    final envoy = founders[2];
    arc.authorizeEnvoy(
      polityDid: polity.did,
      envoy: envoy,
      rationale: 'speaks for the shop',
      authorizers: [founders[0], founders[1]],
    );
    final delegation = arc.envoyDelegation(
      polityDid: polity.did,
      envoyDid: envoy.did,
      root: polity,
    );
    final page = ffi.signBusinessPage(
      polityDid: polity.did,
      envoy: envoy,
      name: name,
      category: category,
      description: 'Open early, good chairs.',
      locality: locality,
      contact: 'hello@$category',
      seq: seq,
    );
    final bundle = jsonEncode({
      'page': jsonDecode(page),
      'delegation': jsonDecode(delegation),
    });
    // Refuse to emit a bundle that does not verify: the cohort's whole point is
    // that the artifact stands on its own.
    if (!ffi.verifyBusinessPageBundle(bundle)) {
      stderr.writeln('minted bundle did not verify: ${arc.lastError()}');
      exit(3);
    }
    stdout.writeln(jsonEncode({
      'polity': polity.did,
      'bundle': bundle,
      'seq': seq,
      'name': name,
      'locality': locality,
    }));
  } finally {
    arc.dispose();
  }
}
