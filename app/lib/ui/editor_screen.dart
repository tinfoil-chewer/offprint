import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/media.dart';
import '../core/models.dart';
import '../core/printer_service.dart';
import 'home_screen.dart';
import '../core/render.dart';
import 'print_dialog.dart';
import 'sheet_preview.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.job});
  final PrintJob job;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> with SingleTickerProviderStateMixin {
  PrintJob get job => widget.job;
  int sheet = 0;
  PhotoSlot? selected;
  bool showDesign = true;
  late final TabController _tabs = TabController(length: 4, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _changed() => setState(() {
        sheet = sheet.clamp(0, job.sheetCount - 1);
        if (selected != null && !job.photos.contains(selected)) selected = null;
      });

  Future<void> _addPhotos() async {
    final more = await pickPhotos(context);
    if (more.isEmpty) return;
    job.photos.addAll(more.map(PhotoSlot.new));
    _changed();
  }

  Future<void> _print() async {
    final ok = await showPrintDialog(context, job);
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Printed. Tear off the tabs along the perforations.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final preview = Padding(
      padding: const EdgeInsets.all(16),
      child: SheetPreview(
        job: job,
        sheet: sheet,
        selected: selected,
        showDesign: showDesign,
        onSelect: (s) => setState(() {
          selected = s;
          if (s != null && _tabs.index == 0) _tabs.animateTo(1);
        }),
        onChanged: _changed,
      ),
    );
    final panels = Column(children: [
      TabBar(controller: _tabs, tabs: const [
        Tab(icon: Icon(Icons.dashboard_outlined), text: 'Layout'),
        Tab(icon: Icon(Icons.tune), text: 'Photo'),
        Tab(icon: Icon(Icons.auto_awesome_outlined), text: 'Finish'),
        Tab(icon: Icon(Icons.text_fields), text: 'Text & QR'),
      ]),
      Expanded(
        child: TabBarView(controller: _tabs, children: [
          _LayoutPanel(job: job, onChanged: _changed, onAddPhotos: _addPhotos),
          _PhotoPanel(job: job, slot: selected, onChanged: _changed),
          _FinishPanel(job: job, onChanged: _changed, showDesign: showDesign, onShowDesign: (v) => setState(() => showDesign = v)),
          _CaptionPanel(job: job, onChanged: _changed),
        ]),
      ),
    ]);

    return Scaffold(
      appBar: AppBar(
        title: Text(job.layout.label),
        actions: const [PrinterStatusButton(), SizedBox(width: 8)],
      ),
      body: wide
          ? Row(children: [
              Expanded(child: ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerLow, child: preview)),
              const VerticalDivider(width: 1),
              SizedBox(width: 400, child: panels),
            ])
          : Column(children: [
              Expanded(flex: 5, child: ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerLow, child: preview)),
              const Divider(height: 1),
              Expanded(flex: 5, child: panels),
            ]),
      bottomNavigationBar: _BottomBar(
        job: job,
        sheet: sheet,
        onSheet: (i) => setState(() => sheet = i),
        onChanged: _changed,
        onPrint: _print,
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.job, required this.sheet, required this.onSheet, required this.onChanged, required this.onPrint});
  final PrintJob job;
  final int sheet;
  final ValueChanged<int> onSheet;
  final VoidCallback onChanged;
  final VoidCallback onPrint;

  @override
  Widget build(BuildContext context) {
    final total = job.sheetCount * job.copies;
    final surface = job.hasDesign ? 'Custom design' : job.surface.label;
    final text = Theme.of(context).textTheme;
    return BottomAppBar(
      height: 72,
      child: Row(children: [
        if (job.sheetCount > 1) ...[
          IconButton(tooltip: 'Previous sheet', onPressed: sheet > 0 ? () => onSheet(sheet - 1) : null, icon: const Icon(Icons.chevron_left)),
          Text('Sheet ${sheet + 1} of ${job.sheetCount}', style: text.bodyMedium),
          IconButton(
            tooltip: 'Next sheet',
            onPressed: sheet < job.sheetCount - 1 ? () => onSheet(sheet + 1) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ] else
          Flexible(
            child: Text(MediaQuery.sizeOf(context).width > 520 ? '${job.paper.name} · $surface' : job.paper.name.split(' ').first,
                overflow: TextOverflow.ellipsis, style: text.bodyMedium),
          ),
        const Spacer(),
        if (MediaQuery.sizeOf(context).width > 520) Text('Copies', style: text.bodyMedium),
        IconButton(
          tooltip: 'Fewer copies',
          onPressed: job.copies > 1 ? () { job.copies--; onChanged(); } : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text('${job.copies}', style: text.titleMedium),
        IconButton(
          tooltip: 'More copies',
          onPressed: job.copies < 99 ? () { job.copies++; onChanged(); } : null,
          icon: const Icon(Icons.add_circle_outline),
        ),
        const SizedBox(width: 8),
        ListenableBuilder(
          listenable: printerService,
          builder: (_, _) => FilledButton.icon(
            onPressed: printerService.busy || job.photos.isEmpty ? null : onPrint,
            icon: const Icon(Icons.print),
            label: Text(total == 1 ? 'Print' : 'Print $total'),
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- helpers

Widget _section(BuildContext context, String title, {String? subtitle}) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        if (subtitle != null) Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      ]),
    );

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({required this.label, required this.value, required this.min, required this.max,
      required this.onChanged, this.format, this.divisions});
  final String label;
  final double value, min, max;
  final ValueChanged<double> onChanged;
  final String Function(double)? format;
  final int? divisions;

  @override
  Widget build(BuildContext context) {
    final text = format?.call(value) ?? value.toStringAsFixed(1);
    return Row(children: [
      SizedBox(width: 92, child: Text(label)),
      Expanded(
        child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, label: text, onChanged: onChanged),
      ),
      SizedBox(width: 56, child: Text(text, textAlign: TextAlign.end)),
    ]);
  }
}

class _SpotPicker extends StatelessWidget {
  const _SpotPicker({required this.value, required this.onChanged});
  final TextSpot value;
  final ValueChanged<TextSpot> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 96,
      height: 96,
      child: GridView.count(
        crossAxisCount: 3,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        children: [
          for (final s in TextSpot.values)
            InkWell(
              onTap: () => onChanged(s),
              borderRadius: BorderRadius.circular(4),
              child: Container(
                decoration: BoxDecoration(
                  color: s == value ? cs.primary : cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _mm(double v) => v == 0 ? 'none' : '${v.toStringAsFixed(1)} mm';
String _pct(double v) => '${(v * 100).round()}';

// ---------------------------------------------------------------- Layout

class _LayoutPanel extends StatelessWidget {
  const _LayoutPanel({required this.job, required this.onChanged, required this.onAddPhotos});
  final PrintJob job;
  final VoidCallback onChanged;
  final VoidCallback onAddPhotos;

  static const _backgrounds = [
    Color(0xFFFFFFFF), Color(0xFF111111), Color(0xFFF4EBDD), Color(0xFFF7D6E0), Color(0xFFD5E8F5), Color(0xFFDCE8D2),
  ];

  @override
  Widget build(BuildContext context) {
    final ink = printerService.info.idle?.inkCassette;
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), children: [
      _section(context, 'Paper', subtitle: ink == null ? null : 'Loaded ink cassette: ${printerService.info.idle!.inkName}'),
      SegmentedButton<Paper>(
        showSelectedIcon: false,
        segments: [for (final p in Paper.all) ButtonSegment(value: p, label: Text(p.name.split(' ').first))],
        selected: {job.paper},
        onSelectionChanged: (s) {
          job.paper = s.first;
          for (final p in job.photos) {
            p.pan = Offset.zero;
          }
          onChanged();
        },
      ),
      _section(context, 'Layout'),
      Wrap(spacing: 8, runSpacing: 4, children: [
        for (final k in LayoutKind.values)
          ChoiceChip(
            avatar: Icon(layoutIcon(k), size: 18),
            label: Text(k.label),
            selected: job.layout == k,
            onSelected: (_) {
              job.layout = k;
              onChanged();
            },
          ),
      ]),
      _section(context, 'Spacing'),
      _LabeledSlider(
        label: 'Border', value: job.borderMm, min: 0, max: 12, divisions: 24, format: _mm,
        onChanged: (v) { job.borderMm = v; onChanged(); },
      ),
      if (job.layout != LayoutKind.single)
        _LabeledSlider(
          label: 'Gap', value: job.gapMm, min: 0, max: 8, divisions: 16, format: _mm,
          onChanged: (v) { job.gapMm = v; onChanged(); },
        ),
      _section(context, 'Background'),
      Wrap(spacing: 10, children: [
        for (final c in _backgrounds)
          InkWell(
            onTap: () { job.background = c; onChanged(); },
            customBorder: const CircleBorder(),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(
                  color: job.background == c ? Theme.of(context).colorScheme.primary : Colors.grey,
                  width: job.background == c ? 3 : 1,
                ),
              ),
            ),
          ),
      ]),
      _section(context, 'Photos', subtitle: '${job.photos.length} photo(s) on ${job.sheetCount} sheet(s)'),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(onPressed: onAddPhotos, icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('Add photos')),
      ),
      const SizedBox(height: 16),
    ]);
  }
}

// ---------------------------------------------------------------- Photo

class _PhotoPanel extends StatelessWidget {
  const _PhotoPanel({required this.job, required this.slot, required this.onChanged});
  final PrintJob job;
  final PhotoSlot? slot;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final s = slot;
    if (s == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Tap a photo in the preview to adjust it.\nDrag to reposition, pinch or scroll to zoom.', textAlign: TextAlign.center),
        ),
      );
    }
    final a = s.adjust;
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), children: [
      _section(context, s.source.name),
      Wrap(spacing: 4, children: [
        IconButton.filledTonal(tooltip: 'Rotate left', onPressed: () { s.quarterTurns = (s.quarterTurns + 3) % 4; s.pan = Offset.zero; onChanged(); }, icon: const Icon(Icons.rotate_left)),
        IconButton.filledTonal(tooltip: 'Rotate right', onPressed: () { s.quarterTurns = (s.quarterTurns + 1) % 4; s.pan = Offset.zero; onChanged(); }, icon: const Icon(Icons.rotate_right)),
        IconButton.filledTonal(tooltip: 'Reset position', onPressed: () { s.reset(); onChanged(); }, icon: const Icon(Icons.center_focus_strong_outlined)),
        IconButton.filledTonal(
          tooltip: 'Replace photo',
          onPressed: () async {
            final r = await pickPhotos(context, multiple: false);
            if (r.isEmpty) return;
            s.source = r.first;
            s.reset();
            onChanged();
          },
          icon: const Icon(Icons.swap_horiz),
        ),
        IconButton.filledTonal(
          tooltip: 'Remove from print',
          onPressed: job.photos.length > 1 ? () { job.photos.remove(s); onChanged(); } : null,
          icon: const Icon(Icons.delete_outline),
        ),
      ]),
      _LabeledSlider(label: 'Zoom', value: s.zoom, min: 1, max: 6, format: (v) => '${v.toStringAsFixed(1)}×',
          onChanged: (v) { s.zoom = v; onChanged(); }),
      _section(context, 'Adjust'),
      _LabeledSlider(label: 'Brightness', value: a.brightness, min: -1, max: 1, format: _pct, onChanged: (v) { a.brightness = v; onChanged(); }),
      _LabeledSlider(label: 'Contrast', value: a.contrast, min: -1, max: 1, format: _pct, onChanged: (v) { a.contrast = v; onChanged(); }),
      _LabeledSlider(label: 'Saturation', value: a.saturation, min: -1, max: 1, format: _pct, onChanged: (v) { a.saturation = v; onChanged(); }),
      _LabeledSlider(label: 'Warmth', value: a.warmth, min: -1, max: 1, format: _pct, onChanged: (v) { a.warmth = v; onChanged(); }),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Black & white'),
        value: a.blackAndWhite,
        onChanged: (v) { a.blackAndWhite = v; onChanged(); },
      ),
      Wrap(spacing: 8, children: [
        TextButton(
          onPressed: () {
            a..brightness = 0..contrast = 0..saturation = 0..warmth = 0..blackAndWhite = false;
            onChanged();
          },
          child: const Text('Reset adjustments'),
        ),
        TextButton(
          onPressed: () {
            for (final o in job.photos) {
              o.adjust
                ..brightness = a.brightness
                ..contrast = a.contrast
                ..saturation = a.saturation
                ..warmth = a.warmth
                ..blackAndWhite = a.blackAndWhite;
            }
            onChanged();
          },
          child: const Text('Apply to all photos'),
        ),
      ]),
      const SizedBox(height: 16),
    ]);
  }
}

