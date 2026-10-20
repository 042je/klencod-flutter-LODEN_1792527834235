import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'login_screen.dart';
import 'models.dart';

const int _maxUploadBytes = 9500000; // ~٩٫٥ ميجا

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final LynoxApi _api = LynoxApi.instance;
  final TextEditingController _ctrl = TextEditingController();
  final ScrollController _scroll = ScrollController();

  final List<ChatMessage> _messages = [];
  List<ChatUser> _users = [];
  List<ChatUser> _typing = [];

  int _since = 0;
  Timer? _timer;
  bool _polling = false;
  bool _background = false;
  bool _online = true;
  bool _sending = false;
  bool _uploading = false;
  bool _firstLoad = true;
  DateTime _lastActivity = DateTime.now();
  late String _room = _api.room;

  String get _me => (_api.profile?.username ?? '').toLowerCase();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _background = state != AppLifecycleState.resumed;
    if (!_background) {
      _lastActivity = DateTime.now();
      _pollNow();
    }
  }

  // ---------------- Polling ----------------

  Duration get _interval {
    if (_background) return const Duration(seconds: 15);
    if (!_online) return const Duration(seconds: 4);
    final idle = DateTime.now().difference(_lastActivity);
    return idle < const Duration(seconds: 20)
        ? const Duration(milliseconds: 1500)
        : const Duration(seconds: 4);
  }

  void _schedule() {
    _timer?.cancel();
    if (!mounted) return;
    _timer = Timer(_interval, _poll);
  }

  void _pollNow() {
    _timer?.cancel();
    _poll();
  }

  Future<void> _poll() async {
    if (_polling || !mounted) return;
    _polling = true;
    try {
      final r = await _api.poll(
        since: _since,
        typing: _ctrl.text.trim().isNotEmpty,
      );
      if (!mounted) return;

      final fresh = r.messages.where((m) => m.id > _since).toList();
      final nearBottom = _isNearBottom();

      setState(() {
        _online = true;
        _room = r.room.isNotEmpty ? r.room : _room;
        _users = r.users;
        _typing =
            r.typing.where((u) => u.username.toLowerCase() != _me).toList();
        if (fresh.isNotEmpty) {
          _messages.addAll(fresh);
          _since = fresh.map((m) => m.id).reduce((a, b) => a > b ? a : b);
        }
      });

      if (fresh.isNotEmpty) {
        _lastActivity = DateTime.now();
        if (_firstLoad || nearBottom) _scrollToBottom(jump: _firstLoad);
      }
      _firstLoad = false;
      _api.refreshIfNeeded();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.status == 401) {
        _polling = false;
        await _forceLogout();
        return;
      }
      setState(() => _online = false);
    } finally {
      _polling = false;
    }
    _schedule();
  }

  // ---------------- UI helpers ----------------

  bool _isNearBottom() {
    if (!_scroll.hasClients) return true;
    final p = _scroll.position;
    return p.maxScrollExtent - p.pixels < 120;
  }

  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (jump) {
        _scroll.jumpTo(max);
      } else {
        _scroll.animateTo(max,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut);
      }
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _forceLogout() async {
    _timer?.cancel();
    await _api.clearSession();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  Future<void> _logout() async {
    _timer?.cancel();
    await _api.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  // ---------------- الإرسال ----------------

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _api.say(text: text);
      _ctrl.clear();
      _lastActivity = DateTime.now();
      _pollNow();
      _scrollToBottom();
    } on ApiException catch (e) {
      if (e.status == 401) {
        await _forceLogout();
        return;
      }
      _toast(e.status == 429 ? 'بتبعت بسرعة، استنى شوية' : e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickAndSend() async {
    if (_uploading) return;
    final res = await FilePicker.platform.pickFiles(withData: kIsWeb);
    if (res == null || res.files.isEmpty) return;
    final f = res.files.single;
    if (f.size > _maxUploadBytes) {
      _toast('الملف أكبر من ٩٫٥ ميجا');
      return;
    }
    setState(() => _uploading = true);
    try {
      final url = await _api.uploadFile(
        path: kIsWeb ? null : f.path,
        bytes: f.bytes,
        name: f.name,
      );
      await _api.say(
        text: '',
        media: Media(url: url, type: 'file', name: f.name, size: f.size),
      );
      _lastActivity = DateTime.now();
      _pollNow();
      _scrollToBottom();
    } on ApiException catch (e) {
      if (e.status == 401) {
        await _forceLogout();
        return;
      }
      _toast(e.status == 429 ? 'بتبعت بسرعة، استنى شوية' : e.message);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  // ---------------- البناء ----------------

  String get _typingText {
    if (_typing.isEmpty) return '';
    if (_typing.length == 1) return '${_typing.first.name} بيكتب الآن...';
    return 'كذا واحد بيكتبوا الآن...';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_room, style: const TextStyle(fontSize: 18)),
            Text(
              _online ? '${_users.length} متصل' : 'غير متصل... بحاول تاني',
              style: TextStyle(
                fontSize: 12,
                color: _online ? cs.onSurfaceVariant : cs.error,
              ),
            ),
          ],
        ),
        actions: [
          Builder(
            builder: (ctx) => IconButton(
              tooltip: 'المتصلين',
              icon: const Icon(Icons.people_alt_outlined),
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'logout') _logout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'logout', child: Text('تسجيل خروج')),
            ],
          ),
        ],
      ),
      endDrawer: _buildUsersDrawer(),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: _firstLoad
                        ? const CircularProgressIndicator()
                        : const Text('مفيش رسايل لسه. ابدأ المحادثة!'),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) {
                      final m = _messages[i];
                      return m.isSystem
                          ? _SystemNote(text: m.text)
                          : _Bubble(
                              message: m,
                              mine: m.username.toLowerCase() == _me,
                            );
                    },
                  ),
          ),
          if (_typing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  _typingText,
                  style: TextStyle(fontSize: 12, color: cs.primary),
                ),
              ),
            ),
          if (_uploading) const LinearProgressIndicator(minHeight: 2),
          _buildInputBar(cs),
        ],
      ),
    );
  }

  Widget _buildInputBar(ColorScheme cs) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: 'إرفاق ملف',
              icon: const Icon(Icons.attach_file),
              onPressed: _uploading ? null : _pickAndSend,
            ),
            Expanded(
              child: TextField(
                controller: _ctrl,
                minLines: 1,
                maxLines: 5,
                maxLength: 2000,
                textInputAction: TextInputAction.newline,
                keyboardType: TextInputType.multiline,
                onChanged: (_) => _lastActivity = DateTime.now(),
                decoration: InputDecoration(
                  hintText: 'اكتب رسالة...',
                  counterText: '',
                  filled: true,
                  fillColor: cs.onSurface.withAlpha(20),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              tooltip: 'إرسال',
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUsersDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'المتصلين (${_users.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: _users.length,
                itemBuilder: (_, i) {
                  final u = _users[i];
                  return ListTile(
                    leading: _Avatar(
                        name: u.name, avatar: u.avatar, color: u.color),
                    title: Text(u.name),
                    subtitle: Text(
                      u.typing ? 'بيكتب الآن...' : '@${u.username}',
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.start,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================= Widgets =======================

class _Avatar extends StatelessWidget {
  final String name;
  final String avatar;
  final int color;
  final double radius;

  const _Avatar({
    required this.name,
    required this.avatar,
    required this.color,
    this.radius = 20,
  });

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim().characters.first;
    final hasImg = avatar.startsWith('http');
    return CircleAvatar(
      radius: radius,
      backgroundColor: hueColor(color),
      foregroundImage: hasImg ? NetworkImage(avatar) : null,
      onForegroundImageError: hasImg ? (_, __) {} : null,
      child: Text(
        initial,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _SystemNote extends StatelessWidget {
  final String text;
  const _SystemNote({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final bool mine;

  const _Bubble({required this.message, required this.mine});

  String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final m = message;
    final bg = mine ? cs.primaryContainer : cs.secondaryContainer;
    final fg = mine ? cs.onPrimaryContainer : cs.onSecondaryContainer;
    final maxW = MediaQuery.of(context).size.width * 0.75;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment:
            mine ? MainAxisAlignment.start : MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        textDirection: TextDirection.rtl,
        children: [
          if (!mine) ...[
            _Avatar(name: m.name, avatar: m.avatar, color: m.color, radius: 16),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxW),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!mine)
                      Text(
                        m.name,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: hueColor(m.color),
                        ),
                      ),
                    if (m.media != null) _MediaView(media: m.media!),
                    if (m.text.isNotEmpty)
                      // النص بيتعرض كنص عادي (مش HTML) عشان نتجنب XSS.
                      Text(m.text, style: TextStyle(color: fg, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(
                      _time(m.time),
                      style: TextStyle(fontSize: 10, color: fg.withAlpha(153)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _open(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

String _fmtSize(int b) {
  if (b <= 0) return '';
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${(b / 1048576).toStringAsFixed(1)} MB';
}

class _MediaView extends StatelessWidget {
  final Media media;
  const _MediaView({required this.media});

  IconData get _icon {
    switch (media.type) {
      case 'video':
        return Icons.videocam_outlined;
      case 'audio':
        return Icons.audiotrack_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (media.type == 'image') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: GestureDetector(
          onTap: () => _open(media.url),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.network(
              media.url,
              width: 220,
              fit: BoxFit.cover,
              loadingBuilder: (_, child, p) => p == null
                  ? child
                  : const SizedBox(
                      width: 220,
                      height: 120,
                      child: Center(child: CircularProgressIndicator()),
                    ),
              errorBuilder: (_, __, ___) => const SizedBox(
                width: 220,
                height: 80,
                child: Center(child: Icon(Icons.broken_image_outlined)),
              ),
            ),
          ),
        ),
      );
    }
    return InkWell(
      onTap: () => _open(media.url),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    media.name.isEmpty ? 'ملف' : media.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_fmtSize(media.size).isNotEmpty)
                    Text(_fmtSize(media.size),
                        style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
