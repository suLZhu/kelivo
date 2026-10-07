import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../../core/models/scheduled_task.dart';

class SentinelTaskTool {
  static const name = 'create_sentinel_once';
  static const updateName = 'update_sentinel_once';
  static const cancelName = 'cancel_sentinel';

  static const names = {name, updateName, cancelName};

  static List<Map<String, dynamic>> get definitions => [
    definition,
    updateDefinition,
    cancelDefinition,
  ];

  static Map<String, dynamic> get definition => {
    'type': 'function',
    'function': {
      'name': name,
      'description':
          'Schedule a one-time check that returns to this conversation.',
      'parameters': {
        'type': 'object',
        'properties': {
          'runAt': {
            'type': 'string',
            'description':
                'RFC 3339 absolute date-time with Z or an explicit ±HH:MM offset; exact minute only.',
          },
          'instruction': {
            'type': 'string',
            'description': 'What to do or check when the task runs.',
          },
          'reason': {
            'type': 'string',
            'description': 'Why the assistant should return to this chat.',
          },
        },
        'required': ['runAt', 'instruction', 'reason'],
        'additionalProperties': false,
      },
    },
  };

  static Map<String, dynamic> get updateDefinition => {
    'type': 'function',
    'function': {
      'name': updateName,
      'description':
          'Update a pending sentinel created by this assistant in this conversation. Omit taskId only when exactly one pending sentinel exists.',
      'parameters': {
        'type': 'object',
        'properties': {
          'taskId': {
            'type': 'string',
            'description': 'The sentinel task ID returned when it was created.',
          },
          'runAt': {
            'type': 'string',
            'description':
                'Optional replacement RFC 3339 absolute date-time with timezone; exact minute only.',
          },
          'instruction': {
            'type': 'string',
            'description': 'Optional replacement instruction.',
          },
          'reason': {
            'type': 'string',
            'description': 'Optional replacement reason.',
          },
        },
        'additionalProperties': false,
      },
    },
  };

  static Map<String, dynamic> get cancelDefinition => {
    'type': 'function',
    'function': {
      'name': cancelName,
      'description':
          'Cancel a pending sentinel created by this assistant in this conversation. Omit taskId only when exactly one pending sentinel exists.',
      'parameters': {
        'type': 'object',
        'properties': {
          'taskId': {
            'type': 'string',
            'description': 'The sentinel task ID returned when it was created.',
          },
        },
        'additionalProperties': false,
      },
    },
  };

  static DateTime parseRunAt(String value, {DateTime? now}) {
    final input = value.trim();
    final zoned = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|([+-])(\d{2}):(\d{2}))$',
    );
    final hasZone = RegExp(r'(?:Z|[+-]\d{2}:\d{2})$').hasMatch(input);
    if (!hasZone) {
      throw const SentinelTaskToolException(
        'timezone_required',
        'runAt must include Z or an explicit ±HH:MM time-zone offset.',
      );
    }
    final match = zoned.firstMatch(input);
    if (match == null) {
      throw const SentinelTaskToolException(
        'invalid_run_at',
        'runAt must be a valid RFC 3339 date-time.',
      );
    }
    int component(int index) => int.parse(match.group(index)!);
    final year = component(1);
    final month = component(2);
    final day = component(3);
    final hour = component(4);
    final minute = component(5);
    final second = component(6);
    final normalizedDate = DateTime.utc(year, month, day);
    if (normalizedDate.year != year ||
        normalizedDate.month != month ||
        normalizedDate.day != day ||
        hour > 23 ||
        minute > 59 ||
        second > 60) {
      throw const SentinelTaskToolException(
        'invalid_run_at',
        'runAt must be a valid RFC 3339 date-time.',
      );
    }
    final zoneHour = match.group(10);
    final zoneMinute = match.group(11);
    if (zoneHour != null &&
        (int.parse(zoneHour) > 23 || int.parse(zoneMinute!) > 59)) {
      throw const SentinelTaskToolException(
        'invalid_run_at',
        'runAt must be a valid RFC 3339 date-time.',
      );
    }
    final parsed = DateTime.tryParse(input);
    if (parsed == null) {
      throw const SentinelTaskToolException(
        'invalid_run_at',
        'runAt must be a valid RFC 3339 date-time.',
      );
    }
    final fraction = match.group(7);
    if (second != 0 ||
        fraction != null && fraction.contains(RegExp('[1-9]')) ||
        parsed.second != 0 ||
        parsed.millisecond != 0 ||
        parsed.microsecond != 0) {
      throw const SentinelTaskToolException(
        'minute_precision_required',
        'runAt must be exactly on a minute; seconds and fractional seconds must be zero.',
      );
    }
    if (!parsed.isAfter((now ?? DateTime.now()).toUtc())) {
      throw const SentinelTaskToolException(
        'run_at_in_past',
        'runAt must be later than the current time.',
      );
    }
    return parsed.toLocal();
  }

  static Map<String, Object?> error(String code, String message) => {
    'ok': false,
    'error': code,
    'message': message,
  };

  static String encodeError(String code, String message) =>
      jsonEncode(error(code, message));

  static ScheduledTask buildTask({
    required DateTime runAtLocal,
    required String instruction,
    required String reason,
    required String assistantId,
    required String conversationId,
    String? id,
  }) {
    final label = reason.trim().isEmpty ? instruction.trim() : reason.trim();
    return ScheduledTask(
      id: id ?? const Uuid().v4(),
      name: String.fromCharCodes(label.runes.take(48)),
      prompt: instruction,
      reason: reason,
      taskKind: ScheduledTaskKind.assistantSentinel,
      assistantId: assistantId,
      hour: runAtLocal.hour,
      minute: runAtLocal.minute,
      onceDate: DateTime(runAtLocal.year, runAtLocal.month, runAtLocal.day),
      weekdays: const [1, 2, 3, 4, 5, 6, 7],
      enabled: true,
      exhausted: false,
      mode: ScheduledTaskMode.followUp,
      conversationId: conversationId,
      allowPreparation: false,
      contextPolicy: ScheduledTaskContextPolicy.latest,
      unavailablePolicy: ScheduledTaskUnavailablePolicy.skip,
      notify: true,
      showPreview: true,
    );
  }
}

class SentinelTaskToolException implements Exception {
  const SentinelTaskToolException(this.code, this.message);

  final String code;
  final String message;
}
