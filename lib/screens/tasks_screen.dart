import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../models/task.dart';
import '../models/app_user.dart';
import '../services/task_service.dart';
import '../services/auth_service.dart';
import '../services/peer_service.dart';

// ─── Paleta Windows 95 + Retrowave ───────────────────────────────────────────
const Color kW95Bg = Color(0xFF008080); // teal clásico Win95
const Color kW95Window = Color(0xFFC0C0C0); // gris ventana
const Color kW95Dark = Color(0xFF808080); // sombra oscura
const Color kW95Light = Color(0xFFFFFFFF); // highlight
const Color kW95TitleBar = Color(0xFF000080); // azul título
const Color kW95TitleText = Color(0xFFFFFFFF); // texto título
const Color kW95Text = Color(0xFF000000); // texto normal
const Color kW95Button = Color(0xFFC0C0C0); // botón
const Color kW95Input = Color(0xFFFFFFFF); // input bg
const Color kW95HighSel = Color(0xFF000080); // selección
// Toques retrowave
const Color kRWPink = Color(0xFFFF2D78);
const Color kRWNeon = Color(0xFF00FFB2);
const Color kRWPurple = Color(0xFF9B00FF);

class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});
  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen>
    with TickerProviderStateMixin {
  final _service = TaskService();
  final _auth = AuthService();
  final _peer = PeerService();

  int _selectedTab = 0;
  StreamSubscription? _sub;

  int get _myHierarchy => _auth.currentUser?.jerarquia ?? 1;
  String get _myId => _auth.currentUser?.id ?? '';
  bool get _isAdmin => _myHierarchy >= 9;
  bool get _canAssign => _service.canAssignTasks(_myId, _myHierarchy);

  List<String> get _tabLabels {
    final labels = <String>['Mis Tareas'];
    if (_canAssign || _isAdmin) labels.add('Enviadas');
    if (_isAdmin) labels.add('Todas');
    return labels;
  }

  @override
void initState() {
  super.initState();
  _sub = _service.events.listen((_) {
    if (mounted) setState(() {});
  });
  for (final ip in _peer.knownPeers.keys) {
    _service.syncWithNewPeer(ip);
  }
  // Forzar rebuild tras primer frame para mostrar tareas ya cargadas
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) setState(() {});
  });
}

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Widget _currentTabContent() {
    if (_selectedTab == 0) {
      return _TaskListTab(
        tasks: _service.tasksAssignedToMe(_myId),
        label: 'RECIBIDAS',
        myId: _myId,
        isAdmin: _isAdmin,
        showAll: false,
        emptyMsg: 'No tienes tareas asignadas.',
      );
    }
    if (_selectedTab == 1 && (_canAssign || _isAdmin)) {
      return _TaskListTab(
        tasks: _service.tasksAssignedByMe(_myId),
        label: 'ENVIADAS',
        myId: _myId,
        isAdmin: _isAdmin,
        showAll: false,
        emptyMsg: 'No has asignado tareas aún.',
      );
    }
    if (_isAdmin) {
      return _TaskListTab(
        tasks: _service.allTasksForAdmin(),
        label: 'TODAS',
        myId: _myId,
        isAdmin: true,
        showAll: true,
        emptyMsg: 'No hay tareas en el sistema.',
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    // Asegurar que _selectedTab no quede fuera de rango
    final maxTab = _tabLabels.length - 1;
    if (_selectedTab > maxTab) _selectedTab = 0;

    return Scaffold(
      backgroundColor: kW95Bg,
      body: SafeArea(
        child: Column(
          children: [
            // Barra superior estilo Win95
            Container(
              height: 28,
              color: const Color(0xFF000080),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  // Botón volver — GestureDetector simple sin nada encima
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: const BoxDecoration(
                        color: kW95Button,
                        border: Border(
                          top: BorderSide(color: kW95Light, width: 1),
                          left: BorderSide(color: kW95Light, width: 1),
                          right: BorderSide(color: kW95Dark, width: 1),
                          bottom: BorderSide(color: kW95Dark, width: 1),
                        ),
                      ),
                      child: const Text(
                        '◄ Volver',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: kW95Text,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'EvilNet — Gestión de Tareas',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  _ClockWidget(),
                ],
              ),
            ),

            // Ventana principal Win95
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  color: kW95Window,
                  border: Border(
                    top: BorderSide(color: kW95Light, width: 2),
                    left: BorderSide(color: kW95Light, width: 2),
                    right: BorderSide(color: kW95Dark, width: 2),
                    bottom: BorderSide(color: kW95Dark, width: 2),
                  ),
                ),
                child: Column(
                  children: [
                    // Título ventana
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [kW95TitleBar, Color(0xFF1084D0)],
                        ),
                      ),
                      child: const Text(
                        'Gestor de Tareas v1.0',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: kW95TitleText,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),

                    // Tabs manuales estilo Win95
                    Container(
                      decoration: const BoxDecoration(
                        color: kW95Window,
                        border: Border(bottom: BorderSide(color: kW95Dark)),
                      ),
                      child: Row(
                        children: _tabLabels.asMap().entries.map((e) {
                          final isSelected = _selectedTab == e.key;
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setState(() => _selectedTab = e.key),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? kW95Window
                                    : const Color(0xFFB0B0B0),
                                border: Border(
                                  top: BorderSide(
                                    color: isSelected ? kW95Light : kW95Dark,
                                    width: isSelected ? 2 : 1,
                                  ),
                                  left: BorderSide(
                                    color: isSelected ? kW95Light : kW95Dark,
                                    width: isSelected ? 2 : 1,
                                  ),
                                  right: const BorderSide(
                                    color: kW95Dark,
                                    width: 1,
                                  ),
                                  bottom: BorderSide(
                                    color: isSelected ? kW95Window : kW95Dark,
                                    width: isSelected ? 2 : 1,
                                  ),
                                ),
                              ),
                              child: Text(
                                e.value,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: kW95Text,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),

                    // Contenido de la tab seleccionada
                    Expanded(child: _currentTabContent()),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: (_canAssign || _isAdmin)
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) => _CreateTaskDialog(
                  currentUserHierarchy: _myHierarchy,
                  currentUserId: _myId,
                ),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: kW95Button,
                  border: const Border(
                    top: BorderSide(color: kW95Light, width: 2),
                    left: BorderSide(color: kW95Light, width: 2),
                    right: BorderSide(color: kW95Dark, width: 2),
                    bottom: BorderSide(color: kW95Dark, width: 2),
                  ),
                  boxShadow: [
                    BoxShadow(color: kRWPink.withOpacity(0.3), blurRadius: 8),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 16, color: kW95Text),
                    SizedBox(width: 6),
                    Text(
                      'Nueva Tarea',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: kW95Text,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}
// ─── Lista de tareas ──────────────────────────────────────────────────────────

class _TaskListTab extends StatelessWidget {
  final List<Task> tasks;
  final String label;
  final String myId;
  final bool isAdmin;
  final bool showAssigner;
  final bool showAll;
  final String emptyMsg;

  const _TaskListTab({
    required this.tasks,
    required this.label,
    required this.myId,
    required this.isAdmin,
    this.showAssigner = true,
    this.showAll = false,
    required this.emptyMsg,
  });

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return Container(
        color: kW95Input,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.inbox, size: 48, color: kW95Dark),
              const SizedBox(height: 8),
              Text(
                emptyMsg,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: kW95Dark,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      color: kW95Input,
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: tasks.length,
        itemBuilder: (_, i) => _TaskCard(
          task: tasks[i],
          myId: myId,
          isAdmin: isAdmin,
          showAll: showAll,
        ),
      ),
    );
  }
}

// ─── Card de tarea ────────────────────────────────────────────────────────────

class _TaskCard extends StatelessWidget {
  final Task task;
  final String myId;
  final bool isAdmin;
  final bool showAll;

  const _TaskCard({
    required this.task,
    required this.myId,
    required this.isAdmin,
    required this.showAll,
  });

  Color get _importanceColor {
    switch (task.importance) {
      case TaskImportance.mandatory:
        return const Color(0xFFCC0000);
      case TaskImportance.important:
        return const Color(0xFF804000);
      case TaskImportance.optional:
        return kW95Dark;
    }
  }

  String get _importanceLabel {
    switch (task.importance) {
      case TaskImportance.mandatory:
        return '!! OBLIGATORIO';
      case TaskImportance.important:
        return '! IMPORTANTE';
      case TaskImportance.optional:
        return 'Opcional';
    }
  }

  Color get _completionColor {
    switch (task.completion) {
      case TaskCompletion.good:
        return Colors.green.shade700;
      case TaskCompletion.regular:
        return Colors.orange.shade700;
      case TaskCompletion.bad:
        return const Color(0xFFCC0000);
      case TaskCompletion.notDone:
        return Colors.red.shade900;
      case TaskCompletion.none:
        return task.isOverdue
            ? Colors.red.shade700
            : task.markedDoneByAssignee
            ? Colors.blue.shade700
            : kW95Dark;
    }
  }

  String get _completionLabel {
    switch (task.completion) {
      case TaskCompletion.good:
        return '✓ BIEN';
      case TaskCompletion.regular:
        return '~ REGULAR';
      case TaskCompletion.bad:
        return '✗ MAL';
      case TaskCompletion.notDone:
        return '✗ NO LO HIZO';
      case TaskCompletion.none:
        return task.isOverdue
            ? '⚠ VENCIDA'
            : task.markedDoneByAssignee
            ? '⏳ EN REVISIÓN'
            : '○ PENDIENTE';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOverdue = task.isOverdue;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              TaskDetailScreen(task: task, myId: myId, isAdmin: isAdmin),
        ),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: kW95Window,
          border: Border(
            top: const BorderSide(color: kW95Light, width: 1),
            left: const BorderSide(color: kW95Light, width: 1),
            right: const BorderSide(color: kW95Dark, width: 1),
            bottom: const BorderSide(color: kW95Dark, width: 1),
          ),
          boxShadow: isOverdue
              ? [BoxShadow(color: kRWPink.withOpacity(0.2), blurRadius: 4)]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Barra de título de la "ventana"
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              color: isOverdue ? const Color(0xFFCC0000) : kW95TitleBar,
              child: Row(
                children: [
                  const Icon(Icons.assignment, size: 12, color: kW95TitleText),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: kW95TitleText,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Text(
                    _importanceLabel,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 9,
                      color: task.importance == TaskImportance.optional
                          ? Colors.white70
                          : Colors.yellow,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            // Cuerpo
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showAll) ...[
                    _InfoRow(
                      label: 'De:',
                      value:
                          '@${task.assignerUsername} (J${task.assignerHierarchy})',
                    ),
                    _InfoRow(
                      label: 'Para:',
                      value:
                          '@${task.assigneeUsername} (J${task.assigneeHierarchy})',
                    ),
                  ] else if (myId == task.assigneeId) ...[
                    _InfoRow(
                      label: 'Asignada por:',
                      value:
                          '@${task.assignerUsername} (J${task.assignerHierarchy})',
                    ),
                  ] else ...[
                    _InfoRow(
                      label: 'Para:',
                      value:
                          '@${task.assigneeUsername} (J${task.assigneeHierarchy})',
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: _InfoRow(
                          label: 'Creada:',
                          value: _fmtDate(task.createdAt),
                        ),
                      ),
                      if (task.dueDate != null) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: _InfoRow(
                            label: 'Límite:',
                            value: _fmtDate(task.dueDate!),
                            valueColor: isOverdue
                                ? const Color(0xFFCC0000)
                                : null,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Estado
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: _completionColor),
                      color: _completionColor.withOpacity(0.08),
                    ),
                    child: Text(
                      _completionLabel,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: _completionColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (task.solution != null) ...[
                    const SizedBox(height: 4),
                    const Row(
                      children: [
                        Icon(Icons.check_circle, size: 11, color: Colors.green),
                        SizedBox(width: 3),
                        Text(
                          'Solución entregada',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 9,
                            color: Colors.green,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/'
      '${dt.month.toString().padLeft(2, '0')}/'
      '${dt.year}';
}

// ─── Pantalla de detalle de tarea ─────────────────────────────────────────────

class TaskDetailScreen extends StatefulWidget {
  final Task task;
  final String myId;
  final bool isAdmin;

  const TaskDetailScreen({
    super.key,
    required this.task,
    required this.myId,
    required this.isAdmin,
  });

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen> {
  final _service = TaskService();
  final _auth = AuthService();
  late Task _task;
  StreamSubscription? _sub;

  bool get _isAssigner => _task.assignerId == widget.myId;
  bool get _isAssignee => _task.assigneeId == widget.myId;
  bool get _canSeeAll => widget.isAdmin || _isAssigner || _isAssignee;

  @override
  void initState() {
    super.initState();
    _task = widget.task;
    _sub = _service.events.listen((_) {
      if (!mounted) return;
      final updated = _service.allTasks.where((t) => t.id == _task.id);
      if (updated.isNotEmpty) setState(() => _task = updated.first);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kW95Bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTitleBar(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildInfoWindow(),
                    const SizedBox(height: 8),
                    _buildDescriptionWindow(),
                    const SizedBox(height: 8),
                    if (_canSeeAll) _buildSolutionWindow(),
                    const SizedBox(height: 8),
                    _buildActionsWindow(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTitleBar() {
    return Container(
      height: 28,
      color: const Color(0xFF000080),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: _W95Button(label: '✕', small: true),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _task.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoWindow() {
    return _Win95Window(
      title: 'Información',
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoRow(label: 'Título:', value: _task.title),
            _InfoRow(
              label: 'Asignada por:',
              value: '@${_task.assignerUsername} (J${_task.assignerHierarchy})',
            ),
            _InfoRow(
              label: 'Para:',
              value: '@${_task.assigneeUsername} (J${_task.assigneeHierarchy})',
            ),
            _InfoRow(label: 'Creada:', value: _fmtDateTime(_task.createdAt)),
            if (_task.dueDate != null)
              _InfoRow(
                label: 'Límite:',
                value: _fmtDateTime(_task.dueDate!),
                valueColor: _task.isOverdue ? const Color(0xFFCC0000) : null,
              ),
            _InfoRow(
              label: 'Importancia:',
              value: _importanceLabel(_task.importance),
              valueColor: _importanceColor(_task.importance),
            ),
            _InfoRow(
              label: 'Estado:',
              value: _completionLabel(_task),
              valueColor: _completionColor(_task),
            ),
            if (_task.markedDoneByAssignee && _task.markedDoneAt != null)
              _InfoRow(
                label: 'Entregó el:',
                value: _fmtDateTime(_task.markedDoneAt!),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDescriptionWindow() {
    return _Win95Window(
      title: 'Descripción',
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: kW95Input,
                border: Border(
                  top: const BorderSide(color: kW95Dark),
                  left: const BorderSide(color: kW95Dark),
                  right: const BorderSide(color: kW95Light),
                  bottom: const BorderSide(color: kW95Light),
                ),
              ),
              child: Text(
                _task.description.isEmpty
                    ? '(sin descripción)'
                    : _task.description,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: kW95Text,
                  height: 1.5,
                ),
              ),
            ),
            if (_task.descriptionImagePaths.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _task.descriptionImagePaths.map((p) {
                  if (!File(p).existsSync()) return const SizedBox.shrink();
                  return GestureDetector(
                    onTap: () => _showFullImage(context, p),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          top: const BorderSide(color: kW95Light),
                          left: const BorderSide(color: kW95Light),
                          right: const BorderSide(color: kW95Dark),
                          bottom: const BorderSide(color: kW95Dark),
                        ),
                      ),
                      child: Image.file(
                        File(p),
                        width: 80,
                        height: 80,
                        fit: BoxFit.cover,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSolutionWindow() {
    final sol = _task.solution;

    return _Win95Window(
      title: 'Solución / Entrega',
      accentColor: kRWNeon,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (sol == null) ...[
              const Text(
                'No se ha entregado solución aún.',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: kW95Dark,
                ),
              ),
              if (_isAssignee && _task.completion == TaskCompletion.none) ...[
                const SizedBox(height: 8),
                _W95Button(
                  label: '+ Agregar solución',
                  onTap: () => _showSolutionDialog(context),
                ),
              ],
            ] else ...[
              _InfoRow(label: 'Enviada:', value: _fmtDateTime(sol.submittedAt)),
              if (sol.editedAt != null)
                _InfoRow(label: 'Editada:', value: _fmtDateTime(sol.editedAt!)),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: kW95Input,
                  border: Border(
                    top: const BorderSide(color: kW95Dark),
                    left: const BorderSide(color: kW95Dark),
                    right: const BorderSide(color: kW95Light),
                    bottom: const BorderSide(color: kW95Light),
                  ),
                ),
                child: Text(
                  sol.text.isEmpty ? '(sin texto)' : sol.text,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
              if (sol.imagePaths.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: sol.imagePaths.map((p) {
                    if (!File(p).existsSync()) return const SizedBox.shrink();
                    return GestureDetector(
                      onTap: () => _showFullImage(context, p),
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border(
                            top: const BorderSide(color: kW95Light),
                            left: const BorderSide(color: kW95Light),
                            right: const BorderSide(color: kW95Dark),
                            bottom: const BorderSide(color: kW95Dark),
                          ),
                        ),
                        child: Image.file(
                          File(p),
                          width: 80,
                          height: 80,
                          fit: BoxFit.cover,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
              if (_isAssignee) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    _W95Button(
                      label: '✎ Editar',
                      onTap: () => _showSolutionDialog(context),
                    ),
                    const SizedBox(width: 6),
                    _W95Button(
                      label: '✕ Eliminar',
                      danger: true,
                      onTap: () => _confirmDeleteSolution(context),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActionsWindow() {
    return _Win95Window(
      title: 'Acciones',
      accentColor: kRWPink,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // El asignado puede marcar "ya terminé"
            if (_isAssignee &&
                !_task.markedDoneByAssignee &&
                _task.completion == TaskCompletion.none &&
                !_task.isOverdue)
              _W95Button(
                label: '✓ Ya terminé',
                accent: kRWNeon,
                onTap: () => _confirmMarkDone(context),
              ),

            // El asignador califica (solo si el asignado marcó listo
            // O si la tarea está vencida)
            if (_isAssigner &&
                (_task.markedDoneByAssignee || _task.isOverdue) &&
                _task.completion == TaskCompletion.none)
              _W95Button(
                label: '⭐ Calificar',
                accent: kRWPurple,
                onTap: () => _showCalificationDialog(context),
              ),

            // También admins pueden calificar
            if (widget.isAdmin &&
                !_isAssigner &&
                (_task.markedDoneByAssignee || _task.isOverdue) &&
                _task.completion == TaskCompletion.none)
              _W95Button(
                label: '⭐ Calificar',
                accent: kRWPurple,
                onTap: () => _showCalificationDialog(context),
              ),

            // El asignador o admin pueden editar
            if (_isAssigner ||
                (widget.isAdmin && _task.completion == TaskCompletion.none))
              _W95Button(
                label: '✎ Editar tarea',
                onTap: () => _showEditDialog(context),
              ),

            // Eliminar
            if (_isAssigner || widget.isAdmin)
              _W95Button(
                label: '🗑 Eliminar',
                danger: true,
                onTap: () => _confirmDeleteTask(context),
              ),
          ],
        ),
      ),
    );
  }

  // ─── Diálogos ─────────────────────────────────────────────────────────────

  Future<void> _confirmMarkDone(BuildContext ctx) async {
    final ok = await _showConfirm(
      ctx,
      '¿Confirmar entrega?',
      'Marcarás esta tarea como terminada.\nEl asignador podrá calificarla.',
    );
    if (!ok) return;
    final err = await _service.markDone(_task.id);
    if (err != null && mounted) _showError(ctx, err);
  }

  Future<void> _showCalificationDialog(BuildContext ctx) async {
    TaskCompletion? selected;
    await showDialog(
      context: ctx,
      builder: (_) => StatefulBuilder(
        builder: (c, setSt) => _Win95Dialog(
          title: 'Calificar tarea',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '"${_task.title}"',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: kW95Text,
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: 12),
              for (final c in [
                TaskCompletion.good,
                TaskCompletion.regular,
                TaskCompletion.bad,
                TaskCompletion.notDone,
              ])
                GestureDetector(
                  onTap: () => setSt(() => selected = c),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: selected == c ? kW95TitleBar : kW95Window,
                      border: Border(
                        top: BorderSide(
                          color: selected == c ? kW95Dark : kW95Light,
                        ),
                        left: BorderSide(
                          color: selected == c ? kW95Dark : kW95Light,
                        ),
                        right: BorderSide(
                          color: selected == c ? kW95Light : kW95Dark,
                        ),
                        bottom: BorderSide(
                          color: selected == c ? kW95Light : kW95Dark,
                        ),
                      ),
                    ),
                    child: Text(
                      _completionLabelFor(c),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: selected == c ? kW95TitleText : kW95Text,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _W95Button(label: 'Cancelar', onTap: () => Navigator.pop(c)),
                  const SizedBox(width: 8),
                  _W95Button(
                    label: 'Confirmar',
                    accent: kRWNeon,
                    onTap: selected == null
                        ? null
                        : () async {
                            Navigator.pop(c);
                            final err = await _service.setCompletion(
                              _task.id,
                              selected!,
                            );
                            if (err != null && mounted) {
                              _showError(ctx, err);
                            }
                          },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSolutionDialog(BuildContext ctx) {
    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => _SolutionDialog(task: _task),
    );
  }

  Future<void> _confirmDeleteSolution(BuildContext ctx) async {
    final ok = await _showConfirm(
      ctx,
      '¿Eliminar solución?',
      'La solución será eliminada permanentemente.',
    );
    if (!ok) return;
    await _service.deleteSolution(_task.id);
  }

  void _showEditDialog(BuildContext ctx) {
    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => _CreateTaskDialog(
        currentUserHierarchy: _auth.currentUser?.jerarquia ?? 1,
        currentUserId: widget.myId,
        existing: _task,
      ),
    );
  }

  Future<void> _confirmDeleteTask(BuildContext ctx) async {
    final ok = await _showConfirm(
      ctx,
      '¿Eliminar tarea?',
      'Esta tarea será eliminada para todos los peers.',
    );
    if (!ok) return;
    await _service.deleteTask(_task.id);
    if (mounted) Navigator.pop(ctx);
  }

  Future<bool> _showConfirm(BuildContext ctx, String title, String msg) async {
    final result = await showDialog<bool>(
      context: ctx,
      builder: (_) => _Win95Dialog(
        title: title,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              msg,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: kW95Text,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _W95Button(label: 'No', onTap: () => Navigator.pop(ctx, false)),
                const SizedBox(width: 8),
                _W95Button(
                  label: 'Sí',
                  accent: kRWPink,
                  onTap: () => Navigator.pop(ctx, true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }

  void _showError(BuildContext ctx, String msg) {
    showDialog(
      context: ctx,
      builder: (_) => _Win95Dialog(
        title: 'Error',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              msg,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Color(0xFFCC0000),
              ),
            ),
            const SizedBox(height: 12),
            _W95Button(label: 'Aceptar', onTap: () => Navigator.pop(ctx)),
          ],
        ),
      ),
    );
  }

  void _showFullImage(BuildContext ctx, String path) {
    showDialog(
      context: ctx,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        child: GestureDetector(
          onTap: () => Navigator.pop(ctx),
          child: Image.file(File(path)),
        ),
      ),
    );
  }

  String _fmtDateTime(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/'
      '${dt.month.toString().padLeft(2, '0')}/'
      '${dt.year}  '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';

  String _completionLabelFor(TaskCompletion c) {
    switch (c) {
      case TaskCompletion.good:
        return '✓ BIEN';
      case TaskCompletion.regular:
        return '~ REGULAR';
      case TaskCompletion.bad:
        return '✗ MAL';
      case TaskCompletion.notDone:
        return '✗ NO LO HIZO';
      case TaskCompletion.none:
        return '○ SIN CALIFICAR';
    }
  }

  String _completionLabel(Task t) {
    if (t.completion != TaskCompletion.none) {
      return _completionLabelFor(t.completion);
    }
    if (t.isOverdue) return '⚠ VENCIDA';
    if (t.markedDoneByAssignee) return '⏳ EN REVISIÓN';
    return '○ PENDIENTE';
  }

  Color _completionColor(Task t) {
    switch (t.completion) {
      case TaskCompletion.good:
        return Colors.green.shade700;
      case TaskCompletion.regular:
        return Colors.orange.shade700;
      case TaskCompletion.bad:
        return const Color(0xFFCC0000);
      case TaskCompletion.notDone:
        return Colors.red.shade900;
      case TaskCompletion.none:
        if (t.isOverdue) return Colors.red.shade700;
        if (t.markedDoneByAssignee) return Colors.blue.shade700;
        return kW95Dark;
    }
  }

  String _importanceLabel(TaskImportance i) {
    switch (i) {
      case TaskImportance.mandatory:
        return '!! OBLIGATORIO';
      case TaskImportance.important:
        return '! IMPORTANTE';
      case TaskImportance.optional:
        return 'Opcional';
    }
  }

  Color _importanceColor(TaskImportance i) {
    switch (i) {
      case TaskImportance.mandatory:
        return const Color(0xFFCC0000);
      case TaskImportance.important:
        return const Color(0xFF804000);
      case TaskImportance.optional:
        return kW95Dark;
    }
  }
}

// ─── Diálogo crear/editar tarea ───────────────────────────────────────────────

class _CreateTaskDialog extends StatefulWidget {
  final int currentUserHierarchy;
  final String currentUserId;
  final Task? existing;

  const _CreateTaskDialog({
    required this.currentUserHierarchy,
    required this.currentUserId,
    this.existing,
  });

  @override
  State<_CreateTaskDialog> createState() => _CreateTaskDialogState();
}

class _CreateTaskDialogState extends State<_CreateTaskDialog> {
  final _service = TaskService();
  final _auth = AuthService();

  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  List<String> _descImages = [];
  TaskImportance _importance = TaskImportance.optional;
  DateTime? _dueDate;
  String? _selectedAssigneeId;
  bool _saving = false;

  List<AppUser> get _eligibleAssignees {
    return _auth.users
        .where(
          (u) =>
              u.jerarquia < widget.currentUserHierarchy &&
              u.id != widget.currentUserId,
        )
        .toList()
      ..sort((a, b) => b.jerarquia.compareTo(a.jerarquia));
  }

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) {
      final t = widget.existing!;
      _titleCtrl.text = t.title;
      _descCtrl.text = t.description;
      _descImages = List.from(t.descriptionImagePaths);
      _importance = t.importance;
      _dueDate = t.dueDate;
      _selectedAssigneeId = t.assigneeId;
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (r == null) return;
    setState(() {
      _descImages.addAll(
        r.files.map((f) => f.path!).where((p) => p.isNotEmpty),
      );
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? now.add(const Duration(days: 3)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      builder: (ctx, child) => Theme(
        data: ThemeData.light().copyWith(
          colorScheme: const ColorScheme.light(primary: kW95TitleBar),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _dueDate = picked);
  }

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty) return;
    if (widget.existing == null && _selectedAssigneeId == null) return;

    setState(() => _saving = true);

    String? err;
    if (widget.existing == null) {
      err = await _service.createTask(
        assigneeId: _selectedAssigneeId!,
        title: _titleCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        descriptionImagePaths: _descImages,
        importance: _importance,
        dueDate: _dueDate,
      );
    } else {
      err = await _service.editTask(
        taskId: widget.existing!.id,
        title: _titleCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        descriptionImagePaths: _descImages,
        importance: _importance,
        dueDate: _dueDate,
        clearDueDate: _dueDate == null,
      );
    }

    setState(() => _saving = false);
    if (err != null && mounted) {
      _showErr(err);
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  void _showErr(String msg) {
    showDialog(
      context: context,
      builder: (_) => _Win95Dialog(
        title: 'Error',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              msg,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Color(0xFFCC0000),
              ),
            ),
            const SizedBox(height: 10),
            _W95Button(label: 'OK', onTap: () => Navigator.pop(context)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;

    return _Win95Dialog(
      title: isEdit ? 'Editar tarea' : 'Nueva tarea',
      wide: true,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Asignado
            if (!isEdit) ...[
              const _W95Label('Asignar a:'),
              const SizedBox(height: 4),
              _eligibleAssignees.isEmpty
                  ? const Text(
                      'No hay usuarios con jerarquía inferior.',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Color(0xFFCC0000),
                      ),
                    )
                  : _W95Dropdown<String>(
                      value: _selectedAssigneeId,
                      hint: '-- Seleccionar usuario --',
                      items: _eligibleAssignees
                          .map(
                            (u) => DropdownMenuItem(
                              value: u.id,
                              child: Text(
                                '@${u.username} (J${u.jerarquia})',
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _selectedAssigneeId = v),
                    ),
              const SizedBox(height: 10),
            ],

            // Título
            const _W95Label('Título:'),
            const SizedBox(height: 4),
            _W95TextField(controller: _titleCtrl, hint: 'Título de la tarea'),
            const SizedBox(height: 10),

            // Descripción
            const _W95Label('Descripción:'),
            const SizedBox(height: 4),
            _W95TextField(
              controller: _descCtrl,
              hint: 'Descripción detallada...',
              maxLines: 4,
            ),
            const SizedBox(height: 6),
            _W95Button(label: '📎 Adjuntar imágenes', onTap: _pickImage),
            if (_descImages.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: _descImages.asMap().entries.map((e) {
                  return Stack(
                    children: [
                      if (File(e.value).existsSync())
                        Image.file(
                          File(e.value),
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                        )
                      else
                        Container(
                          width: 60,
                          height: 60,
                          color: kW95Dark,
                          child: const Icon(
                            Icons.broken_image,
                            size: 20,
                            color: kW95Window,
                          ),
                        ),
                      Positioned(
                        top: 0,
                        right: 0,
                        child: GestureDetector(
                          onTap: () =>
                              setState(() => _descImages.removeAt(e.key)),
                          child: Container(
                            color: Colors.black54,
                            padding: const EdgeInsets.all(2),
                            child: const Icon(
                              Icons.close,
                              size: 10,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 10),

            // Importancia
            const _W95Label('Importancia:'),
            const SizedBox(height: 4),
            _W95Dropdown<TaskImportance>(
              value: _importance,
              items: const [
                DropdownMenuItem(
                  value: TaskImportance.optional,
                  child: Text(
                    'Opcional',
                    style: TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
                DropdownMenuItem(
                  value: TaskImportance.important,
                  child: Text(
                    '! Importante',
                    style: TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
                DropdownMenuItem(
                  value: TaskImportance.mandatory,
                  child: Text(
                    '!! Obligatorio',
                    style: TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ],
              onChanged: (v) =>
                  setState(() => _importance = v ?? TaskImportance.optional),
            ),
            const SizedBox(height: 10),

            // Fecha límite
            const _W95Label('Fecha límite (opcional):'),
            const SizedBox(height: 4),
            Row(
              children: [
                _W95Button(
                  label:
                      '📅 ${_dueDate == null ? 'Sin fecha' : _fmtDate(_dueDate!)}',
                  onTap: _pickDate,
                ),
                if (_dueDate != null) ...[
                  const SizedBox(width: 6),
                  _W95Button(
                    label: '✕',
                    small: true,
                    danger: true,
                    onTap: () => setState(() => _dueDate = null),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),

            // Botones
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _W95Button(
                  label: 'Cancelar',
                  onTap: () => Navigator.pop(context),
                ),
                const SizedBox(width: 8),
                _W95Button(
                  label: _saving
                      ? 'Guardando...'
                      : (isEdit ? 'Guardar cambios' : 'Crear tarea'),
                  accent: kRWNeon,
                  onTap: _saving ? null : _save,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmtDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/'
      '${dt.month.toString().padLeft(2, '0')}/'
      '${dt.year}';
}

// ─── Diálogo solución ─────────────────────────────────────────────────────────

class _SolutionDialog extends StatefulWidget {
  final Task task;
  const _SolutionDialog({required this.task});

  @override
  State<_SolutionDialog> createState() => _SolutionDialogState();
}

class _SolutionDialogState extends State<_SolutionDialog> {
  final _service = TaskService();
  final _textCtrl = TextEditingController();
  List<String> _images = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.task.solution != null) {
      _textCtrl.text = widget.task.solution!.text;
      _images = List.from(widget.task.solution!.imagePaths);
    }
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (r == null) return;
    setState(() {
      _images.addAll(r.files.map((f) => f.path!).where((p) => p.isNotEmpty));
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final err = await _service.submitSolution(
      taskId: widget.task.id,
      text: _textCtrl.text.trim(),
      imagePaths: _images,
    );
    setState(() => _saving = false);
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return _Win95Dialog(
      title: 'Mi solución',
      wide: true,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _W95Label('Descripción de mi solución:'),
            const SizedBox(height: 6),
            _W95TextField(
              controller: _textCtrl,
              hint: 'Explica cómo resolviste la tarea...',
              maxLines: 5,
            ),
            const SizedBox(height: 8),
            _W95Button(label: '📎 Adjuntar imágenes', onTap: _pickImage),
            if (_images.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: _images.asMap().entries.map((e) {
                  return Stack(
                    children: [
                      if (File(e.value).existsSync())
                        Image.file(
                          File(e.value),
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                        )
                      else
                        Container(width: 60, height: 60, color: kW95Dark),
                      Positioned(
                        top: 0,
                        right: 0,
                        child: GestureDetector(
                          onTap: () => setState(() => _images.removeAt(e.key)),
                          child: Container(
                            color: Colors.black54,
                            padding: const EdgeInsets.all(2),
                            child: const Icon(
                              Icons.close,
                              size: 10,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _W95Button(
                  label: 'Cancelar',
                  onTap: () => Navigator.pop(context),
                ),
                const SizedBox(width: 8),
                _W95Button(
                  label: _saving ? 'Enviando...' : 'Enviar solución',
                  accent: kRWNeon,
                  onTap: _saving ? null : _save,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Widget para panel de control: gestión de permisos ───────────────────────

class TaskPermissionsWidget extends StatefulWidget {
  const TaskPermissionsWidget({super.key});

  @override
  State<TaskPermissionsWidget> createState() => _TaskPermissionsWidgetState();
}

class _TaskPermissionsWidgetState extends State<TaskPermissionsWidget> {
  final _service = TaskService();
  final _auth = AuthService();

  @override
  Widget build(BuildContext context) {
    final me = _auth.currentUser;
    if (me == null || me.jerarquia < 9) return const SizedBox.shrink();

    final candidates =
        _auth.users.where((u) => u.jerarquia < 9 && u.id != me.id).toList()
          ..sort((a, b) => b.jerarquia.compareTo(a.jerarquia));

    if (candidates.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text(
          'No hay usuarios habilitables.',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: Colors.white38,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: candidates.map((u) {
        final enabled = _service.isEnabledAssigner(u.id);
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '@${u.username}  (J${u.jerarquia})',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.white70,
                  ),
                ),
              ),
              Switch(
                value: enabled,
                onChanged: (v) async {
                  await _service.setAssignerPermission(u.id, v);
                  if (mounted) setState(() {});
                },
                activeColor: const Color(0xFF00FFB2),
                inactiveThumbColor: Colors.white38,
                inactiveTrackColor: Colors.white12,
              ),
              Text(
                enabled ? 'PUEDE ASIGNAR' : 'No puede',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9,
                  color: enabled ? const Color(0xFF00FFB2) : Colors.white24,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// ─── Widgets auxiliares Win95 ─────────────────────────────────────────────────

class _Win95Window extends StatelessWidget {
  final String title;
  final Widget child;
  final double? width;
  final Color? accentColor;

  const _Win95Window({
    required this.title,
    required this.child,
    this.width,
    this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: kW95Window,
        border: Border(
          top: const BorderSide(color: kW95Light, width: 2),
          left: const BorderSide(color: kW95Light, width: 2),
          right: const BorderSide(color: kW95Dark, width: 2),
          bottom: const BorderSide(color: kW95Dark, width: 2),
        ),
        boxShadow: accentColor != null
            ? [BoxShadow(color: accentColor!.withOpacity(0.2), blurRadius: 6)]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Barra de título
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: accentColor != null
                    ? [kW95TitleBar, accentColor!.withOpacity(0.7)]
                    : [kW95TitleBar, const Color(0xFF1084D0)],
              ),
            ),
            child: Text(
              title,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: kW95TitleText,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _Win95Dialog extends StatelessWidget {
  final String title;
  final Widget child;
  final bool wide;

  const _Win95Dialog({
    required this.title,
    required this.child,
    this.wide = false,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: wide ? 360 : 280,
        constraints: const BoxConstraints(maxHeight: 560),
        decoration: BoxDecoration(
          color: kW95Window,
          border: Border(
            top: const BorderSide(color: kW95Light, width: 2),
            left: const BorderSide(color: kW95Light, width: 2),
            right: const BorderSide(color: kW95Dark, width: 2),
            bottom: const BorderSide(color: kW95Dark, width: 2),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [kW95TitleBar, Color(0xFF1084D0)],
                ),
              ),
              child: Text(
                title,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: kW95TitleText,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Flexible(
              child: Padding(padding: const EdgeInsets.all(12), child: child),
            ),
          ],
        ),
      ),
    );
  }
}

class _W95Button extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool small;
  final bool danger;
  final Color? accent;

  const _W95Button({
    required this.label,
    this.onTap,
    this.small = false,
    this.danger = false,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1.0,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: small ? 6 : 10,
            vertical: small ? 3 : 5,
          ),
          decoration: BoxDecoration(
            color: kW95Button,
            border: const Border(
              top: BorderSide(color: kW95Light, width: 1),
              left: BorderSide(color: kW95Light, width: 1),
              right: BorderSide(color: kW95Dark, width: 1),
              bottom: BorderSide(color: kW95Dark, width: 1),
            ),
            boxShadow: accent != null
                ? [BoxShadow(color: accent!.withOpacity(0.3), blurRadius: 4)]
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: small ? 10 : 11,
              color: danger
                  ? const Color(0xFFCC0000)
                  : accent != null
                  ? const Color(0xFF000060)
                  : kW95Text,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

class _W95TextField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final int maxLines;

  const _W95TextField({
    required this.controller,
    required this.hint,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: kW95Input,
        border: Border(
          top: BorderSide(color: kW95Dark),
          left: BorderSide(color: kW95Dark),
          right: BorderSide(color: kW95Light),
          bottom: BorderSide(color: kW95Light),
        ),
      ),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: kW95Text,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: kW95Dark,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 6,
            vertical: 4,
          ),
          border: InputBorder.none,
        ),
        cursorColor: kW95TitleBar,
      ),
    );
  }
}

class _W95Dropdown<T> extends StatelessWidget {
  final T? value;
  final String? hint;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const _W95Dropdown({
    this.value,
    this.hint,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: const BoxDecoration(
        color: kW95Input,
        border: Border(
          top: BorderSide(color: kW95Dark),
          left: BorderSide(color: kW95Dark),
          right: BorderSide(color: kW95Light),
          bottom: BorderSide(color: kW95Light),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          hint: hint != null
              ? Text(
                  hint!,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: kW95Dark,
                  ),
                )
              : null,
          dropdownColor: kW95Window,
          isExpanded: true,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: kW95Text,
          ),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _W95Label extends StatelessWidget {
  final String text;
  const _W95Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 11,
        color: kW95Text,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label ',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: kW95Dark,
              ),
            ),
            TextSpan(
              text: value,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: valueColor ?? kW95Text,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        overflow: TextOverflow.ellipsis,
        maxLines: 2,
      ),
    );
  }
}

class _ClockWidget extends StatefulWidget {
  @override
  State<_ClockWidget> createState() => _ClockWidgetState();
}

class _ClockWidgetState extends State<_ClockWidget> {
  late Timer _timer;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = _now.hour.toString().padLeft(2, '0');
    final m = _now.minute.toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: kW95Button,
        border: Border(
          top: const BorderSide(color: kW95Dark, width: 1),
          left: const BorderSide(color: kW95Dark, width: 1),
          right: const BorderSide(color: kW95Light, width: 1),
          bottom: const BorderSide(color: kW95Light, width: 1),
        ),
      ),
      child: Text(
        '$h:$m',
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: kW95Text,
        ),
      ),
    );
  }
}
