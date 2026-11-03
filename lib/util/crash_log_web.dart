// Web: there is no file to write. The entry already went to the browser
// console through debugPrint, which is where a web user looks.

/// Where [appendCrashLog] writes, or null when it writes nowhere.
String? crashLogPath() => null;

void appendCrashLog(String entry) {}