// ---------------------------------------------------------------- Finish

class _FinishPanel extends StatelessWidget {
  const _FinishPanel({required this.job, required this.onChanged, required this.showDesign, required this.onShowDesign});
  final PrintJob job;
  final VoidCallback onChanged;
  final bool showDesign;
  final ValueChanged<bool> onShowDesign;

  static const _descriptions = {
    Surface.gloss: 'Classic shiny photo finish.',
    Surface.semiGloss: 'Softer sheen, fewer reflections.',
    Surface.satin: 'Fine textured, low-glare finish.',
    Surface.design: 'Your own design pressed into the clear coat: it appears as matte texture '
        'on a glossy print. Replaces the finish above.',
  };

  @override
  Widget build(BuildContext context) {
    final d = job.design;
    final wifi = printerService.transport == Transport.wifi;
    final cs = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), children: [
      _section(context, 'Surface'),
      SegmentedButton<Surface>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: Surface.gloss, label: Text('Gloss')),
          ButtonSegment(value: Surface.semiGloss, label: Text('Semi')),
          ButtonSegment(value: Surface.satin, label: Text('Satin')),
          ButtonSegment(value: Surface.design, label: Text('Design')),
        ],
        selected: {job.surface},
        onSelectionChanged: (s) { job.surface = s.first; onChanged(); },
      ),
      const SizedBox(height: 8),
      Text(_descriptions[job.surface]!, style: Theme.of(context).textTheme.bodySmall),
      if (!wifi && job.surface != Surface.gloss)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('Finishes and designs need the Wi-Fi connection; USB/IPP prints glossy.',
              style: TextStyle(color: cs.error, fontSize: 12)),
        ),
      if (job.surface == Surface.design) ...[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Show design in preview'),
          value: showDesign,
          onChanged: onShowDesign,
        ),
        _section(context, 'Text'),
        _SyncedTextField(
          value: d.text,
          decoration: const InputDecoration(hintText: 'e.g. names, a date, a message', border: OutlineInputBorder(), isDense: true),
          onChanged: (v) { d.text = v; onChanged(); },
        ),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
            child: _LabeledSlider(label: 'Size', value: d.textSizeMm, min: 3, max: 30, format: (v) => '${v.round()} mm',
                onChanged: (v) { d.textSizeMm = v; onChanged(); }),
          ),
          const SizedBox(width: 8),
          _SpotPicker(value: d.textSpot, onChanged: (s) { d.textSpot = s; onChanged(); }),
        ]),
        _section(context, 'Texture'),
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final p in Pattern.values)
            ChoiceChip(
              label: Text(p == Pattern.none ? 'None' : p.name[0].toUpperCase() + p.name.substring(1)),
              selected: d.pattern == p,
              onSelected: (_) { d.pattern = p; onChanged(); },
            ),
        ]),
        if (d.pattern != Pattern.none)
          _LabeledSlider(label: 'Spacing', value: d.patternSpacingMm, min: 1.5, max: 8, format: _mm,
              onChanged: (v) { d.patternSpacingMm = v; onChanged(); }),
        _LabeledSlider(label: 'Frame', value: d.frameMm, min: 0, max: 15, divisions: 30, format: _mm,
            onChanged: (v) { d.frameMm = v; onChanged(); }),
        _section(context, 'Logo or signature', subtitle: 'Dark parts of the image become texture'),
        Row(children: [
          OutlinedButton.icon(
            onPressed: () async {
              final r = await pickPhotos(context, multiple: false);
              if (r.isEmpty) return;
              d.logo = r.first.image;
              d.logoPath = r.first.path;
              onChanged();
            },
            icon: const Icon(Icons.draw_outlined),
            label: Text(d.logo == null ? 'Choose image' : 'Change'),
          ),
          if (d.logo != null)
            TextButton(onPressed: () { d.logo = null; d.logoPath = null; onChanged(); }, child: const Text('Remove')),
        ]),
        if (d.logo != null)
          Row(children: [
            Expanded(
              child: _LabeledSlider(label: 'Size', value: d.logoScale, min: 0.1, max: 1, format: (v) => '${(v * 100).round()}%',
                  onChanged: (v) { d.logoScale = v; onChanged(); }),
            ),
            const SizedBox(width: 8),
            _SpotPicker(value: d.logoSpot, onChanged: (s) { d.logoSpot = s; onChanged(); }),
          ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Invert'),
          subtitle: const Text('Texture everywhere except the design'),
          value: d.invert,
          onChanged: (v) { d.invert = v; onChanged(); },
        ),
      ],
      if (wifi) ...[
        const Divider(height: 32),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Printer auto-correct'),
          subtitle: const Text("Let the SELPHY optimise each image"),
          value: job.autoCorrect,
          onChanged: (v) { job.autoCorrect = v; onChanged(); },
        ),
      ],
      const SizedBox(height: 16),
    ]);
  }
}

