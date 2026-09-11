// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Agora — a decentralized social app on AutonomousTrust.
// Phase 0 (Linux + macOS): spawn the AT daemon, show observed peers with live
// presence and reputation. See SOCIAL_APP_PLAN.md.

import 'package:flutter/material.dart';

import 'src/node/peer_stream.dart';
import 'src/ui/people_near_me.dart';

void main() {
  runApp(const AgoraApp());
}

class AgoraApp extends StatefulWidget {
  const AgoraApp({super.key});

  @override
  State<AgoraApp> createState() => _AgoraAppState();
}

class _AgoraAppState extends State<AgoraApp> {
  final PeerService _service = PeerService();

  @override
  void initState() {
    super.initState();
    _service.start();
  }

  @override
  void dispose() {
    _service.shutdown();
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Agora',
      // The debug-build ribbon paints over the AppBar's top-right actions (the
      // location/profile icons); it adds nothing here, so drop it.
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: PeopleNearMePage(service: _service),
    );
  }
}
