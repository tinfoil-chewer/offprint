import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../core/printer_service.dart';
import 'editor_screen.dart';
import 'printer_settings.dart';

IconData layoutIcon(LayoutKind k) => switch (k) {
      LayoutKind.single => Icons.crop_portrait,
      LayoutKind.grid2 => Icons.view_agenda_outlined,
      LayoutKind.grid4 => Icons.grid_view,
      LayoutKind.mini8 => Icons.apps,
      LayoutKind.strips => Icons.view_column_outlined,
    };

bool printerOk(PrinterService s) => s.info.online && !(s.info.idle?.hasError ?? false);

String statusLine(PrinterService s) => [
      s.busy ? 'Printing' : s.info.summary,
      switch (s.transport) { Transport.wifi => 'Wi-Fi', Transport.usb => 'USB', Transport.ippNetwork => 'IPP' },
      if (s.info.idle != null) '${s.info.idle!.inkName} ink',
    ].join(' · ');

/// App-bar action showing printer status; opens printer settings.
class PrinterStatusButton extends StatelessWidget {
  const PrinterStatusButton({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: printerService,
        builder: (context, _) {
          final s = printerService;
          final cs = Theme.of(context).colorScheme;
          return Tooltip(
            message: statusLine(s),
            child: ActionChip(
              avatar: Icon(printerOk(s) ? Icons.print : Icons.print_disabled, size: 18, color: printerOk(s) ? cs.primary : cs.error),
              label: Text(s.busy ? 'Printing…' : s.info.summary),
              onPressed: () => showPrinterSettings(context),
            ),
          );
        },
      );
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static Future<void> start(BuildContext context, LayoutKind layout) async {
    final photos = await pickPhotos(context);
    if (photos.isEmpty || !context.mounted) return;
    final job = PrintJob(photos: photos.map(PhotoSlot.new).toList(), layout: layout);
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EditorScreen(job: job)));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Offprint'),
        actions: [
          const PrinterStatusButton(),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'about') showOffprintAbout(context);
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'about', child: Text('About Offprint'))],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => start(context, LayoutKind.single),
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: const Text('New print'),
      ),
      body: ListenableBuilder(
        listenable: printerService,
        builder: (context, _) {
          final s = printerService;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: [
                  Card.outlined(
                    child: ListTile(
                      contentPadding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                      leading: Icon(printerOk(s) ? Icons.print : Icons.print_disabled, color: printerOk(s) ? cs.primary : cs.error),
                      title: Text('SELPHY · ${s.busy ? 'Printing' : s.info.summary}'),
                      subtitle: Text(
                        [s.transport.label, if (s.info.detail.isNotEmpty) s.info.detail].join('\n'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: s.refresh),
                        IconButton(
                          tooltip: 'Printer settings',
                          icon: const Icon(Icons.settings_outlined),
                          onPressed: () => showPrinterSettings(context),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('Layouts', style: text.titleMedium),
                  const SizedBox(height: 8),
                  LayoutBuilder(builder: (context, c) {
                    final cols = (c.maxWidth / 200).floor().clamp(2, 5);
                    return GridView.count(
                      crossAxisCount: cols,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1.25,
                      children: [
                        for (final k in LayoutKind.values)
                          Card.filled(
                            margin: EdgeInsets.zero,
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () => start(context, k),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Icon(layoutIcon(k), size: 32, color: cs.primary),
                                  const Spacer(),
                                  Text(k.label, style: text.titleSmall),
                                  const SizedBox(height: 2),
                                  Text(k.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                                ]),
                              ),
                            ),
                          ),
                      ],
                    );
                  }),
                  const SizedBox(height: 24),
                  Row(children: [
                    Text('Recent prints', style: text.titleMedium),
                    const Spacer(),
                    if (s.history.isNotEmpty) ...[
                      Text('${s.totalSheets} sheets', style: text.bodySmall),
                      IconButton(
                        tooltip: 'Clear history',
                        icon: const Icon(Icons.delete_sweep_outlined),
                        onPressed: () => _confirmClear(context),
                      ),
                    ],
                  ]),
                  const SizedBox(height: 8),
                  if (s.history.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text('Nothing printed yet.', textAlign: TextAlign.center, style: TextStyle(color: cs.outline)),
                    )
                  else
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final h in s.history.take(30))
                        SizedBox(
                          width: 128,
                          child: Card.outlined(
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                SizedBox(
                                  height: 140,
                                  child: Center(
                                    child: Image.file(File(h.thumb), fit: BoxFit.contain,
                                        errorBuilder: (_, _, _) => Icon(Icons.image_not_supported_outlined, color: cs.outline)),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(MaterialLocalizations.of(context).formatShortDate(h.time), style: text.labelMedium),
                                Text(h.sheets > 1 ? '${h.surface} · ×${h.sheets}' : h.surface,
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                              ]),
                            ),
                          ),
                        ),
                    ]),
                  const SizedBox(height: 24),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.lock_outline, size: 14, color: cs.outline),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text('Everything stays on this device. No accounts, no cloud, no analytics.',
                          style: text.bodySmall?.copyWith(color: cs.outline)),
                    ),
                  ]),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Clear print history?'),
        content: const Text('Removes the local list and thumbnails. Your photos are not touched.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) await printerService.clearHistory();
  }
}

const appVersion = '0.1.0';

void showOffprintAbout(BuildContext context) => showAboutDialog(
      context: context,
      applicationName: 'Offprint',
      applicationVersion: appVersion,
      applicationIcon: Image.asset('assets/icon/offprint.png', width: 48, height: 48),
      applicationLegalese: 'Copyright © 2026 Offprint contributors\nLicensed under the GNU GPL v3.0',
      children: const [
        SizedBox(height: 16),
        Text('Offline photo printing for Canon SELPHY printers. No accounts, no cloud, no analytics.'),
        SizedBox(height: 12),
        Text('Offprint is an independent project and is not affiliated with, endorsed by or supported by Canon Inc. '
            'Canon and SELPHY are trademarks of Canon Inc.'),
      ],
    );
