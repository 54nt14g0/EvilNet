import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Gestiona notificaciones de sonido con debounce de 5 segundos.
/// Una sola reproducción completa por ráfaga de mensajes.
class NotificationService {
  static final NotificationService _i = NotificationService._();
  factory NotificationService() => _i;
  NotificationService._();

  final _player = AudioPlayer();
  bool _isPlaying = false;
  DateTime? _lastPlayed;
  bool _pendingPlay = false;
  Timer? _debounceTimer;

  // Clave base para prefs
  static const _globalKey = 'notif_global_enabled';
  static const _chatKeyPrefix = 'notif_chat_';

  /// Reproduce el sonido respetando las reglas:
  /// - Si está sonando: marcar pendiente (no apilar más)
  /// - Si no está sonando y han pasado >= 5s desde el último: sonar
  /// - Si no están pasados 5s: ignorar (ya sonó recientemente)
  Future<void> notify(String chatId) async {
    if (!await isEnabled(chatId)) return;

    final now = DateTime.now();
    final sinceLastPlay = _lastPlayed == null
        ? const Duration(days: 1)
        : now.difference(_lastPlayed!);

    if (_isPlaying) {
      // Ya está sonando — solo marcar pendiente una vez
      _pendingPlay = true;
      return;
    }

    if (sinceLastPlay.inSeconds < 5) {
      // Sonó hace menos de 5s — ignorar
      return;
    }

    await _play();
  }

  Future<void> _play() async {
    if (_isPlaying) return;
    _isPlaying = true;
    _lastPlayed = DateTime.now();
    _pendingPlay = false;

    try {
      await _player.stop();
      _player.onPlayerComplete.listen((_) async {
        _isPlaying = false;
        if (_pendingPlay) {
          _pendingPlay = false;
          // Esperar el resto del delay de 5s si aplica
          final elapsed = DateTime.now().difference(_lastPlayed!).inSeconds;
          if (elapsed < 5) {
            await Future.delayed(Duration(seconds: 5 - elapsed));
          }
          await _play();
        }
      });
      await _player.play(AssetSource('notify.mp3'));
    } catch (e) {
      _isPlaying = false;
      print('[NotificationService] Error playing: $e');
    }
  }

  // ── Configuración persistente ──────────────────────────────────────────────

  /// ¿Están activas las notificaciones globalmente?
  Future<bool> isGlobalEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_globalKey) ?? true;
  }

  Future<void> setGlobalEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_globalKey, value);
  }

  /// ¿Están activas para un chat concreto (chatId = userId o groupId o 'broadcast')?
  Future<bool> isChatEnabled(String chatId) async {
    if (!await isGlobalEnabled()) return false;
    final prefs = await SharedPreferences.getInstance();
    // Por defecto activado si no hay preferencia guardada
    return prefs.getBool('$_chatKeyPrefix$chatId') ?? true;
  }

  Future<void> setChatEnabled(String chatId, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_chatKeyPrefix$chatId', value);
  }

  /// Decide si notificar: global AND chat específico
  Future<bool> isEnabled(String chatId) async {
    return await isChatEnabled(chatId);
  }

  void dispose() {
    _debounceTimer?.cancel();
    _player.dispose();
  }
}