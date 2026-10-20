import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class ApiException implements Exception {
  final String message;
  final int status;
  final String? field;

  ApiException(this.message, {this.status = 0, this.field});

  @override
  String toString() => message;
}

/// عميل Lynox Chat API + تخزين الجلسة.
class LynoxApi {
  LynoxApi._();
  static final LynoxApi instance = LynoxApi._();

  /// غيّر العنوان ده لو الموقع اتنقل.
  static const String baseUrl = 'https://lynox.xo.je/api.php';

  String? token;
  DateTime? expiresAt;
  Profile? profile;
  String room = 'Lynox Chat';

  bool get loggedIn => token != null && token!.isNotEmpty;

  Map<String, String> _baseHeaders() => {
        'Accept': 'application/json',
        // بعض الاستضافات المجانية بتفلتر الطلبات اللي مفيهاش User-Agent شبه المتصفح.
        if (!kIsWeb)
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
      };

  Uri _uri(String route, [Map<String, String>? query]) =>
      Uri.parse(baseUrl).replace(queryParameters: {'r': route, ...?query});

  Map<String, dynamic> _decode(http.Response res) {
    final body = utf8.decode(res.bodyBytes).trim();
    if (body.startsWith('<')) {
      throw ApiException(
        'الاستضافة رجّعت صفحة HTML بدل JSON (غالباً فحص أمان InfinityFree).',
        status: res.statusCode,
      );
    }
    Map<String, dynamic> data;
    try {
      final d = jsonDecode(body);
      data = d is Map<String, dynamic> ? d : <String, dynamic>{};
    } catch (_) {
      throw ApiException('رد غير مفهوم من السيرفر', status: res.statusCode);
    }
    if (res.statusCode >= 400) {
      throw ApiException(
        (data['error'] ?? 'خطأ ${res.statusCode}').toString(),
        status: res.statusCode,
        field: data['field']?.toString(),
      );
    }
    return data;
  }

