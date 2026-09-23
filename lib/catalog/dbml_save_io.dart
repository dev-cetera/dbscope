import 'dart:io';

Future<void> writeDbmlFile(String path, String content) async {
  await File(path).writeAsString(content);
}
