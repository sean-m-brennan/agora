// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Mint a REAL business polity and emit, from that ONE polity, its
// self-verifying page bundle plus one self-verifying {post,delegation} bundle
// per --post (Phase 3 P3.4).
//
// WHY BOTH, FROM ONE INVOCATION. A post only means anything to a reader that
// already holds the business's PAGE — the core drops a post from a polity it
// knows nothing about — so a cohort needs a page and posts that belong to the
// same polity, signed by the same envoy. Minting them separately would mint
// two different businesses and the run would fail at the audience gate for a
// reason that has nothing to do with what it is testing.
//
//   dart run tool/make_business_post.dart [--name N] [--locality GEOHASH] \
//       [--post "body"] [--post "another"]
//
// Prints one JSON object:
//   {"polity","page_bundle","page_seq","name","locality",
//    "posts":[{"seq","body","bundle"}, ...]}
//
// Needs the cdylib: AGORA_ETHNE_PATH, or native/build/libethne_agora.{so,dylib}.

import 'dart:convert';
import 'dart:io';

import 'package:agora/src/ffi/ethne_bindings.dart';

String _arg(List<String> a, String flag, String dflt) {
  final i = a.indexOf(flag);
  return (i >= 0 && i + 1 < a.length) ? a[i + 1] : dflt;
}

/// Every value given to a repeatable flag, in order.
List<String> _args(List<String> a, String flag) {
  final out = <String>[];
  for (var i = 0; i < a.length - 1; i++) {
    if (a[i] == flag) out.add(a[i + 1]);
  }
  return out;
}

void main(List<String> args) {
  final name = _arg(args, '--name', 'Corner Cafe');
  final locality = _arg(args, '--locality', 'u4pruy');
  final category = _arg(args, '--category', 'cafe');
  final pageSeq = int.tryParse(_arg(args, '--seq', '1')) ?? 1;
  final bodies = _args(args, '--post');
  if (bodies.isEmpty) bodies.add('Fresh croissants at seven.');

  final libPath = EthneFfi.resolveLibraryPath();
  if (libPath == null) {
    stderr.writeln('ethne_agora not found (set AGORA_ETHNE_PATH or build '
        'native/build/libethne_agora.{so,dylib})');
    exit(2);
  }
  final ffi = EthneFfi.open(libPath);

  // Found the polity with three members, ratified by a majority, then give one
  // of them the envoy office — the only voice authorized to speak AS the shop.
  // Being on the roll is not enough, which is the whole point of box 5.
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
    final decodedDelegation = jsonDecode(delegation);

    final page = ffi.signBusinessPage(
      polityDid: polity.did,
      envoy: envoy,
      name: name,
      category: category,
      description: 'Open early, good chairs.',
      locality: locality,
      contact: 'hello@$category',
      seq: pageSeq,
    );
    final pageBundle = jsonEncode({
      'page': jsonDecode(page),
      'delegation': decodedDelegation,
    });
    // Refuse to emit anything that does not verify: the cohort's whole claim is
    // that these artifacts stand on their own.
    if (!ffi.verifyBusinessPageBundle(pageBundle)) {
      stderr.writeln('minted page bundle did not verify: ${arc.lastError()}');
      exit(3);
    }

    final posts = <Map<String, Object>>[];
    for (var i = 0; i < bodies.length; i++) {
      final seq = i + 1;
      final post = ffi.signBusinessPost(
        polityDid: polity.did,
        envoy: envoy,
        body: bodies[i],
        seq: seq,
      );
      final bundle = jsonEncode({
        'post': jsonDecode(post),
        'delegation': decodedDelegation,
      });
      if (!ffi.verifyBusinessPostBundle(bundle)) {
        stderr.writeln('minted post bundle $seq did not verify: '
            '${ffi.lastError()}');
        exit(3);
      }
      // The full-log verifier too, while the archive is still in hand: it is
      // the check a node holding the charter would run, and disagreeing with
      // the self-contained one would mean the two tiers had drifted apart.
      if (!arc.verifyBusinessPostFull(post)) {
        stderr.writeln('minted post $seq failed full-log verification: '
            '${arc.lastError()}');
        exit(3);
      }
      posts.add({'seq': seq, 'body': bodies[i], 'bundle': bundle});
    }

    stdout.writeln(jsonEncode({
      'polity': polity.did,
      'page_bundle': pageBundle,
      'page_seq': pageSeq,
      'name': name,
      'locality': locality,
      'posts': posts,
    }));
  } finally {
    arc.dispose();
  }
}
