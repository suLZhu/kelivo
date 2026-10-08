import '../../../core/services/memory/memory_tools.dart';
import '../../../core/services/search/search_tool_service.dart';
import '../../../core/services/workspace/workspace_tools_service.dart';
import '../../chat_room/services/chat_room_tools.dart';
import 'local_tools_service.dart';

/// Client-side built-in function names that MCP tools must not expose.
///
/// Reservation is static and unconditional: every name here is always
/// reserved, independent of the current assistant's tool switches.
abstract final class BuiltInToolNames {
  static Set<String> get all => {
    'create_sentinel_once',
    'update_sentinel_once',
    'cancel_sentinel',
    SearchToolService.toolName,
    'builtin_search',
    ...MemoryTools.allToolNames,
    ...MemoryTools.legacyToolNames,
    ...LocalToolNames.all,
    ...ChatRoomTools.names,
    ...WorkspaceToolsService.toolNames,
  };
}