// ---------------------------------------------------------------- Caption

class _CaptionPanel extends StatelessWidget {
  const _CaptionPanel({required this.job, required this.onChanged});
  final PrintJob job;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final c = job.caption;
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), children: [
      _section(context, 'Caption', subtitle: 'Printed in colour on every sheet'),
      _SyncedTextField(
        value: c.text,
        decoration: InputDecoration(
          hintText: 'e.g. Lisbon · June 2026',
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: IconButton(
            tooltip: "Insert today's date",
            icon: const Icon(Icons.today_outlined),
            onPressed: () {
              final now = DateTime.now();
              c.text = '${c.text}${c.text.isEmpty ? '' : ' · '}${MaterialLocalizations.of(context).formatMediumDate(now)}';
              onChanged();
            },
          ),
        ),
        onChanged: (v) { c.text = v; onChanged(); },
      ),
      Row(children: [
        Expanded(
          child: _LabeledSlider(label: 'Size', value: c.sizeMm, min: 2, max: 20, format: (v) => '${v.toStringAsFixed(1)} mm',
              onChanged: (v) { c.sizeMm = v; onChanged(); }),
        ),
        const SizedBox(width: 8),
        _SpotPicker(value: c.spot, onChanged: (s) { c.spot = s; onChanged(); }),
      ]),
      _section(context, 'Colour'),
      Wrap(spacing: 10, children: [
        for (final col in const [Color(0xFFFFFFFF), Color(0xFF111111), Color(0xFFB0306A), Color(0xFFE8B04A), Color(0xFF2F6FB0)])
          InkWell(
            onTap: () { c.color = col; onChanged(); },
            customBorder: const CircleBorder(),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: col,
                shape: BoxShape.circle,
                border: Border.all(color: c.color == col ? Theme.of(context).colorScheme.primary : Colors.grey, width: c.color == col ? 3 : 1),
              ),
            ),
          ),
      ]),
      const Divider(height: 32),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: const Icon(Icons.qr_code_2),
        title: const Text('QR code'),
        subtitle: const Text('A link, message or Wi-Fi details, printed on every sheet'),
        value: job.qr.enabled,
        onChanged: (v) { job.qr.enabled = v; onChanged(); },
      ),
      if (job.qr.enabled) ...[
        _SyncedTextField(
          value: job.qr.content,
          decoration: InputDecoration(
            hintText: 'https://… or any text',
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: IconButton(
              tooltip: 'Wi-Fi network…',
              icon: const Icon(Icons.wifi),
              onPressed: () async {
                final v = await _wifiQrDialog(context);
                if (v != null) { job.qr.content = v; onChanged(); }
              },
            ),
          ),
          onChanged: (v) { job.qr.content = v; onChanged(); },
        ),
        if (job.qr.content.trim().isNotEmpty && buildQr(job.qr.content.trim()) == null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Too long for a QR code.', style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
          ),
        Row(children: [
          Expanded(
            child: _LabeledSlider(label: 'Size', value: job.qr.sizeMm, min: 12, max: 45, format: (v) => '${v.round()} mm',
                onChanged: (v) { job.qr.sizeMm = v; onChanged(); }),
          ),
          const SizedBox(width: 8),
          _SpotPicker(value: job.qr.spot, onChanged: (s) { job.qr.spot = s; onChanged(); }),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('White background'),
          subtitle: const Text('Keeps it scannable on busy photos'),
          value: job.qr.whiteBackground,
          onChanged: (v) { job.qr.whiteBackground = v; onChanged(); },
        ),
      ],
      const SizedBox(height: 16),
    ]);
  }
}

