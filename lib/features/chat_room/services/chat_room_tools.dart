import 'dart:convert';

import '../../../core/models/assistant.dart';
import '../../../core/providers/settings_provider.dart';
import '../models/chat_room_message.dart';
import 'pocketbase_chat_service.dart';

abstract final class ChatRoomTools {
  static const String readName = 'read_chat_room';
  static const String sendName = 'send_chat_room_message';
  static const Set<String> names = {readName, sendName};

  static const List<Map<String, dynamic>> definitions = [
    {
      'type': 'function',
      'function': {
        'name': readName,
        'description':
            'Read the latest messages from the shared PocketBase chat room. '
            'Use this when the user asks what was said there or asks you to check '
            'messages from the user or other assistants.',
        'parameters': {
          'type': 'object',
          'properties': {
            'limit': {
              'type': 'integer',
              'description':
                  'Number of latest messages to return (1-100, default 20).',
            },
          },
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': sendName,
        'description':
            'Send a message to the shared PocketBase chat room as the current '
            'assistant. Use only when the user asks you to post or reply there.',
        'parameters': {
          'type': 'object',
          'properties': {
            'content': {
              'type': 'string',
              'description': 'The message text to send.',
            },
          },
          'required': ['content'],
        },
      },
    },
  ];

  static bool isConfigured(SettingsProvider settings) =>
      settings.chatRoomPocketBaseServerUrl.trim().isNotEmpty &&
      settings.chatRoomPocketBaseCollection.trim().isNotEmpty &&
      settings.chatRoomPocketBaseAuthCollection.trim().isNotEmpty &&
      settings.chatRoomPocketBaseEmail.trim().isNotEmpty;

  static Future<String> execute({
    required String name,
    required Map<String, dynamic> arguments,
    required SettingsProvider settings,
    required Assistant assistant,
  }) async {
    if (!names.contains(name)) {
      return _error('unknown_tool', 'Unknown chat room tool.');
    }
    if (!isConfigured(settings)) {
      return _error(
        'not_configured',
        'Open the chat room and finish PocketBase configuration first.',
      );
    }

    final service = PocketBaseChatService(
      serverUrl: settings.chatRoomPocketBaseServerUrl,
      messageCollection: settings.chatRoomPocketBaseCollection,
      authCollection: settings.chatRoomPocketBaseAuthCollection,
    );
    try {
      final history = await service.connect(
        email: settings.chatRoomPocketBaseEmail,
        onStatus: (_, [__]) {},
        onMessage: (_) {},
      );
      if (name == readName) {
        final limit = _readLimit(arguments['limit']);
        final selected = history.length <= limit
            ? history
            : history.sublist(history.length - limit);
        return jsonEncode({
          'success': true,
          'messages': selected.map(_messageJson).toList(growable: false),
        });
      }

      final content = arguments['content']?.toString().trim() ?? '';
      if (content.isEmpty) {
        return _error('invalid_arguments', 'content is required.');
      }
      final message = await service.sendTextAs(
        senderId: assistant.id,
        senderName: assistant.name,
        content: content,
      );
      return jsonEncode({'success': true, 'message': _messageJson(message)});
    } on ChatRoomServiceException catch (error) {
      return _error(error.failure.name, 'The chat room request failed.');
    } catch (_) {
      return _error('unexpected', 'The chat room request failed.');
    } finally {
      await service.close();
    }
  }

  static int _readLimit(Object? raw) {
    final parsed = raw is num ? raw.toInt() : int.tryParse('$raw');
    return (parsed ?? 20).clamp(1, 100) as int;
  }

  static Map<String, dynamic> _messageJson(ChatRoomMessage message) => {
    'id': message.id,
    'senderId': message.senderId,
    'senderName': message.senderName,
    'content': message.content,
    'created': message.created.toIso8601String(),
  };

  static String _error(String error, String message) =>
      jsonEncode({'success': false, 'error': error, 'message': message});
}
