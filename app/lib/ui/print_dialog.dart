import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../core/printer_service.dart';

Future<bool?> showPrintDialog(BuildContext context, PrintJob job) => showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PrintDialog(job: job),
    );

class _PrintDialog extends StatefulWidget {
  const _PrintDialog({required this.job});
  final PrintJob job;

  @override
  State<_PrintDialog> createState() => _PrintDialogState();
}

class _PrintDialogState extends State<_PrintDialog> {
  PrintProgress _p = const PrintProgress(PrintPhase.rendering, 'Starting…');
  late final StreamSubscription<PrintProgress> _sub;

  @override
  void initState() {
    super.initState();
    _sub = printerService.print(widget.job).listen((p) => setState(() => _p = p));
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  bool get _finished => _p.phase == PrintPhase.done || _p.phase == PrintPhase.failed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final (icon, color, title) = switch (_p.phase) {
      PrintPhase.rendering => (Icons.auto_fix_high, cs.primary, 'Preparing'),
      PrintPhase.connecting => (Icons.wifi_tethering, cs.primary, 'Connecting'),
      PrintPhase.sending => (Icons.upload, cs.primary, 'Sending'),
      PrintPhase.printing => (Icons.print, cs.primary, 'Printing'),
      PrintPhase.done => (Icons.check_circle, cs.primary, 'Done'),
      PrintPhase.failed => (Icons.error_outline, cs.error, 'Could not print'),
    };
    final job = widget.job;
    return PopScope(
      canPop: _finished,
      child: AlertDialog(
        icon: Icon(icon, color: color),
        title: Text(title),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_p.message, textAlign: TextAlign.center, style: _p.phase == PrintPhase.failed ? TextStyle(color: cs.error) : null),
            const SizedBox(height: 4),
            Text(
              '${job.paper.name} · ${job.hasDesign ? 'Custom design' : job.surface.label}'
              '${_p.sheets > 1 && !_finished ? ' · sheet ${_p.sheet == 0 ? 1 : _p.sheet} of ${_p.sheets}' : ''}',
              textAlign: TextAlign.center,
              style: text.bodySmall,
            ),
            if (!_finished) ...[
              const SizedBox(height: 20),
              LinearProgressIndicator(value: _p.phase == PrintPhase.printing ? null : _p.fraction),
            ],
            if (_p.phase == PrintPhase.printing) ...[
              const SizedBox(height: 12),
              Text('Four passes: yellow, magenta, cyan, then the clear overcoat. Don\'t pull the paper.',
                  textAlign: TextAlign.center, style: text.bodySmall),
            ],
          ]),
        ),
        actions: [
          if (_finished)
            FilledButton(onPressed: () => Navigator.pop(context, _p.phase == PrintPhase.done), child: const Text('Close')),
        ],
      ),
    );
  }
}
