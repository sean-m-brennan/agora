// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Contacts (SOCIAL_APP_PLAN Phase 4, multi-device per person): the people this
// reader added on purpose. Each is one record that may list several devices,
// and is shown once. Adding someone is a link: one of you mints it, the other
// redeems it. A link that crossed face to face can be marked so, which
// verifies at once; any other way, the two compare safety numbers before the
// contact is verified, and only a verified contact's other devices join their
// record.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/address_book.dart';
import '../node/peer_stream.dart';
import 'contact_detail.dart';
import 'my_devices_page.dart';

class ContactsPage extends StatelessWidget {
  const ContactsPage({super.key, required this.service});

  final PeerService service;

  @override
  Widget build(BuildContext context) {
    final s = service;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          IconButton(
            key: const Key('contacts-refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload from this device',
            onPressed: s.refreshBook,
          ),
          IconButton(
            key: const Key('open-my-devices'),
            icon: const Icon(Icons.devices_other),
            tooltip: 'Your devices and backup',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => MyDevicesPage(service: s))),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) {
          final book = s.book;
          final contacts = book.sorted;
          final refusal = book.lastRefusal;
          return ListView(
            children: [
              ListTile(
                key: const Key('contacts-invite'),
                leading: const Icon(Icons.qr_code_2),
                title: const Text('Share a link to add you'),
                subtitle: const Text('Anyone holding it can ask to add you, '
                    'so send it only to the person you mean.'),
                onTap: () {
                  s.createInvitation();
                  showDialog<void>(
                      context: context,
                      builder: (_) => LinkDialog(
                          service: s,
                          title: 'Your link',
                          pick: (b) => b.invitation));
                },
              ),
              ListTile(
                key: const Key('contacts-redeem'),
                leading: const Icon(Icons.person_add_alt_1),
                title: const Text('Add someone from their link'),
                subtitle: const Text('Also how a new device of yours pairs '
                    'with one you already have.'),
                onTap: () => showDialog<void>(
                    context: context, builder: (_) => RedeemDialog(service: s)),
              ),
              if (refusal != null)
                ListTile(
                  key: const Key('contacts-refusal'),
                  leading: const Icon(Icons.error_outline),
                  title: Text(refusalText(refusal.reason)),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      book.lastRefusal = null;
                      s.refreshBook();
                    },
                  ),
                ),
              const Divider(),
              if (!book.loaded)
                const ListTile(title: Text('Reading the address book…')),
              if (book.loaded && contacts.isEmpty)
                const ListTile(
                    title: Text('Nobody yet. Share your link, or redeem theirs.')),
              for (final c in contacts)
                ListTile(
                  key: Key('contact-${c.uuidHex}'),
                  leading: Icon(c.verified ? Icons.verified_user : Icons.person_outline,
                      color: c.verified
                          ? Theme.of(context).colorScheme.primary
                          : null),
                  title: Text(c.label),
                  subtitle: Text([
                    c.verified ? 'verified' : 'not verified yet',
                    if (c.allDevices.length > 1) '${c.allDevices.length} devices',
                    provenanceLabel(c.provenance),
                  ].join(' · ')),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => ContactDetailPage(service: s, contact: c))),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// A link the node mints, shown as it arrives, with a copy button.
class LinkDialog extends StatelessWidget {
  const LinkDialog(
      {super.key, required this.service, required this.title, required this.pick, this.note});

  final PeerService service;
  final String title;
  final String Function(AddressBook) pick;
  final String? note;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(title),
        content: ListenableBuilder(
          listenable: service,
          builder: (context, _) {
            final link = pick(service.book);
            final refusal = service.book.lastRefusal;
            if (link.isEmpty && refusal != null &&
                (refusal.ref == refInvite || refusal.ref == refPairInvite)) {
              return Text(refusalText(refusal.reason));
            }
            if (link.isEmpty) return const Text('Minting…');
            return Column(mainAxisSize: MainAxisSize.min, children: [
              if (note != null) Text(note!),
              const SizedBox(height: 8),
              SelectableText(link,
                  key: const Key('link-text'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            ]);
          },
        ),
        actions: [
          TextButton(
            key: const Key('link-copy'),
            onPressed: () {
              final link = pick(service.book);
              if (link.isEmpty) return;
              Clipboard.setData(ClipboardData(text: link));
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Link copied')));
            },
            child: const Text('Copy'),
          ),
          TextButton(
              onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
        ],
      );
}

/// Paste a link: a contact's, or a pairing link from another device of ours.
class RedeemDialog extends StatefulWidget {
  const RedeemDialog({super.key, required this.service});
  final PeerService service;

  @override
  State<RedeemDialog> createState() => _RedeemDialogState();
}

class _RedeemDialogState extends State<RedeemDialog> {
  final _link = TextEditingController();
  final _name = TextEditingController();
  bool _inPerson = false;

  @override
  void dispose() {
    _link.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Redeem a link'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            key: const Key('redeem-link'),
            controller: _link,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Link (at+contact:…)'),
          ),
          TextField(
            key: const Key('redeem-name'),
            controller: _name,
            decoration:
                const InputDecoration(labelText: 'Your name for them (optional)'),
          ),
          CheckboxListTile(
            key: const Key('redeem-in-person'),
            contentPadding: EdgeInsets.zero,
            value: _inPerson,
            onChanged: (v) => setState(() => _inPerson = v ?? false),
            title: const Text('They handed it to me in person'),
            subtitle: const Text('Only if no one could have changed it on the way. '
                'Otherwise compare safety numbers afterwards.'),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            key: const Key('redeem-go'),
            onPressed: () {
              final rc = widget.service.redeemInvitation(_link.text,
                  inPerson: _inPerson, petname: _name.text);
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(rc == 0
                      ? 'Saying hello… they appear here once it completes.'
                      : 'Could not send (is the node running?)')));
            },
            child: const Text('Add'),
          ),
        ],
      );
}
