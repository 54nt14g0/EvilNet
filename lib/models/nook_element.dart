import 'package:uuid/uuid.dart';

const _uuid = Uuid();

enum NookElementType { backgroundImage, secondaryImage, text, linkButton, riddleInput }

/// Un elemento posicionable en el canvas de un recoveco.
class NookElement {
  final String id;
  final NookElementType type;

  // Posición y tamaño en el canvas (lógico, independiente del dispositivo)
  final double x;
  final double y;
  final double width;
  final double height;

  // ── backgroundImage ────────────────────────────────────────────────────────
  final String? imagePath; // también usado para secondaryImage

  // ── text ──────────────────────────────────────────────────────────────────
  final String? text;
  final double? fontSize;
  final bool isBold;
  final bool isItalic;
  final int? textColor; // ARGB int

  // ── linkButton ────────────────────────────────────────────────────────────
  final String? targetNookId;      // recoveco destino
  final int? buttonColor;          // ARGB int (si no tiene imagen)
  final String? buttonImagePath;   // imagen opcional para el botón
  // ID del riddleInput que debe resolverse para mostrar este botón.
  // null = visible siempre.
  final String? requiredRiddleId;

  // ── riddleInput ───────────────────────────────────────────────────────────
  final String? riddleQuestion;    // pregunta visible al usuario
  final String? riddleAnswer;      // respuesta correcta (exacta)
  // ID del linkButton que este input desbloquea.
  final String? unlocksButtonId;

  const NookElement({
    required this.id,
    required this.type,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.imagePath,
    this.text,
    this.fontSize,
    this.isBold = false,
    this.isItalic = false,
    this.textColor,
    this.targetNookId,
    this.buttonColor,
    this.buttonImagePath,
    this.requiredRiddleId,
    this.riddleQuestion,
    this.riddleAnswer,
    this.unlocksButtonId,
  });

  factory NookElement.backgroundImage({String? imagePath}) => NookElement(
        id: _uuid.v4(),
        type: NookElementType.backgroundImage,
        x: 0,
        y: 0,
        width: 1.0, // fracción del canvas
        height: 1.0,
        imagePath: imagePath,
      );

  factory NookElement.secondaryImage({
    required double x,
    required double y,
    required double width,
    required double height,
    required String imagePath,
  }) =>
      NookElement(
        id: _uuid.v4(),
        type: NookElementType.secondaryImage,
        x: x,
        y: y,
        width: width,
        height: height,
        imagePath: imagePath,
      );

  factory NookElement.text({
    required double x,
    required double y,
    required double width,
    required double height,
    required String text,
    double fontSize = 16,
    bool isBold = false,
    bool isItalic = false,
    int textColor = 0xFFFFFFFF,
  }) =>
      NookElement(
        id: _uuid.v4(),
        type: NookElementType.text,
        x: x,
        y: y,
        width: width,
        height: height,
        text: text,
        fontSize: fontSize,
        isBold: isBold,
        isItalic: isItalic,
        textColor: textColor,
      );

  factory NookElement.linkButton({
    required double x,
    required double y,
    required double width,
    required double height,
    required String targetNookId,
    int buttonColor = 0xFFFF2D78,
    String? buttonImagePath,
    String? requiredRiddleId,
  }) =>
      NookElement(
        id: _uuid.v4(),
        type: NookElementType.linkButton,
        x: x,
        y: y,
        width: width,
        height: height,
        targetNookId: targetNookId,
        buttonColor: buttonColor,
        buttonImagePath: buttonImagePath,
        requiredRiddleId: requiredRiddleId,
      );

  factory NookElement.riddleInput({
    required double x,
    required double y,
    required double width,
    required double height,
    required String riddleQuestion,
    required String riddleAnswer,
    required String unlocksButtonId,
  }) =>
      NookElement(
        id: _uuid.v4(),
        type: NookElementType.riddleInput,
        x: x,
        y: y,
        width: width,
        height: height,
        riddleQuestion: riddleQuestion,
        riddleAnswer: riddleAnswer,
        unlocksButtonId: unlocksButtonId,
      );

  NookElement copyWith({
    double? x,
    double? y,
    double? width,
    double? height,
    String? imagePath,
    bool clearImage = false,
    String? text,
    double? fontSize,
    bool? isBold,
    bool? isItalic,
    int? textColor,
    String? targetNookId,
    int? buttonColor,
    String? buttonImagePath,
    bool clearButtonImage = false,
    String? requiredRiddleId,
    bool clearRequiredRiddle = false,
    String? riddleQuestion,
    String? riddleAnswer,
    String? unlocksButtonId,
  }) {
    return NookElement(
      id: id,
      type: type,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      imagePath: clearImage ? null : (imagePath ?? this.imagePath),
      text: text ?? this.text,
      fontSize: fontSize ?? this.fontSize,
      isBold: isBold ?? this.isBold,
      isItalic: isItalic ?? this.isItalic,
      textColor: textColor ?? this.textColor,
      targetNookId: targetNookId ?? this.targetNookId,
      buttonColor: buttonColor ?? this.buttonColor,
      buttonImagePath: clearButtonImage ? null : (buttonImagePath ?? this.buttonImagePath),
      requiredRiddleId: clearRequiredRiddle ? null : (requiredRiddleId ?? this.requiredRiddleId),
      riddleQuestion: riddleQuestion ?? this.riddleQuestion,
      riddleAnswer: riddleAnswer ?? this.riddleAnswer,
      unlocksButtonId: unlocksButtonId ?? this.unlocksButtonId,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'imagePath': imagePath,
        'text': text,
        'fontSize': fontSize,
        'isBold': isBold,
        'isItalic': isItalic,
        'textColor': textColor,
        'targetNookId': targetNookId,
        'buttonColor': buttonColor,
        'buttonImagePath': buttonImagePath,
        'requiredRiddleId': requiredRiddleId,
        'riddleQuestion': riddleQuestion,
        'riddleAnswer': riddleAnswer,
        'unlocksButtonId': unlocksButtonId,
      };

  factory NookElement.fromJson(Map<String, dynamic> j) => NookElement(
        id: j['id'] as String,
        type: NookElementType.values.byName(j['type'] as String),
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        width: (j['width'] as num).toDouble(),
        height: (j['height'] as num).toDouble(),
        imagePath: j['imagePath'] as String?,
        text: j['text'] as String?,
        fontSize: (j['fontSize'] as num?)?.toDouble(),
        isBold: j['isBold'] as bool? ?? false,
        isItalic: j['isItalic'] as bool? ?? false,
        textColor: j['textColor'] as int?,
        targetNookId: j['targetNookId'] as String?,
        buttonColor: j['buttonColor'] as int?,
        buttonImagePath: j['buttonImagePath'] as String?,
        requiredRiddleId: j['requiredRiddleId'] as String?,
        riddleQuestion: j['riddleQuestion'] as String?,
        riddleAnswer: j['riddleAnswer'] as String?,
        unlocksButtonId: j['unlocksButtonId'] as String?,
      );
}