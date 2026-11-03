part of '../column_input.dart';

class _DateInput extends StatefulWidget {
  const _DateInput({
    required this.value,
    required this.enabled,
    required this.mode,
    required this.onChanged,
    this.focusNode,
  });
  final String? value;
  final bool enabled;
  final CupertinoDatePickerMode mode;
  final ValueChanged<Object?> onChanged;
  final FocusNode? focusNode;

  @override
  State<_DateInput> createState() => _DateInputState();
}

class _DateInputState extends State<_DateInput> {
  static final _firstDate = DateTime(1);
  static final _lastDate = DateTime(9999, 12, 31);

  String _format(DateTime dt) {
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    switch (widget.mode) {
      case CupertinoDatePickerMode.date:
        return '$year-$month-$day';
      case CupertinoDatePickerMode.time:
        return '$hour:$minute:$second';
      case CupertinoDatePickerMode.dateAndTime:
        return '$year-$month-$day $hour:$minute:$second';
      case CupertinoDatePickerMode.monthYear:
        return '$year-$month';
    }
  }

  /// The picker's starting point: the wall-clock fields exactly as the
  /// cell text spells them (no zone conversion, so a `timestamptz` shows the
  /// hour the cell shows), or now when the cell is empty or unparseable.
  DateTime _seed() => _parseWallClock(widget.value) ?? DateTime.now();

  static final _dateTimeRe = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{1,2}):(\d{2})(.*))?$',
  );
  static final _timeRe = RegExp(r'^(\d{1,2}):(\d{2})(.*)$');

  DateTime? _parseWallClock(String? raw) {
    if (raw == null) return null;
    final text = raw.trim();
    if (widget.mode == CupertinoDatePickerMode.time) {
      final m = _timeRe.firstMatch(text);
      if (m == null) return null;
      return DateTime(0, 1, 1, int.parse(m[1]!), int.parse(m[2]!));
    }
    final m = _dateTimeRe.firstMatch(text);
    if (m == null) return null;
    return DateTime(
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      int.parse(m[4] ?? '0'),
      int.parse(m[5] ?? '0'),
    );
  }

  /// What follows `HH:MM` in the cell text (`:45.123+02` …), kept verbatim
  /// when the user leaves the hour and minute as they were, so confirming
  /// the picker never drops seconds, fractions or a zone.
  String? _timeTail() {
    final text = widget.value?.trim();
    if (text == null || text.isEmpty) return null;
    final m = widget.mode == CupertinoDatePickerMode.time
        ? _timeRe.firstMatch(text)
        : _dateTimeRe.firstMatch(text);
    if (m == null) return null;
    return widget.mode == CupertinoDatePickerMode.time ? m[3] : m[6];
  }

  /// `HH:MM` plus [_timeTail] when the picked time is the seed's, otherwise
  /// `HH:MM:00`.
  String _timeText(TimeOfDay picked, DateTime seed) {
    final hour = picked.hour.toString().padLeft(2, '0');
    final minute = picked.minute.toString().padLeft(2, '0');
    final tail = _timeTail();
    final untouched = picked.hour == seed.hour && picked.minute == seed.minute;
    if (untouched && tail != null) return '$hour:$minute$tail';
    return '$hour:$minute:00';
  }

  DateTime _clampToRange(DateTime dt) {
    if (dt.isBefore(_firstDate)) return _firstDate;
    if (dt.isAfter(_lastDate)) return _lastDate;
    return dt;
  }

  Future<DateTime?> _pickDate(DateTime seed) {
    return showDatePicker(
      context: context,
      initialDate: _clampToRange(seed),
      firstDate: _firstDate,
      lastDate: _lastDate,
    );
  }

  Future<TimeOfDay?> _pickTime(DateTime seed) {
    return showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: seed.hour, minute: seed.minute),
      builder: (builderContext, child) => MediaQuery(
        data: MediaQuery.of(
          builderContext,
        ).copyWith(alwaysUse24HourFormat: true),
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }

  Future<void> _pick() async {
    if (!widget.enabled) return;
    final seed = _seed();
    switch (widget.mode) {
      case CupertinoDatePickerMode.date:
        final picked = await _pickDate(seed);
        if (picked != null) widget.onChanged(_format(picked));
      case CupertinoDatePickerMode.monthYear:
        final picked = await _pickDate(seed);
        if (picked != null) {
          widget.onChanged(_format(DateTime(picked.year, picked.month)));
        }
      case CupertinoDatePickerMode.time:
        final picked = await _pickTime(seed);
        if (picked != null) widget.onChanged(_timeText(picked, seed));
      case CupertinoDatePickerMode.dateAndTime:
        final pickedDate = await _pickDate(seed);
        if (pickedDate == null) return;
        if (!mounted) return;
        final pickedTime = await _pickTime(seed);
        if (pickedTime == null) return;
        final date = _format(
          DateTime(pickedDate.year, pickedDate.month, pickedDate.day),
        ).substring(0, 10);
        widget.onChanged('$date ${_timeText(pickedTime, seed)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return _RawTextInput(
      value: widget.value,
      enabled: widget.enabled,
      monospace: true,
      hint: switch (widget.mode) {
        CupertinoDatePickerMode.date => 'YYYY-MM-DD',
        CupertinoDatePickerMode.time => 'HH:MM:SS',
        CupertinoDatePickerMode.dateAndTime => 'YYYY-MM-DD HH:MM:SS',
        CupertinoDatePickerMode.monthYear => 'YYYY-MM',
      },
      onChanged: widget.onChanged,
      focusNode: widget.focusNode,
      suffix: MouseRegion(
        cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: _pick,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6.0),
            child: Tooltip(
              message: 'Pick date',
              child: Icon(Icons.event, size: 14.0),
            ),
          ),
        ),
      ),
    );
  }
}
