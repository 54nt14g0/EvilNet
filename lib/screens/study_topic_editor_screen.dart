import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import '../models/study_topic.dart';
import '../services/study_room_service.dart';
import '../services/peer_service.dart';
import 'study_room_screen.dart'
    show kSRed, kSRedGlow, kSRedDim, kSBg, kSPanel, kSBorder, kSText, kSTextDim;

const _uuidE = Uuid();

class StudyTopicEditorScreen extends StatefulWidget {
  /// Si es null → crear nuevo tema. Si tiene valor → editar existente.
  final StudyTopic? existing;
  const StudyTopicEditorScreen({super.key, this.existing});

  @override
  State<StudyTopicEditorScreen> createState() => _StudyTopicEditorScreenState();
}

class _StudyTopicEditorScreenState extends State<StudyTopicEditorScreen> {
  final _service = StudyRoomService();
  final _peer = PeerService();

  final _titleCtrl = TextEditingController();
  quill.QuillController _quillCtrl = quill.QuillController.basic();
  final _focusNode = FocusNode();
  final _scrollCtrl = ScrollController();

  bool _isSequential = false;
  bool _requiresApproval = false;
  int _minHierarchy = 1;
  String? _coverImagePath;

  /// IDs de temas que deben comentarse para desbloquear ESTE
  List<String> _requiredTopicIds = [];

  /// IDs de temas que ESTE desbloquea al ser comentado
  List<String> _unlocksTopicIds = [];

  bool _saving = false;
  bool get _isEdit => widget.existing != null;

  List<StudyTopic> get _allTopics => _service.topics;

  @override
void initState() {
  super.initState();

  final existing = widget.existing;
  if (existing != null) {
    _titleCtrl.text = existing.title;
    _isSequential = existing.isSequential;
    _requiresApproval = existing.requiresApproval;
    _minHierarchy = existing.minHierarchy;
    _coverImagePath = existing.coverImagePath;
    _requiredTopicIds = List.from(existing.requiredTopicIds);
    _unlocksTopicIds = List.from(existing.unlocksTopicIds);

    try {
      final delta = existing.contentDelta;
      if (delta.isNotEmpty && delta != '[]') {
        final doc = quill.Document.fromJson(
          jsonDecode(delta) as List<dynamic>,
        );
        _quillCtrl = quill.QuillController(
          document: doc,
          selection: const TextSelection.collapsed(offset: 0),
        );
      }
      // delta vacío → _quillCtrl ya tiene QuillController.basic() por defecto
    } catch (_) {
      // error → _quillCtrl ya tiene QuillController.basic() por defecto
    }
  }
  // existing == null → _quillCtrl ya tiene QuillController.basic() por defecto
}

  @override
  void dispose() {
    _titleCtrl.dispose();
    _quillCtrl.dispose();
    _focusNode.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ─── Portada ──────────────────────────────────────────────────────────────

  Future<void> _pickCover() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    setState(() => _coverImagePath = result.files.first.path);
  }

  void _clearCover() => setState(() => _coverImagePath = null);