/// Text field that keeps its controller (and cursor) across rebuilds, but
/// picks up external changes such as "insert date".
class _SyncedTextField extends StatefulWidget {
  const _SyncedTextField({required this.value, required this.onChanged, this.decoration});
  final String value;
  final ValueChanged<String> onChanged;
  final InputDecoration? decoration;

  @override
  State<_SyncedTextField> createState() => _SyncedTextFieldState();
}

class _SyncedTextFieldState extends State<_SyncedTextField> {
  late final _ctl = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(covariant _SyncedTextField old) {
    super.didUpdateWidget(old);
    if (widget.value != _ctl.text) {
      _ctl.value = TextEditingValue(text: widget.value, selection: TextSelection.collapsed(offset: widget.value.length));
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TextField(controller: _ctl, minLines: 1, maxLines: 3, decoration: widget.decoration, onChanged: widget.onChanged);
}

/// Builds a standard Wi-Fi QR payload (phones offer to join when scanned).
Future<String?> _wifiQrDialog(BuildContext context) async {
  final ssid = TextEditingController(), pw = TextEditingController();
  final r = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.wifi),
      title: const Text('Wi-Fi QR code'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: ssid, decoration: const InputDecoration(labelText: 'Network name', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(controller: pw, decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder())),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            String esc(String v) => v.replaceAllMapped(RegExp(r'([\\;,:"])'), (m) => '\\${m[1]}');
            final p = pw.text;
            Navigator.pop(c, p.isEmpty ? 'WIFI:T:nopass;S:${esc(ssid.text)};;' : 'WIFI:T:WPA;S:${esc(ssid.text)};P:${esc(p)};;');
          },
          child: const Text('Use'),
        ),
      ],
    ),
  );
  ssid.dispose();
  pw.dispose();
  return r;
}
