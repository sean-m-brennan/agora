// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// "In your city": people nearby, found at the area hubs of the communities
// this reader follows (SOCIAL_APP_PLAN Phase 4, §4.1 band 2). Being findable
// is its own opt-in, separate from sharing a bucket with connected peers, and
// a hub shows its list only to people listed in the same area. Found people are
// strangers until they say yes: asking goes through first contact, and a yes
// makes a direct peer, unverified until the two compare safety numbers.

import 'package:flutter/material.dart';

import '../model/hub_directory.dart';
import '../node/peer_stream.dart';

class NearbyHubsPage extends StatefulWidget {
  const NearbyHubsPage({super.key, required this.service});

  final PeerService service;

  @override
  State<NearbyHubsPage> createState() => _NearbyHubsPageState();
}

class _NearbyHubsPageState extends State<NearbyHubsPage> {
  late final TextEditingController _name =
      TextEditingController(text: widget.service.hubName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String _why(PeerService s) {
    if (s.hubAreas.isEmpty) {
      return 'None of the communities you follow runs an area hub yet.';
    }
    if (s.ownGeohash == null) {
      return 'Share your ~5 km bucket first (the location button on People near '
          'me): a hub lists you under it and nothing finer.';
    }
    return 'Your bucket is outside every area your communities\' hubs serve '
        '(${s.hubAreas.join(', ')}).';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    return Scaffold(
      appBar: AppBar(
        title: const Text('In your city'),
        actions: [
          ListenableBuilder(
            listenable: s,
            builder: (context, _) => IconButton(
              key: const Key('hub-lookup'),
              icon: const Icon(Icons.refresh),
              tooltip: 'Look again',
              onPressed: s.listedAtHubs ? s.lookupNearby : null,
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) {
          final listable = s.listableAreas;
          final cards = s.hubs.allCards(personOf: s.personKey);
          final incoming = s.hubs.incoming.values.toList();
          return ListView(
            children: [
              SwitchListTile(
                key: const Key('hub-list-me'),
                title: const Text('List me at my communities\' hubs'),
                subtitle: Text(listable.isEmpty
                    ? _why(s)
                    : s.listedAtHubs
                        ? 'Listed in ${s.hubs.listed.join(', ')}. People listed '
                            'there can find you and ask to connect.'
                        : 'Off. Only people listed in the same area can see who '
                            'is listed, and nobody can add you without your yes.'),
                value: s.listedAtHubs,
                onChanged: listable.isEmpty
                    ? null
                    : (on) => s.setListedAtHubs(on, name: _name.text.trim()),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  key: const Key('hub-name'),
                  controller: _name,
                  maxLength: 64,
                  decoration: const InputDecoration(
                      labelText: 'Name to list under (optional)'),
                ),
              ),
              for (final area in s.hubs.refusals.keys)
                ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: Text('The hub for $area said no'),
                  subtitle: Text(s.hubs.refusals[area]!),
                ),
              if (incoming.isNotEmpty) const _Heading('Asking to connect'),
              for (final c in incoming)
                ListTile(
                  key: Key('hub-request-${c.ref}'),
                  leading: const Icon(Icons.person_add_alt),
                  title: Text(c.nickname.isEmpty ? c.uuidHex.substring(0, 8) : c.nickname),
                  subtitle: Text('Found you ${c.foundBy.startsWith('area:') ? 'in ${c.foundBy.substring(5)}' : 'as ${c.foundBy}'}'),
                  trailing: Wrap(spacing: 4, children: [
                    TextButton(
                        onPressed: () => s.declineContact(c), child: const Text('Decline')),
                    FilledButton(
                        onPressed: () => s.acceptContact(c), child: const Text('Accept')),
                  ]),
                ),
              if (s.listedAtHubs) const _Heading('Listed nearby'),
              if (s.listedAtHubs && cards.isEmpty)
                const ListTile(title: Text('Nobody else is listed here yet.')),
              for (final c in cards) _CardTile(card: c, service: s),
            ],
          );
        },
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

class _CardTile extends StatelessWidget {
  const _CardTile({required this.card, required this.service});

  final HubCard card;
  final PeerService service;

  @override
  Widget build(BuildContext context) {
    final km = card.distanceKmFrom(service.ownGeohash);
    final stage = service.hubs.outgoing[card.uuidHex];
    return ListTile(
      key: Key('hub-card-${card.uuidHex}'),
      leading: const Icon(Icons.person_outline),
      title: Text(card.name.isEmpty ? 'Someone in ${card.area}' : card.name),
      subtitle: Text(km == null ? 'In ${card.area}' : '~${km.toStringAsFixed(0)} km away'),
      trailing: switch (stage) {
        ContactStage.established => const Chip(label: Text('Connected')),
        ContactStage.asked => const Chip(label: Text('Asked')),
        ContactStage.refused => const Chip(label: Text('Could not ask')),
        _ => FilledButton.tonal(
            onPressed: () => service.askToConnect(card),
            child: const Text('Ask to connect')),
      },
    );
  }
}
