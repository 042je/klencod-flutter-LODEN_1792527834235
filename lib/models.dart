import 'package:flutter/material.dart';

/// اللون الثابت لكل مستخدم: hsl(color, 70%, 60%)
Color hueColor(num hue) =>
    HSLColor.fromAHSL(1, (hue % 360).toDouble(), 0.7, 0.6).toColor();

int _int(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
String _str(dynamic v) => v == null ? '' : v.toString();

class Profile {
  final String username;
  final String name;
  final String avatar;

  const Profile({required this.username, required this.name, this.avatar = ''});

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        username: _str(j['username']),
        name: _str(j['name']),
        avatar: _str(j['avatar']),
      );
}

class Media {
  final String url;
  final String type; // image | video | audio | file
  final String name;
  final int size;

  const Media({
    required this.url,
    required this.type,
    required this.name,
    required this.size,
  });

  factory Media.fromJson(Map<String, dynamic> j) => Media(
        url: _str(j['url']),
        type: _str(j['type']).isEmpty ? 'file' : _str(j['type']),
        name: _str(j['name']),
        size: _int(j['size']),
      );
}

class ChatUser {
  final String username;
  final String name;
  final String avatar;
  final int color;
  final bool typing;

  const ChatUser({
    required this.username,
    required this.name,
    required this.avatar,
    required this.color,
    required this.typing,
  });

  factory ChatUser.fromJson(Map<String, dynamic> j) => ChatUser(
        username: _str(j['username']),
        name: _str(j['name']),
        avatar: _str(j['avatar']),
        color: _int(j['color']),
        typing: j['typing'] == true,
      );
}

class ChatMessage {
  final int id;
  final double ts;
  final String kind; // msg | sys
  final String username;
  final String name;
  final String avatar;
  final int color;
  final String text;
  final Media? media;

  const ChatMessage({
    required this.id,
    required this.ts,
    required this.kind,
    required this.username,
    required this.name,
    required this.avatar,
    required this.color,
    required this.text,
    this.media,
  });

  bool get isSystem => kind == 'sys';

  DateTime get time =>
      DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: _int(j['id']),
        ts: (j['ts'] is num) ? (j['ts'] as num).toDouble() : 0,
        kind: _str(j['kind']).isEmpty ? 'msg' : _str(j['kind']),
        username: _str(j['username']),
        name: _str(j['name']),
        avatar: _str(j['avatar']),
        color: _int(j['color']),
        text: _str(j['text']),
        media: j['media'] is Map<String, dynamic>
            ? Media.fromJson(j['media'] as Map<String, dynamic>)
            : null,
      );
}

class PollResult {
  final String room;
  final List<ChatUser> users;
  final List<ChatUser> typing;
  final List<ChatMessage> messages;

  const PollResult({
    required this.room,
    required this.users,
    required this.typing,
    required this.messages,
  });

  factory PollResult.fromJson(Map<String, dynamic> j) {
    List<T> list<T>(String key, T Function(Map<String, dynamic>) f) =>
        (j[key] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(f)
            .toList();

    return PollResult(
      room: _str(j['room']),
      users: list('users', ChatUser.fromJson),
      typing: (j['typing'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((t) => ChatUser(
                username: _str(t['username']),
                name: _str(t['name']),
                avatar: '',
                color: 0,
                typing: true,
              ))
          .toList(),
      messages: list('messages', ChatMessage.fromJson),
    );
  }
}