  // ─── Guardar ──────────────────────────────────────────────────────────────

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      _showError('El título es obligatorio');
      return;
    }

    setState(() => _saving = true);

    try {
      // Serializar el contenido del editor
      final delta = jsonEncode(_quillCtrl.document.toDelta().toJson());

      // Broadcast de portada si hay una nueva
      if (_coverImagePath != null) {
        await _service.broadcastImage(_coverImagePath!);
      }

      final now = DateTime.now();
      final existing = widget.existing;

      final topic = StudyTopic(
        id: existing?.id ?? _uuidE.v4(),
        title: title,
        contentDelta: delta,
        coverImagePath: _coverImagePath,
        minHierarchy: _minHierarchy,
        isSequential: _isSequential,
        requiredTopicIds: _requiredTopicIds,
        unlocksTopicIds: _unlocksTopicIds,
        requiresApproval: _requiresApproval,
        order: existing?.order ?? _service.topics.length,
        creatorId: _peer.myId,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      );

      await _service.upsertTopic(topic);

      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _saving = false);
      _showError('Error al guardar: $e');
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: const TextStyle(fontFamily: 'monospace', color: kSText),
        ),
        backgroundColor: kSRedDim,
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSBg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            // Toolbar del editor
            Container(
              color: kSPanel,
              child: quill.QuillSimpleToolbar(
                controller: _quillCtrl,
                config: quill.QuillSimpleToolbarConfig(
                  showDividers: true,
                  showFontFamily: false,
                  showFontSize: true,
                  showBoldButton: true,
                  showItalicButton: true,
                  showUnderLineButton: true,
                  showStrikeThrough: true,
                  showInlineCode: true,
                  showColorButton: false,
                  showBackgroundColorButton: false,
                  showListNumbers: true,
                  showListBullets: true,
                  showListCheck: false,
                  showCodeBlock: true,
                  showQuote: true,
                  showLink: false,
                  showSearchButton: false,
                  showSubscript: false,
                  showSuperscript: false,
                ),
              ),
            ),
            // Contenido principal scrolleable
            Expanded(
              child: SingleChildScrollView(
                controller: _scrollCtrl,
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildTitleField(),
                    const SizedBox(height: 20),
                    _buildCoverPicker(),
                    const SizedBox(height: 20),
                    _buildEditorArea(),
                    const SizedBox(height: 24),
                    _buildConfigSection(),
                    const SizedBox(height: 24),
                    if (_isSequential) ...[
                      _buildTopicLinksSection(),
                      const SizedBox(height: 24),
                    ],
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: kSPanel,
        border: Border(bottom: BorderSide(color: kSRed.withOpacity(0.3))),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                border: Border.all(color: kSRed.withOpacity(0.4)),
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Icon(
                Icons.arrow_back_ios_new,
                color: kSRed,
                size: 13,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _isEdit ? '◈ EDITAR TEMA' : '◈ NUEVO TEMA',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: kSText,
                letterSpacing: 2,
              ),
            ),
          ),
          GestureDetector(
            onTap: _saving ? null : _save,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: kSRedDim,
                border: Border.all(color: kSRed.withOpacity(0.6)),
                borderRadius: BorderRadius.circular(2),
              ),
              child: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        color: kSRedGlow,
                        strokeWidth: 1.5,
                      ),
                    )
                  : const Text(
                      'GUARDAR',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: kSRedGlow,
                        letterSpacing: 2,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitleField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _FieldLabel(label: 'TÍTULO DEL TEMA'),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: kSPanel,
            border: Border.all(color: kSRed.withOpacity(0.25)),
            borderRadius: BorderRadius.circular(2),
          ),
          child: TextField(
            controller: _titleCtrl,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              color: kSText,
              fontWeight: FontWeight.bold,
            ),
            decoration: const InputDecoration(
              hintText: '// título del tema...',
              hintStyle: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: kSTextDim,
              ),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: InputBorder.none,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCoverPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _FieldLabel(label: 'IMAGEN DE PORTADA'),
        const SizedBox(height: 6),
        if (_coverImagePath != null && File(_coverImagePath!).existsSync()) ...[
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Image.file(
                  File(_coverImagePath!),
                  height: 140,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: Row(
                  children: [
                    _CoverActionBtn(
                      icon: Icons.edit_outlined,
                      onTap: _pickCover,
                      color: kSRedGlow,
                    ),
                    const SizedBox(width: 6),
                    _CoverActionBtn(
                      icon: Icons.close,
                      onTap: _clearCover,
                      color: Colors.red.shade800,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ] else
          GestureDetector(
            onTap: _pickCover,
            child: Container(
              height: 80,
              width: double.infinity,
              decoration: BoxDecoration(
                color: kSPanel,
                border: Border.all(
                  color: kSRed.withOpacity(0.2),
                  style: BorderStyle.solid,
                ),
                borderRadius: BorderRadius.circular(3),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.add_photo_alternate_outlined,
                    color: kSTextDim,
                    size: 24,
                  ),
                  SizedBox(height: 6),
                  Text(
                    'SELECCIONAR PORTADA',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: kSTextDim,
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildEditorArea() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _FieldLabel(label: 'CONTENIDO'),
        const SizedBox(height: 6),
        Container(
          constraints: const BoxConstraints(minHeight: 200),
          decoration: BoxDecoration(
            color: kSPanel,
            border: Border.all(color: kSRed.withOpacity(0.2)),
            borderRadius: BorderRadius.circular(2),
          ),
          padding: const EdgeInsets.all(14),
          child: quill.QuillEditor.basic(
            controller: _quillCtrl,
            config: quill.QuillEditorConfig(
              autoFocus: false,
              expands: false,
              padding: EdgeInsets.zero,
              placeholder: '// escribe el contenido del tema aquí...',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConfigSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kSPanel,
        border: Border.all(color: kSBorder),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _FieldLabel(label: 'CONFIGURACIÓN'),
          const SizedBox(height: 16),

          // Jerarquía mínima
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'JERARQUÍA MÍNIMA',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: kSText,
                        letterSpacing: 1,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Nivel mínimo para ver este tema',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 9,
                        color: kSTextDim,
                      ),
                    ),
                  ],
                ),
              ),
              _HierarchySelector(
                value: _minHierarchy,
                onChanged: (v) => setState(() => _minHierarchy = v),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Divider(),

          // Es secuencial
          _SwitchRow(
            label: 'FORMA PARTE DE LA SECUENCIA',
            subtitle:
                'Los usuarios deben comentarlo para desbloquear el siguiente',
            value: _isSequential,
            onChanged: (v) => setState(() => _isSequential = v),
          ),
          const SizedBox(height: 12),
          _Divider(),

          // Requiere aprobación
          _SwitchRow(
            label: 'REQUIERE APROBACIÓN',
            subtitle: 'Los comentarios deben ser aprobados antes de contar',
            value: _requiresApproval,
            onChanged: (v) => setState(() => _requiresApproval = v),
          ),
        ],
      ),
    );
  }

  Widget _buildTopicLinksSection() {
    final otherTopics = _allTopics
        .where((t) => t.id != widget.existing?.id)
        .toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kSPanel,
        border: Border.all(color: kSBorder),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _FieldLabel(label: 'ENLACES DE SECUENCIA'),
          const SizedBox(height: 4),
          const Text(
            'Define qué temas deben haberse comentado para desbloquear este,\ny qué temas desbloquea este al ser comentado.',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 9,
              color: kSTextDim,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),

          // Requisitos
          _TopicPickerSection(
            label: '⟵  REQUISITOS (deben comentarse ANTES)',
            labelColor: Colors.orange,
            topics: otherTopics,
            selectedIds: _requiredTopicIds,
            onToggle: (id) {
              setState(() {
                if (_requiredTopicIds.contains(id)) {
                  _requiredTopicIds.remove(id);
                } else {
                  _requiredTopicIds.add(id);
                }
              });
            },
          ),
          const SizedBox(height: 16),
          _Divider(),
          const SizedBox(height: 16),

          // Desbloqueos
          _TopicPickerSection(
            label: '⟶  DESBLOQUEA (al comentar ESTE)',
            labelColor: Colors.green,
            topics: otherTopics,
            selectedIds: _unlocksTopicIds,
            onToggle: (id) {
              setState(() {
                if (_unlocksTopicIds.contains(id)) {
                  _unlocksTopicIds.remove(id);
                } else {
                  _unlocksTopicIds.add(id);
                }
              });
            },
          ),
        ],
      ),
    );
  }
}

