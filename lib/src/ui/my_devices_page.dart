// Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
//
// Your devices (SOCIAL_APP_PLAN Phase 4, multi-device per person). Each device
// is its own node with its own keys. What makes them one person is a device
// cert from your operator key, issued out of band with AutonomousTrust's
// tools/device_cert.py. The key itself never reaches Agora. Two devices with
// certs from the same key can pair; after that their address books stay in
// step, and your contacts see the new device as you. A backup, sealed with a
// passphrase, brings the address book to a new device when the old one is gone.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ffi/at_events_bindings.dart';
import '../model/address_book.dart';
import '../model/device_cert.dart';
import '../node/peer_stream.dart';
import 'contacts_page.dart';

class MyDevicesPage extends StatelessWidget {
  const MyDevicesPage({super.key, required this.service});

  final PeerService service;

  @override
  Widget build(BuildContext context) {
    final s = service;
    return Scaffold(
      appBar: AppBar(title: const Text('Your devices')),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) {
          final cert = s.deviceCert;
          final certified = cert.state == DeviceCertState.ours;
          final siblings = s.book.siblings.values.toList();
          final backup = s.book.lastBackup;
          return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
            _CertTile(service: s, cert: cert),
            const Divider(),
            ListTile(
              key: const Key('devices-pair'),
              enabled: certified,
              leading: const Icon(Icons.add_to_home_screen),
              title: const Text('Pair a new device'),
              subtitle: Text(certified
                  ? 'Shows a link. On the new device, open Contacts → "Add someone '
                      'from their link" and paste it there.'
                  : 'Needs a device cert on this device first.'),
              onTap: certified
                  ? () {
                      s.createPairInvitation();
                      showDialog<void>(
                          context: context,
                          builder: (_) => LinkDialog(
                              service: s,
                              title: 'Pairing link',
                              note: 'Only for your own devices: the pairing '
                                  'succeeds only if the other device has a cert '
                                  'from the same operator key.',
                              pick: (b) => b.pairInvitation));
                    }
                  : null,
            ),
            if (s.book.lastPaired != null)
              ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: Text('Paired with ${s.book.lastPaired!.nickname}'),
                subtitle: const Text('Your address books are now in step.'),
              ),
            if (s.book.lastRefusal?.reason == atFcReasonNotSibling)
              ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(refusalText(atFcReasonNotSibling)),
              ),
            if (siblings.isNotEmpty) const _Heading('Paired with'),
            for (final d in siblings)
              ListTile(
                key: Key('sibling-${d.uuidHex}'),
                leading: const Icon(Icons.devices),
                title: Text(d.nickname.isEmpty ? d.uuidHex.substring(0, 12) : d.nickname),
                subtitle: Text(d.uuidHex.substring(0, 12),
                    style: const TextStyle(fontFamily: 'monospace')),
                trailing: TextButton(
                  onPressed: () => s.removeSibling(d),
                  child: const Text('Unpair here'),
                ),
              ),
            const Divider(),
            const _Heading('Backup'),
            ListTile(
              key: const Key('devices-backup-export'),
              leading: const Icon(Icons.save_alt),
              title: const Text('Make a backup'),
              subtitle: const Text('Your address book and paired devices, sealed '
                  'with a passphrase. Keep the file and the passphrase apart.'),
              onTap: () => showDialog<void>(
                  context: context, builder: (_) => _ExportDialog(service: s)),
            ),
            ListTile(
              key: const Key('devices-backup-import'),
              leading: const Icon(Icons.restore),
              title: const Text('Restore a backup'),
              subtitle: const Text('Contacts stay verified. Pair again with your '
                  'other devices to resume keeping them in step.'),
              onTap: () => showDialog<void>(
                  context: context, builder: (_) => _ImportDialog(service: s)),
            ),
            if (backup != null) _BackupOutcomeTile(outcome: backup),
            const Divider(),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Lost a device? On the new one: restore your operator key '
                '(tools/backup.py restore-key), issue this device a cert '
                '(tools/device_cert.py issue), restart Agora, then restore the '
                'backup here.',
              ),
            ),
          ]);
        },
      ),
    );
  }
}

class _CertTile extends StatelessWidget {
  const _CertTile({required this.service, required this.cert});
  final PeerService service;
  final DeviceCertStatus cert;

