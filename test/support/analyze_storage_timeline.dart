import 'dart:convert';
import 'dart:io';

import 'storage_timeline_analysis.dart';

// Local private-artifact tool, not a diagnostic exporter or application API.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError('expected one private stand timeline');
  }
  final lines = await File(arguments.single).readAsLines();
  final records = [
    for (final line in lines)
      Map<String, dynamic>.from(jsonDecode(line) as Map),
  ];
  stdout.writeln(jsonEncode(analyzeStorageTimeline(records)));
}
