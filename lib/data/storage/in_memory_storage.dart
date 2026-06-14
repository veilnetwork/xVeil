import '../../domain/chat.dart';
import '../../domain/identity.dart';
import 'storage.dart';

/// Volatile [Storage] used in development and tests. Data lives only for the
/// process lifetime. Any non-empty password unlocks; an empty password fails,
/// to exercise the lock-screen error path.
class InMemoryStorage implements Storage {
  bool _open = false;
  Identity? _identity;
  final Map<String, String> _settings = {};
  final Map<String, Contact> _contacts = {};
  final Map<String, List<Message>> _messages = {};

  @override
  bool get isOpen => _open;

  @override
  Future<bool> open({
    required String password,
    bool createIfMissing = false,
  }) async {
    if (password.isEmpty && !createIfMissing) return false;
    _open = true;
    return true;
  }

  @override
  Future<void> saveIdentity(Identity identity) async {
    _identity = identity;
  }

  @override
  Future<Identity?> loadIdentity() async => _identity;

  @override
  Future<void> putSetting(String key, String value) async {
    _settings[key] = value;
  }

  @override
  Future<String?> getSetting(String key) async => _settings[key];

  @override
  Future<void> upsertContact(Contact contact) async {
    _contacts[contact.nodeId.hex] = contact;
    _messages.putIfAbsent(contact.nodeId.hex, () => []);
  }

  @override
  Future<List<Conversation>> loadConversations() async {
    final out = <Conversation>[];
    for (final entry in _contacts.entries) {
      final msgs = _messages[entry.key] ?? const [];
      out.add(Conversation(
        peer: entry.value,
        lastMessage: msgs.isEmpty ? null : msgs.last,
      ));
    }
    out.sort((a, b) {
      final at = a.lastMessage?.timestamp;
      final bt = b.lastMessage?.timestamp;
      if (at == null && bt == null) return a.peer.label.compareTo(b.peer.label);
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return out;
  }

  @override
  Future<List<Message>> loadMessages(String conversationId) async {
    return List.unmodifiable(_messages[conversationId] ?? const []);
  }

  @override
  Future<void> appendMessage(Message message) async {
    _messages.putIfAbsent(message.conversationId, () => []).add(message);
  }

  @override
  Future<void> close() async {
    _open = false;
    _identity = null;
    _settings.clear();
    _contacts.clear();
    _messages.clear();
  }
}