  @override
  Widget build(BuildContext context) {
    final cmd = DeviceCertStatus.issueCommand(service.root);
    final (icon, title, body) = switch (cert.state) {
      DeviceCertState.ours => (
          Icons.verified,
          'This device has a cert',
          'Operator key ${cert.operatorShort}. Your verified contacts file this '
              'device under you.'
        ),
      DeviceCertState.none => (
          Icons.help_outline,
          'No device cert',
          'Without one this device is a person of its own: it cannot pair, and '
              'your contacts cannot tell it is you. Stop Agora, run this from an '
              'AutonomousTrust checkout where your operator keystore is, then '
              'start Agora again:'
        ),
      DeviceCertState.foreign => (
          Icons.warning_amber,
          'The cert names another device',
          'The node ignores it. Issue this device its own:'
        ),
      DeviceCertState.unreadable => (
          Icons.warning_amber,
          'The cert file is not readable',
          'Issue this device a new one:'
        ),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ListTile(
        key: const Key('devices-cert'),
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(body),
        trailing: IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Check again',
          onPressed: service.reloadDeviceCert,
        ),
      ),
      if (cert.state != DeviceCertState.ours)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(
              child: SelectableText(cmd,
                  key: const Key('devices-cert-command'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
            IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () => Clipboard.setData(ClipboardData(text: cmd)),
            ),
          ]),
        ),
    ]);
  }
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.service});
  final PeerService service;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late final _path = TextEditingController(text: widget.service.defaultBackupPath());
  final _pass = TextEditingController();
  bool _generate = true;

  @override
  void dispose() {
    _path.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final weak = !_generate && _pass.text.length < 12;
    return AlertDialog(
      title: const Text('Make a backup'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
            key: const Key('backup-path'),
            controller: _path,
            decoration: const InputDecoration(labelText: 'File (absolute path)')),
        SwitchListTile(
          key: const Key('backup-generate'),
          contentPadding: EdgeInsets.zero,
          value: _generate,
          onChanged: (v) => setState(() => _generate = v),
          title: const Text('Make a passphrase for me'),
          subtitle: const Text('Shown once. Write it down.'),
        ),
        if (!_generate)
          TextField(
            key: const Key('backup-passphrase'),
            controller: _pass,
            obscureText: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: 'Passphrase (12 characters or more)',
                errorText: _pass.text.isNotEmpty && weak ? 'Too short' : null),
          ),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('backup-export-go'),
          onPressed: weak
              ? null
              : () {
                  final path = _path.text.trim();
                  // The node writes the file; make sure its folder exists.
                  try {
                    File(path).parent.createSync(recursive: true);
                  } on FileSystemException {
                    // The node's refusal ("io") says so if it matters.
                  }
                  widget.service.exportBackup(path,
                      passphrase: _generate ? null : _pass.text);
                  Navigator.of(context).pop();
                },
          child: const Text('Make backup'),
        ),
      ],
    );
  }
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.service});
  final PeerService service;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _path = TextEditingController();
  final _pass = TextEditingController();

  @override
  void dispose() {
    _path.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Restore a backup'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              key: const Key('restore-path'),
              controller: _path,
              decoration: const InputDecoration(labelText: 'Backup file (absolute path)')),
          TextField(
              key: const Key('restore-passphrase'),
              controller: _pass,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Passphrase')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            key: const Key('backup-import-go'),
            onPressed: () {
              widget.service.importBackup(_path.text.trim(), _pass.text);
              Navigator.of(context).pop();
            },
            child: const Text('Restore'),
          ),
        ],
      );
}

class _BackupOutcomeTile extends StatelessWidget {
  const _BackupOutcomeTile({required this.outcome});
  final BackupOutcome outcome;

  @override
  Widget build(BuildContext context) {
    if (outcome.refused) {
      return ListTile(
        key: const Key('backup-outcome'),
        leading: const Icon(Icons.error_outline),
        title: Text(backupRefusalText(outcome.reason)),
      );
    }
    if (outcome.kind == atBackupRestored) {
      return ListTile(
        key: const Key('backup-outcome'),
        leading: const Icon(Icons.check_circle_outline),
        title: const Text('Restored'),
        subtitle: Text('${outcome.added} added, ${outcome.updated} updated, '
            '${outcome.removed} removed; ${outcome.contacts} contacts now, '
            '${outcome.siblings} paired devices added.'),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ListTile(
        key: const Key('backup-outcome'),
        leading: const Icon(Icons.check_circle_outline),
        title: const Text('Backup written'),
        subtitle: Text('${outcome.path}\n${outcome.contacts} contacts, '
            '${outcome.siblings} paired devices.'),
      ),
      if (outcome.passphrase.isNotEmpty)
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Your passphrase. It is shown once and stored nowhere.'),
              const SizedBox(height: 8),
              SelectableText(outcome.passphrase,
                  key: const Key('backup-passphrase-shown'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 18)),
            ]),
          ),
        ),
    ]);
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}
