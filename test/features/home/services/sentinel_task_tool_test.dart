import 'package:Kelivo/core/models/scheduled_task.dart';
import 'package:Kelivo/features/home/services/sentinel_task_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('create_sentinel_once definition', () {
    test('publishes only the three model-owned string parameters', () {
      final function = SentinelTaskTool.definition['function'] as Map;
      final parameters = function['parameters'] as Map;
      final properties = parameters['properties'] as Map;

      expect(function['name'], SentinelTaskTool.name);
      expect(properties.keys.toSet(), {'runAt', 'instruction', 'reason'});
      expect(
        properties.values.every((property) => property['type'] == 'string'),
        isTrue,
      );
      expect(parameters['required'], ['runAt', 'instruction', 'reason']);
    });
  });

  group('runAt parsing', () {
    test('requires an explicit time zone', () {
      expect(
        () => SentinelTaskTool.parseRunAt('2099-04-05T10:30:00'),
        throwsA(
          isA<SentinelTaskToolException>().having(
            (error) => error.code,
            'code',
            'timezone_required',
          ),
        ),
      );
    });

    test('rejects past dates', () {
      expect(
        () => SentinelTaskTool.parseRunAt(
          '2000-01-01T00:00:00Z',
          now: DateTime.utc(2020),
        ),
        throwsA(
          isA<SentinelTaskToolException>().having(
            (error) => error.code,
            'code',
            'run_at_in_past',
          ),
        ),
      );
    });

    test('rejects calendar dates that DateTime would otherwise normalize', () {
      expect(
        () => SentinelTaskTool.parseRunAt(
          '2099-02-31T10:30:00Z',
          now: DateTime.utc(2020),
        ),
        throwsA(
          isA<SentinelTaskToolException>().having(
            (error) => error.code,
            'code',
            'invalid_run_at',
          ),
        ),
      );
    });

    test('rejects nonzero seconds and fractional seconds', () {
      for (final value in [
        '2099-04-05T10:30:01Z',
        '2099-04-05T10:30:00.001+08:00',
      ]) {
        expect(
          () => SentinelTaskTool.parseRunAt(value),
          throwsA(
            isA<SentinelTaskToolException>().having(
              (error) => error.code,
              'code',
              'minute_precision_required',
            ),
          ),
        );
      }
    });

    test('accepts Z and offset timestamps at exact minute precision', () {
      expect(
        SentinelTaskTool.parseRunAt(
          '2099-04-05T10:30:00Z',
          now: DateTime.utc(2020),
        ).isUtc,
        isFalse,
      );
      expect(
        SentinelTaskTool.parseRunAt(
          '2099-04-05T10:30:00+08:00',
          now: DateTime.utc(2020),
        ).minute,
        isA<int>(),
      );
    });
  });

  test(
    'task builder binds host identity and creates once follow-up sentinel',
    () {
      final task = SentinelTaskTool.buildTask(
        runAtLocal: DateTime(2099, 4, 5, 10, 30),
        instruction: 'Check the result',
        reason: 'The user expects an update',
        assistantId: 'host-assistant',
        conversationId: 'host-conversation',
      );

      expect(task.taskKind, ScheduledTaskKind.assistantSentinel);
      expect(task.mode, ScheduledTaskMode.followUp);
      expect(task.repeat, ScheduledTaskRepeat.once);
      expect(task.assistantId, 'host-assistant');
      expect(task.conversationId, 'host-conversation');
      expect(task.prompt, 'Check the result');
      expect(task.reason, 'The user expects an update');
      expect(task.enabled, isTrue);
      expect(task.exhausted, isFalse);
    },
  );
}