  Future<Map<String, dynamic>> _request(
    String route, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String>? query,
    bool auth = true,
  }) async {
    final headers = _baseHeaders();
    if (auth) {
      if (!loggedIn) {
        throw ApiException('سجّل دخول الأول', status: 401);
      }
      headers['Authorization'] = 'Bearer $token';
    }
    final uri = _uri(route, query);
    try {
      final http.Response res;
      if (method == 'POST') {
        headers['Content-Type'] = 'application/json';
        res = await http
            .post(uri, headers: headers, body: jsonEncode(body ?? {}))
            .timeout(const Duration(seconds: 25));
      } else {
        res = await http
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 25));
      }
      return _decode(res);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException('انتهت مهلة الاتصال بالسيرفر');
    } catch (_) {
      throw ApiException('مفيش اتصال بالسيرفر');
    }
  }

  // ---------------- الجلسة ----------------

  Future<void> _applyAuth(Map<String, dynamic> j) async {
    final t = j['token'];
    if (t is String && t.isNotEmpty) token = t;
    final exp = j['expires_in'];
    if (exp is num) {
      expiresAt = DateTime.now().add(Duration(seconds: exp.toInt()));
    }
    if (j['room'] is String) room = j['room'] as String;
    if (j['profile'] is Map<String, dynamic>) {
      profile = Profile.fromJson(j['profile'] as Map<String, dynamic>);
    }
    final p = await SharedPreferences.getInstance();
    await p.setString('token', token ?? '');
    await p.setInt('expires_at', expiresAt?.millisecondsSinceEpoch ?? 0);
    await p.setString('username', profile?.username ?? '');
    await p.setString('name', profile?.name ?? '');
    await p.setString('avatar', profile?.avatar ?? '');
    await p.setString('room', room);
  }

  Future<void> clearSession() async {
    token = null;
    expiresAt = null;
    profile = null;
    final p = await SharedPreferences.getInstance();
    for (final k in ['token', 'expires_at', 'username', 'name', 'avatar']) {
      await p.remove(k);
    }
  }

  /// يرجّع الجلسة المحفوظة (لو لسه صالحة).
  Future<bool> restore() async {
    final p = await SharedPreferences.getInstance();
    final t = p.getString('token');
    final exp = p.getInt('expires_at') ?? 0;
    if (t == null || t.isEmpty) return false;
    if (DateTime.now().millisecondsSinceEpoch >= exp) {
      await clearSession();
      return false;
    }
    token = t;
    expiresAt = DateTime.fromMillisecondsSinceEpoch(exp);
    profile = Profile(
      username: p.getString('username') ?? '',
      name: p.getString('name') ?? '',
      avatar: p.getString('avatar') ?? '',
    );
    room = p.getString('room') ?? room;
    try {
      await refresh();
    } on ApiException catch (e) {
      if (e.status == 401) {
        await clearSession();
        return false;
      }
      // مشكلة شبكة: كمّل بالتوكن الحالي.
    }
    return true;
  }

  /// يجدد التوكن لو فاضل أقل من يوم.
  Future<void> refreshIfNeeded() async {
    final e = expiresAt;
    if (e == null) return;
    if (e.difference(DateTime.now()) < const Duration(days: 1)) {
      try {
        await refresh();
      } on ApiException {
        // هيتعامل معاه الـ poll لو بقى 401
      }
    }
  }

  // ---------------- الـ Endpoints ----------------

  Future<Map<String, dynamic>> info() => _request('info', auth: false);

  Future<void> login(String username, String password) async {
    final j = await _request('login',
        method: 'POST',
        auth: false,
        body: {'username': username, 'password': password});
    await _applyAuth(j);
  }

  Future<void> register({
    required String username,
    required String password,
    required String name,
    String avatar = '',
  }) async {
    final j = await _request('register', method: 'POST', auth: false, body: {
      'username': username,
      'password': password,
      'name': name,
      if (avatar.isNotEmpty) 'avatar': avatar,
    });
    await _applyAuth(j);
  }

  Future<void> refresh() async {
    final j = await _request('refresh', method: 'POST');
    await _applyAuth(j);
  }

  Future<PollResult> poll({required int since, bool? typing}) async {
    final j = await _request('poll', query: {
      'since': '$since',
      if (typing != null) 'typing': typing ? '1' : '0',
    });
    if (j['room'] is String) room = j['room'] as String;
    return PollResult.fromJson(j);
  }

  Future<int> say({String text = '', Media? media}) async {
    final body = <String, dynamic>{'text': text};
    if (media != null) {
      body['media'] = {
        'url': media.url,
        'name': media.name,
        'size': media.size,
      };
    }
    final j = await _request('say', method: 'POST', body: body);
    return (j['id'] as num?)?.toInt() ?? 0;
  }

  Future<void> setTyping(bool typing) =>
      _request('typing', method: 'POST', body: {'typing': typing});

  /// يرفع ملف (حتى ٩٫٥ ميجا) ويرجّع الرابط.
  Future<String> uploadFile({
    String? path,
    Uint8List? bytes,
    required String name,
  }) async {
    if (!loggedIn) throw ApiException('سجّل دخول الأول', status: 401);
    final req = http.MultipartRequest('POST', _uri('upload'));
    req.headers.addAll(_baseHeaders());
    req.headers['Authorization'] = 'Bearer $token';
    if (bytes != null) {
      req.files.add(http.MultipartFile.fromBytes('file', bytes, filename: name));
    } else if (path != null) {
      req.files.add(await http.MultipartFile.fromPath('file', path,
          filename: name));
    } else {
      throw ApiException('الملف مش متاح');
    }
    try {
      final streamed = await req.send().timeout(const Duration(minutes: 3));
      final res = await http.Response.fromStream(streamed);
      final j = _decode(res);
      final url = j['url']?.toString() ?? '';
      if (url.isEmpty) throw ApiException('فشل رفع الملف');
      return url;
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException('انتهت مهلة رفع الملف');
    } catch (_) {
      throw ApiException('فشل رفع الملف');
    }
  }

  Future<List<ChatMessage>> messages(
      {int limit = 50, int? since, int? before}) async {
    final j = await _request('messages', query: {
      'limit': '$limit',
      if (since != null) 'since': '$since',
      if (before != null) 'before': '$before',
    });
    return (j['messages'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(ChatMessage.fromJson)
        .toList();
  }

  Future<List<ChatUser>> users() async {
    final j = await _request('users');
    return (j['users'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(ChatUser.fromJson)
        .toList();
  }

  Future<void> logout() async {
    try {
      await _request('logout', method: 'POST');
    } on ApiException {
      // نكمل الخروج محلياً حتى لو فشل الطلب
    }
    await clearSession();
  }
}
