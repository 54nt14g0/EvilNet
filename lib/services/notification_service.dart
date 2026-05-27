import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationService {
  static final NotificationService _i = NotificationService._();
  factory NotificationService() => _i;
  NotificationService._();

  final _player = AudioPlayer();
  bool _isPlaying = false;
  DateTime? _lastPlayed;
  bool _pendingPlay = false;

  final _localNotif = FlutterLocalNotificationsPlugin();
  bool _localNotifInitialized = false;

  static const _globalKey = 'notif_global_enabled';
  static const _chatKeyPrefix = 'notif_chat_';

  Future<void> init() async {
    if (_localNotifInitialized) return;
    if (!Platform.isAndroid) {
      _localNotifInitialized = true;
      return;
    }
    try {
      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidSettings);
      await _localNotif.initialize(initSettings);
      _localNotifInitialized = true;
    } catch (e) {
      print('[NotificationService] init error: $e');
      _localNotifInitialized = true;
    }
  }

  Future<void> notify(String chatId, {String? senderName, String? preview}) async {
    if (!await isEnabled(chatId)) return;

    if (Platform.isAndroid) {
      await _showAndroidNotification(chatId, senderName: senderName, preview: preview);
      await _playInApp();
    } else {
      await _playInApp();
    }
  }

  Future<void> _showAndroidNotification(
    String chatId, {
    String? senderName,
    String? preview,
  }) async {
    if (!_localNotifInitialized) await init();
    try {
      final title = senderName != null ? '@$senderName' : 'EvilNet';
      final body = preview ?? 'Nuevo mensaje';

      const androidDetails = AndroidNotificationDetails(
        'evilnet_messages',
        'Mensajes EvilNet',
        channelDescription: 'Notificaciones de nuevos mensajes',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
      );

      await _localNotif.show(
        chatId.hashCode.abs() % 10000,
        title,
        body,
        const NotificationDetails(android: androidDetails),
      );
    } catch (e) {
      print('[NotificationService] show error: $e');
    }
  }

  Future<void> _playInApp() async {
    final now = DateTime.now();
    final sinceLastPlay = _lastPlayed == null
        ? const Duration(days: 1)
        : now.difference(_lastPlayed!);

    if (_isPlaying) {
      _pendingPlay = true;
      return;
    }

    if (sinceLastPlay.inSeconds < 5) return;

    await _doPlay();
  }

  Future<void> _doPlay() async {
    if (_isPlaying) return;
    _isPlaying = true;
    _lastPlayed = DateTime.now();
    _pendingPlay = false;

    try {
      await _player.stop();
      await _player.play(AssetSource('notify.mp3'));
      _player.onPlayerComplete.listen((_) async {
        _isPlaying = false;
        if (_pendingPlay) {
          _pendingPlay = false;
          final elapsed = DateTime.now().difference(_lastPlayed!).inSeconds;
          if (elapsed < 5) {
            await Future.delayed(Duration(seconds: 5 - elapsed));
          }
          await _doPlay();
        }
      });
    } catch (e) {
      _isPlaying = false;
      print('[NotificationService] Error playing: $e');
    }
  }

  Future<bool> isGlobalEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_globalKey) ?? true;
  }

  Future<void> setGlobalEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_globalKey, value);
  }

  Future<bool> isChatEnabled(String chatId) async {
    if (!await isGlobalEnabled()) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$_chatKeyPrefix$chatId') ?? true;
  }

  Future<void> setChatEnabled(String chatId, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_chatKeyPrefix$chatId', value);
  }

  Future<bool> isEnabled(String chatId) => isChatEnabled(chatId);

  void dispose() {
    _player.dispose();
  }
}