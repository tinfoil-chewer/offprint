import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'core/models.dart';
import 'core/printer_service.dart';
import 'core/render.dart';

/// Single app-wide printer service.
final printerService = PrinterService();

final _picker = ImagePicker();

/// Lets the user pick photos and decodes them (with a progress dialog).
Future<List<PhotoSource>> pickPhotos(BuildContext context, {bool multiple = true}) async {
  final files = multiple
      ? await _picker.pickMultiImage(requestFullMetadata: false)
      : [?await _picker.pickImage(source: ImageSource.gallery, requestFullMetadata: false)];
  if (files.isEmpty || !context.mounted) return [];

  final progress = ValueNotifier(0);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      content: ValueListenableBuilder(
        valueListenable: progress,
        builder: (_, n, _) => Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Text('Loading photo ${n + 1} of ${files.length}…'),
        ]),
      ),
    ),
  );
  final out = <PhotoSource>[];
  final failed = <String>[];
  for (final f in files) {
    try {
      out.add(PhotoSource(f.path, await loadPhoto(await f.readAsBytes())));
    } catch (_) {
      failed.add(f.name);
    }
    progress.value++;
  }
  if (context.mounted) {
    Navigator.of(context).pop();
    if (failed.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open: ${failed.join(', ')}')));
    }
  }
  return out;
}
