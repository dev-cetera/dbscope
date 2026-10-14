part of '../column_input.dart';

class _DateInput extends StatefulWidget {
  const _DateInput({
    required this.value,
    required this.enabled,
    required this.mode,
    required this.onChanged,
  });
  final String? value;
  final bool enabled;
  final CupertinoDatePickerMode mode;
  final ValueChanged<Object?> onChanged;

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

  DateTime _seed() {
    final raw = widget.value;
    if (raw != null && raw.isNotEmpty) {
      final parsed = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
      if (parsed != null) return parsed;
    }
    return DateTime.now();
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
        if (picked != null) {
          widget.onChanged(
            _format(DateTime(0, 1, 1, picked.hour, picked.minute)),
          );
        }
      case CupertinoDatePickerMode.dateAndTime:
        final pickedDate = await _pickDate(seed);
        if (pickedDate == null) return;
        if (!mounted) return;
        final pickedTime = await _pickTime(seed);
        if (pickedTime == null) return;
        widget.onChanged(
          _format(
            DateTime(
              pickedDate.year,
              pickedDate.month,
              pickedDate.day,
              pickedTime.hour,
              pickedTime.minute,
            ),
          ),
        );
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
      suffix: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
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
