// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// One contact (SOCIAL_APP_PLAN Phase 4): their safety number, verifying it,
// their local name, their devices, and removing them. Both people see the same
// 60 digits; matching them is what makes a contact verified, and only then
// can their other devices join the record.

import 'package:flutter/material.dart';

import '../model/address_book.dart';
import '../node/peer_stream.dart';

class ContactDetailPage extends StatefulWidget {
  const ContactDetailPage({super.key, required this.service, required this.contact});

  final PeerService service;
  final Contact contact;

  @override
  State<ContactDetailPage> createState() => _ContactDetailPageState();
}

class _ContactDetailPageState extends State<ContactDetailPage> {
  final _typed = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.service.requestSafetyNumber(widget.contact);
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  Future<void> _rename(BuildContext context, Contact c) async {
    final ctl = TextEditingController(text: c.label);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your name for them'),
        content: TextField(
            key: const Key('contact-rename-field'), controller: ctl, maxLength: 128),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(ctl.text),
              child: const Text('Save')),
        ],
      ),
    );
    ctl.dispose();
    if (name != null && name.trim().isNotEmpty) widget.service.renameContact(c, name);
  }

  Future<void> _remove(BuildContext context, Contact c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${c.label}?'),
        content: const Text('They leave your address book on every device of '
            'yours, and stop being a direct peer. Adding them again needs a new link.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              key: const Key('contact-remove-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      widget.service.removeContact(c);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final c = s.book.contacts[widget.contact.uuidHex] ?? widget.contact;
        final refusal = s.book.lastRefusal;
        return Scaffold(
          appBar: AppBar(title: Text(c.label), actions: [
            IconButton(
                icon: const Icon(Icons.edit),
                tooltip: 'Rename',
                onPressed: () => _rename(context, c)),
            IconButton(
                key: const Key('contact-remove'),
                icon: const Icon(Icons.person_remove_outlined),
                tooltip: 'Remove',
                onPressed: () => _remove(context, c)),
          ]),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Text(c.verified
                ? 'Verified${c.verifiedAt > 0 ? ' on ${_date(c.verifiedAt)}' : ''}.'
                : 'Not verified yet. Compare this number with the one on their '
                    'screen, in person or over a call you trust.'),
            const SizedBox(height: 12),
            Text('Safety number', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            SelectableText(
              c.safetyNumber.isEmpty ? '…' : c.safetyNumber,
              key: const Key('contact-safety-number'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 16, height: 1.5),
            ),
            if (!c.verified) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('contact-verify-confirm'),
                icon: const Icon(Icons.verified_user),
                label: const Text('They match: mark verified'),
                onPressed: () => s.verifyContact(c, confirmed: true),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('contact-verify-typed'),
                controller: _typed,
                decoration: InputDecoration(
                  labelText: 'Or type the digits from their screen',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.check),
                    onPressed: () =>
                        s.verifyContact(c, presented: _typed.text.trim()),
                  ),
                ),
              ),
              if (refusal != null && refusal.ref == refVerify)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(refusalText(refusal.reason),
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
            ],
            const SizedBox(height: 20),
            Text('Devices', style: Theme.of(context).textTheme.titleSmall),
            for (final d in c.allDevices)
              ListTile(
                dense: true,
                leading: const Icon(Icons.smartphone),
                title: Text(d.substring(0, 12),
                    style: const TextStyle(fontFamily: 'monospace')),
                subtitle: Text(d == c.uuidHex ? 'the device you added' : 'linked by their operator key'),
              ),
            if (!c.verified)
              const Text('Their other devices join here once they are verified.'),
            const SizedBox(height: 12),
            Text('${provenanceLabel(c.provenance)} · added ${_date(c.addedAt)}'),
          ]),
        );
      },
    );
  }

  static String _date(double epoch) => epoch <= 0
      ? '—'
      : DateTime.fromMillisecondsSinceEpoch((epoch * 1000).round())
          .toLocal()
          .toIso8601String()
          .substring(0, 10);
}