// ─── Widgets auxiliares ───────────────────────────────────────────────────────

class _FieldLabel extends StatelessWidget {
  final String label;
  const _FieldLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 10,
        color: kSRed,
        letterSpacing: 2,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: kSRed.withOpacity(0.1),
      margin: const EdgeInsets.symmetric(vertical: 4),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: kSText,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: kSTextDim,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: kSRedGlow,
            activeTrackColor: kSRedDim,
            inactiveThumbColor: kSTextDim,
            inactiveTrackColor: kSBorder,
          ),
        ],
      ),
    );
  }
}

class _HierarchySelector extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const _HierarchySelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: kSBg,
        border: Border.all(color: kSRed.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(2),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: value,
          dropdownColor: kSPanel,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: kSRedGlow,
          ),
          items: List.generate(
            10,
            (i) => DropdownMenuItem(
              value: i + 1,
              child: Text(
                'J${i + 1}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: kSText,
                ),
              ),
            ),
          ),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

class _TopicPickerSection extends StatelessWidget {
  final String label;
  final Color labelColor;
  final List<StudyTopic> topics;
  final List<String> selectedIds;
  final ValueChanged<String> onToggle;

  const _TopicPickerSection({
    required this.label,
    required this.labelColor,
    required this.topics,
    required this.selectedIds,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 10,
            color: labelColor,
            letterSpacing: 1,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 10),
        if (topics.isEmpty)
          const Text(
            'No hay otros temas disponibles',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 10,
              color: kSTextDim,
            ),
          )
        else
          ...topics.map((t) {
            final selected = selectedIds.contains(t.id);
            return GestureDetector(
              onTap: () => onToggle(t.id),
              child: Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? labelColor.withOpacity(0.08)
                      : Colors.transparent,
                  border: Border.all(
                    color: selected ? labelColor.withOpacity(0.5) : kSBorder,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Row(
                  children: [
                    Icon(
                      selected
                          ? Icons.check_box_outlined
                          : Icons.check_box_outline_blank,
                      color: selected ? labelColor : kSTextDim,
                      size: 15,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        t.title,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: selected ? kSText : kSTextDim,
                        ),
                      ),
                    ),
                    if (t.isSequential)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: kSRed.withOpacity(0.3)),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Text(
                          '${t.order + 1}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 8,
                            color: kSRed,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }
}

class _CoverActionBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color color;
  const _CoverActionBtn({
    required this.icon,
    required this.onTap,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.8),
          border: Border.all(color: color.withOpacity(0.5)),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Icon(icon, color: color, size: 14),
      ),
    );
  }
}
