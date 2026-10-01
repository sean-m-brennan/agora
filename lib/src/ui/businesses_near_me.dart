// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Businesses near me (Phase 3 P3.2, SOCIAL_APP_PLAN.md §5): the directory of
// businesses whose pages have reached this node, ranked distance → who you trust
// that vouched → freshness.
//
// The page you are looking at got here because somebody carried it. A business
// advertises once to its own group; from there it travels only as CUSTOMERS
// re-advertise it in the first person, each signing their own satisfaction. So
// every entry below names the people who vouched, and a business with no
// customers shows exactly that — its own ad, and nobody else's voice.
//
// The withdrawal is silence, not a bad review: an unhappy customer clears their
// edge and stops carrying the page. Nothing negative is ever published, so there
// is nothing here to brigade with.

import 'package:flutter/material.dart' hide ConnectionState;

import '../model/business.dart';
import '../model/compact_book.dart';
import '../node/peer_stream.dart';
import 'staff_roster.dart';

class BusinessesNearMePage extends StatelessWidget {
  const BusinessesNearMePage({super.key, required this.service});

  final PeerService service;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Businesses near me'),
        actions: [
          IconButton(
            key: const Key('open-staff-roster'),
            icon: const Icon(Icons.badge_outlined),
            tooltip: 'Staff roll',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => StaffRosterPage(service: service),
              ),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          // Reach (Phase 5): businesses that sit in a compact with a community
          // this reader follows come first, under their own heading.
          final mates = service.compactMates;
          final all = service.businesses;
          final fromCompact = [for (final b in all) if (mates.contains(b.polity)) b];
          final businesses = [for (final b in all) if (!mates.contains(b.polity)) b];
          return ListView(
            children: [
              const _DirectoryLegend(),
              if (service.businessesUnverified > 0)
                _UnverifiedNotice(count: service.businessesUnverified),
              if (all.isEmpty) const _EmptyDirectory(),
              if (fromCompact.isNotEmpty)
                const Padding(
                  key: Key('from-your-compact'),
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('From your compact'),
                ),
              for (final b in fromCompact)
                _BusinessTile(business: b, service: service),
              if (fromCompact.isNotEmpty && businesses.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('Near you'),
                ),
              for (final b in businesses)
                _BusinessTile(business: b, service: service),
            ],
          );
        },
      ),
    );
  }
}

class _DirectoryLegend extends StatelessWidget {
  const _DirectoryLegend();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        'Businesses whose pages reached you, nearest first, then weighted by the '
        'people you trust who vouched for them. A business advertises once; its '
        'page travels only as customers carry it. Self-vouching counts for '
        'nothing.',
        style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
      ),
    );
  }
}

class _UnverifiedNotice extends StatelessWidget {
  const _UnverifiedNotice({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.gpp_maybe_outlined, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$count page${count == 1 ? '' : 's'} could not be verified and '
              'were not shown. A page must prove it speaks for its polity.',
              style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyDirectory extends StatelessWidget {
  const _EmptyDirectory();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 32, 16, 16),
      child: Text(
        'No businesses yet. One will appear when a business near you advertises, '
        'or when someone you know carries a page here.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13),
      ),
    );
  }
}

class _BusinessTile extends StatelessWidget {
  const _BusinessTile({required this.business, required this.service});

  final Business business;
  final PeerService service;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final page = business.page;
    final mySat = service.customerSatisfaction(business.polity);
    final endorsers = business.endorsers.length;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    business.displayName,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                if (standingBadge(service.standingOfCommunity(business.polity) ?? CompactStanding.outside)
                    case final badge?)
                  Chip(
                    key: Key('business-standing-${business.polity}'),
                    visualDensity: VisualDensity.compact,
                    label: Text(badge, style: const TextStyle(fontSize: 11)),
                  ),
                if (mySat != null)
                  Chip(
                    key: const Key('business-my-vouch'),
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.verified_user, size: 16),
                    label: Text('You vouch · $mySat'),
                  ),
              ],
            ),
            if (page != null && page.category.isNotEmpty)
              Text(page.category,
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            if (page != null && page.description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(page.description, style: const TextStyle(fontSize: 13)),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _MetaChip(
                  icon: Icons.place_outlined,
                  // The page's coarse bucket, never coordinates. An unplaced
                  // page says so rather than guessing.
                  label: business.locality.isEmpty
                      ? 'no location on the page'
                      : business.locality,
                ),
                _MetaChip(
                  key: const Key('business-endorsers'),
                  icon: Icons.group_outlined,
                  // The whole distribution story in one number: who carried this
                  // here. Zero is honest, not an error.
                  label: endorsers == 0
                      ? 'no customers vouching yet'
                      : '$endorsers customer${endorsers == 1 ? '' : 's'} vouching',
                ),
                if (page != null && page.contact.isNotEmpty)
                  _MetaChip(icon: Icons.alternate_email, label: page.contact),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (mySat != null)
                  TextButton.icon(
                    key: const Key('business-go-quiet'),
                    icon: const Icon(Icons.volume_off_outlined, size: 18),
                    // Withdrawal is silence: we stop carrying the page. No
                    // negative is published, so there is no "bad review" here.
                    label: const Text('Go quiet'),
                    onPressed: () => service.clearCustomer(business.polity),
                  ),
                TextButton.icon(
                  key: const Key('business-vouch'),
                  icon: const Icon(Icons.storefront_outlined, size: 18),
                  label: Text(mySat == null ? "I'm a customer" : 'Change rating'),
                  onPressed: () => _rate(context, business, service, mySat),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Declare or update our own satisfaction. Choosing a rating is what
  /// authorizes this node to CARRY the page — from then on we re-advertise it in
  /// the first person, with this number attached to our name.
  Future<void> _rate(BuildContext context, Business business,
      PeerService service, int? current) async {
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('How is ${business.displayName}?'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              'Your rating is signed with your name and carried to the people '
              'near you. It is the only way this page travels further.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          for (var sat = 4; sat >= 0; sat--)
            SimpleDialogOption(
              key: Key('business-sat-$sat'),
              onPressed: () => Navigator.of(ctx).pop(sat),
              child: Row(
                children: [
                  for (var i = 0; i <= 4; i++)
                    Icon(i <= sat ? Icons.star : Icons.star_border, size: 18),
                  const SizedBox(width: 8),
                  Text(_satLabel(sat)),
                ],
              ),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    service.markCustomer(business.polity, chosen);
  }

  static String _satLabel(int sat) {
    switch (sat) {
      case 4:
        return 'I send people here';
      case 3:
        return 'Good';
      case 2:
        return 'Fine';
      case 1:
        return 'It exists';
      default:
        return 'I would rather not say much';
    }
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}
