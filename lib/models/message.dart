import 'dart:convert';
 
enum MessageType { text, image, video, audio, file, system }
 
/// Constante especial: cuando recipientId == null → broadcast a todos.
/// Cuando recipientId tiene valor → mensaje privado 1 a 1.
/// Cuando senderId == 'ADMIN' y type == video → video de fondo del menú.
 
class Message {
  final String id;
  final String senderId;
  final String senderIp;
  final MessageType type;
  final String content; // texto o ruta local del archivo
  final String? fileName;
  final int? fileSize;
  final DateTime timestamp;
  final bool isMe;
 
  /// null = broadcast global / mensaje de grupo "Todos"
  /// valor = IP del destinatario (chat 1 a 1)
  final String? recipientIp;
 
  /// Indica si este mensaje es el video de fondo del menú (enviado por ADMIN)
  final bool isBackgroundVideo;
 
  Message({
    required this.id,
    required this.senderId,
    required this.senderIp,
    required this.type,
    required this.content,
    this.fileName,
    this.fileSize,
    required this.timestamp,
    required this.isMe,
    this.recipientIp,
    this.isBackgroundVideo = false,
  });
 
  Map<String, dynamic> toJson() => {
        'id': id,
        'senderId': senderId,
        'senderIp': senderIp,
        'type': type.name,
        'content': content,
        'fileName': fileName,
        'fileSize': fileSize,
        'timestamp': timestamp.toIso8601String(),
        'recipientIp': recipientIp,
        'isBackgroundVideo': isBackgroundVideo,
      };
 
  factory Message.fromJson(Map<String, dynamic> j, bool isMe) => Message(
        id: j['id'],
        senderId: j['senderId'],
        senderIp: j['senderIp'],
        type: MessageType.values.byName(j['type']),
        content: j['content'],
        fileName: j['fileName'],
        fileSize: j['fileSize'],
        timestamp: DateTime.parse(j['timestamp']),
        isMe: isMe,
        recipientIp: j['recipientIp'],
        isBackgroundVideo: j['isBackgroundVideo'] ?? false,
      );
}