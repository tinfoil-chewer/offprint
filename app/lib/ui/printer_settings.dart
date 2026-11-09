import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/cpnp.dart';
import '../core/direct_wifi.dart';
import '../core/ipp.dart';
import '../core/printer_service.dart';
import 'qr_scan_screen.dart';

Future<void> showPrinterSettings(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _PrinterSettingsDialog());

class _PrinterSettingsDialog extends StatefulWidget {
  const _PrinterSettingsDialog();

  @override
  State<_PrinterSettingsDialog> createState() => _PrinterSettingsDialogState();
}

class _PrinterSettingsDialogState extends State<_PrinterSettingsDialog> {
  late Transport transport = printerService.transport;
  late final hostCtl = TextEditingController(text: printerService.host);
  late final ippCtl = TextEditingController(text: printerService.ippUri == usbIppUri ? '' : printerService.ippUri);
  List<FoundPrinter>? found;
  bool searching = false;

  Future<void> _search() async {
    setState(() => searching = true);
    final r = await discover();
    if (!mounted) return;
    setState(() {
      found = r;
      searching = false;
      if (r.isNotEmpty && hostCtl.text.isEmpty) hostCtl.text = r.first.address;
    });
  }

  @override
  void initState() {
    super.initState();
    if (printerService.host.isEmpty) _search();
  }

  bool joining = false;

  Future<void> _join(PrinterNetwork? net) async {
    if (net == null || !mounted) return;
    setState(() => joining = true);
    try {
      await joinPrinterNetwork(net);
      await printerService.save(transport: Transport.wifi, host: directPrinterAddress);
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Connected directly to ${net.ssid}')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => joining = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _scan() async {
    final net = await Navigator.of(context).push<PrinterNetwork>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    await _join(net);
  }

  Future<void> _enterId() async {
    final id = TextEditingController(), pw = TextEditingController();
    final net = await showDialog<PrinterNetwork>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Printer network'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text("Enter the ID and password shown on the SELPHY's smartphone connection screen."),
          const SizedBox(height: 12),
          TextField(
            controller: id,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Printer ID (6 characters)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(controller: pw, decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(c, PrinterNetwork.fromId(id.text, pw.text)),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    id.dispose();
    pw.dispose();
    await _join(net);
  }

  @override
  void dispose() {
    hostCtl.dispose();
    ippCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final usbAvailable = Platform.isLinux;
    return AlertDialog(
      icon: const Icon(Icons.print_outlined),
      title: const Text('Printer connection'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            RadioGroup<Transport>(
              groupValue: transport,
              onChanged: (v) => setState(() => transport = v!),
              child: Column(children: [
                const RadioListTile(
                  value: Transport.wifi,
                  secondary: Icon(Icons.wifi),
                  title: Text('Wi-Fi'),
                  subtitle: Text('All features: finishes, custom designs, live progress'),
                ),
                RadioListTile(
                  value: Transport.usb,
                  enabled: usbAvailable,
                  secondary: const Icon(Icons.usb),
                  title: const Text('USB cable'),
                  subtitle: Text(usbAvailable ? 'Standard glossy printing via ipp-usb' : 'Coming soon on Android'),
                ),
                const RadioListTile(
                  value: Transport.ippNetwork,
                  secondary: Icon(Icons.lan_outlined),
                  title: Text('Network (IPP)'),
                  subtitle: Text('Standard glossy printing to an IPP address'),
                ),
              ]),
            ),
            const Divider(height: 24),
            if (transport == Transport.wifi && canJoinPrinterNetwork) ...[
              Text('No router? Connect straight to the printer:', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              if (joining)
                const Row(children: [
                  SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Text('Joining printer network…'),
                ])
              else
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.tonalIcon(onPressed: _scan, icon: const Icon(Icons.qr_code_scanner), label: const Text('Scan printer QR code')),
                  TextButton(onPressed: _enterId, child: const Text('Enter ID instead')),
                ]),
              const Divider(height: 24),
            ],
            if (transport == Transport.wifi) ...[
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: hostCtl,
                    decoration: const InputDecoration(labelText: 'Printer IP address', hintText: 'Auto-detect', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                searching
                    ? const Padding(padding: EdgeInsets.all(12), child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                    : TextButton.icon(onPressed: _search, icon: const Icon(Icons.search), label: const Text('Search')),
              ]),
              if (found != null) ...[
                const SizedBox(height: 8),
                if (found!.isEmpty)
                  const Text('No printers answered. Is the SELPHY on the same Wi-Fi network?')
                else
                  for (final p in found!)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.print_outlined),
                      title: Text(p.model),
                      subtitle: Text(p.address),
                      selected: hostCtl.text == p.address,
                      onTap: () => setState(() => hostCtl.text = p.address),
                    ),
              ],
            ],
            if (transport == Transport.ippNetwork)
              TextField(
                controller: ippCtl,
                decoration: const InputDecoration(
                    labelText: 'IPP address', hintText: 'ipp://192.168.1.50/ipp/print', border: OutlineInputBorder()),
              ),
            if (transport == Transport.usb) const Text('Uses ipp://localhost:60000/ipp/print (ipp-usb).'),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            Navigator.pop(context);
            await printerService.save(
              transport: transport,
              host: hostCtl.text,
              ippUri: ippCtl.text.isEmpty ? usbIppUri : ippCtl.text,
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
