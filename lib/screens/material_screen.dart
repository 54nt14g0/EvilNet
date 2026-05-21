import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import '../models/material_file.dart';
import '../services/material_service.dart';
import 'package:open_filex/open_filex.dart';
import '../services/auth_service.dart';
import '../services/peer_service.dart';

// ─── PALETA UMBRELLA / GOB. SECRETO ──────────────────────────────────────────
const Color kBg         = Color(0xFF070707);
const Color kSurface    = Color(0xFF0F0A0A);
const Color kPanel      = Color(0xFF140808);
const Color kBorder     = Color(0xFF2A0A0A);
const Color kRed        = Color(0xFFCC0000);
const Color kRedGlow    = Color(0xFFFF1A1A);
const Color kRedDeep    = Color(0xFF8B0000);
const Color kCold       = Color(0xFFE8E8E0);
const Color kSteel      = Color(0xFF5A5A5A);
const Color kGreenScan  = Color(0xFF00FF41);
const Color kAmber      = Color(0xFFFFAA00);

// ─── HELPERS ──────────────────────────────────────────────────────────────────
String _militaryTime(DateTime dt) =>
    '${dt.year}${dt.month.toString().padLeft(2,'0')}${dt.day.toString().padLeft(2,'0')}'
    '-${dt.hour.toString().padLeft(2,'0')}${dt.minute.toString().padLeft(2,'0')}';

String _fileCode(String id) => 'EXP-${id.substring(0,6).toUpperCase()}';

// ─── MAIN SCREEN ──────────────────────────────────────────────────────────────
class MaterialScreen extends StatefulWidget {
  const MaterialScreen({super.key});
  @override
  State<MaterialScreen> createState() => _MaterialScreenState();
}

class _MaterialScreenState extends State<MaterialScreen>
    with TickerProviderStateMixin {

  final _material = MaterialService();
  final _auth     = AuthService();
  final _peer     = PeerService();

  StreamSubscription<String>? _subscription;

  String?          _currentFolderId;
  String           _searchQuery    = '';
  MaterialFileType? _filterType;
  String           _sortBy         = 'date';
  bool             _sortAscending  = false;
  bool             _showSearch     = false;

  // Animaciones
  late AnimationController _scanCtrl;
  late AnimationController _flickerCtrl;
  late AnimationController _fabCtrl;
  bool _fabOpen = false;

  final _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();

    _scanCtrl = AnimationController(
      vsync: this, duration: const Duration(seconds: 4),
    )..repeat();

    _flickerCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 80),
    )..repeat(reverse: true);

    _fabCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 220),
    );

    _subscription = _material.events.listen(_onEvent);
  }

  void _onEvent(String event) {
    if (!mounted) return;
    if (event == 'files_updated') setState(() {});
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _scanCtrl.dispose();
    _flickerCtrl.dispose();
    _fabCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  bool get _canManage => (_auth.currentUser?.jerarquia ?? 0) >= 7;

  // ── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final size   = MediaQuery.of(context).size;
    final mobile = size.width < 600;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: kBg,
        body: Stack(
          children: [
            Positioned.fill(child: _buildBackground()),
            Positioned.fill(child: _buildScanlines()),
            SafeArea(
              child: Column(
                children: [
                  _buildHeader(mobile),
                  _buildStatusBar(mobile),
                  _buildBreadcrumb(mobile),
                  if (_showSearch) _buildSearchBar(),
                  _buildToolbar(mobile),
                  Expanded(child: _buildFileList(mobile)),
                ],
              ),
            ),
            if (_canManage)
              Positioned(
                bottom: 24,
                right: 20,
                child: _buildExpandableFab(),
              ),
          ],
        ),
      ),
    );
  }

  // ── FONDO ─────────────────────────────────────────────────────────────────
  Widget _buildBackground() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset('assets/material.jpg', fit: BoxFit.cover),
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xF0070707),
                Color(0xE8070707),
                Color(0xF5070707),
              ],
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 1.4,
              colors: [
                Colors.transparent,
                kBg.withOpacity(0.6),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── SCANLINES ─────────────────────────────────────────────────────────────
  Widget _buildScanlines() {
    return AnimatedBuilder(
      animation: _scanCtrl,
      builder: (_, __) => CustomPaint(
        painter: _ScanlinePainter(_scanCtrl.value),
      ),
    );
  }

  // ── HEADER ────────────────────────────────────────────────────────────────
  Widget _buildHeader(bool mobile) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: mobile ? 12 : 24,
        vertical: 12,
      ),
      decoration: BoxDecoration(
        color: kPanel,
        border: Border(
          bottom: BorderSide(color: kRed.withOpacity(0.8), width: 1),
        ),
        boxShadow: [
          BoxShadow(
            color: kRed.withOpacity(0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          _HeaderButton(
            icon: Icons.arrow_back_ios_new,
            onTap: () => Navigator.pop(context),
          ),
          const SizedBox(width: 12),
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: kRed, width: 2),
              color: kRedDeep.withOpacity(0.3),
            ),
            child: const Center(
              child: Text(
                '§',
                style: TextStyle(
                  color: kCold,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  mobile ? 'ARCHIVO CORP.' : 'ARCHIVO CORPORATIVO',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: mobile ? 13 : 15,
                    fontWeight: FontWeight.w900,
                    color: kCold,
                    letterSpacing: 2.5,
                  ),
                ),
                Text(
                  'DIVISIÓN MATERIAL CLASIFICADO',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 8,
                    color: kSteel,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
          _HeaderButton(
            icon: _showSearch ? Icons.search_off : Icons.search,
            color: _showSearch ? kGreenScan : kSteel,
            onTap: () {
              setState(() => _showSearch = !_showSearch);
              if (_showSearch) {
                Future.delayed(
                  const Duration(milliseconds: 100),
                  () => _searchFocus.requestFocus(),
                );
              }
            },
          ),
          const SizedBox(width: 6),
          _ClearanceChip(level: _auth.currentUser?.jerarquia ?? 0),
        ],
      ),
    );
  }

  // ── STATUS BAR ────────────────────────────────────────────────────────────
  Widget _buildStatusBar(bool mobile) {
    final user  = _auth.currentUser;
    final peers = _peer.knownPeers.length;
    final ip    = _peer.myIp;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      color: const Color(0xFF0A0505),
      child: Row(
        children: [
          _StatusDot(active: peers > 0),
          const SizedBox(width: 6),
          Text(
            '$peers PEER${peers != 1 ? "S" : ""} ACTIVO${peers != 1 ? "S" : ""}',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 9,
              color: peers > 0 ? kGreenScan : kSteel,
              letterSpacing: 1,
            ),
          ),
          const Spacer(),
          if (!mobile)
            Text(
              ip,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                color: kSteel,
                letterSpacing: 1,
              ),
            ),
          if (!mobile) const SizedBox(width: 12),
          Text(
            '@${user?.username ?? "ANON"}',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 9,
              color: kCold.withOpacity(0.6),
              letterSpacing: 1,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${_material.files.where((f) => f.type != MaterialFileType.folder).length} ARCHIVOS',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 9,
              color: kSteel,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }

  // ── BREADCRUMB ────────────────────────────────────────────────────────────
  Widget _buildBreadcrumb(bool mobile) {
    final folders = _getBreadcrumbFolders();
    final canGoBack = _currentFolderId != null;
    final String? parentId = folders.length >= 2
        ? folders[folders.length - 2].id
        : canGoBack ? null : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(
        color: kSurface,
        border: Border(
          bottom: BorderSide(color: kBorder, width: 1),
        ),
      ),
      child: Row(
        children: [
          Text(
            '//',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: kRed.withOpacity(0.7),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _BreadcrumbItem(
                    label: 'RAÍZ',
                    active: _currentFolderId == null,
                    onTap: () => setState(() => _currentFolderId = null),
                  ),
                  ...folders.map((f) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          '›',
                          style: TextStyle(color: kSteel, fontSize: 12),
                        ),
                      ),
                      _BreadcrumbItem(
                        label: f.name.toUpperCase(),
                        active: f.id == _currentFolderId,
                        onTap: () => setState(() => _currentFolderId = f.id),
                      ),
                    ],
                  )),
                ],
              ),
            ),
          ),
          if (canGoBack) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => setState(() => _currentFolderId = parentId),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  border: Border.all(color: kRed.withOpacity(0.4)),
                  borderRadius: BorderRadius.circular(2),
                  color: kRedDeep.withOpacity(0.15),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.arrow_upward, size: 10, color: kRedGlow),
                    SizedBox(width: 4),
                    Text(
                      'RETROCEDER',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 9,
                        color: kRedGlow,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<MaterialFile> _getBreadcrumbFolders() {
    final result = <MaterialFile>[];
    var id = _currentFolderId;
    while (id != null) {
      try {
        final f = _material.files.firstWhere((f) => f.id == id);
        result.insert(0, f);
        id = f.parentId;
      } catch (_) { break; }
    }
    return result;
  }

  // ── BARRA DE BÚSQUEDA ─────────────────────────────────────────────────────
  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      color: kSurface,
      child: TextField(
        focusNode: _searchFocus,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          color: kGreenScan,
          letterSpacing: 1,
        ),
        cursorColor: kGreenScan,
        decoration: InputDecoration(
          hintText: '> BUSCAR EXPEDIENTE...',
          hintStyle: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: kSteel.withOpacity(0.6),
            letterSpacing: 1,
          ),
          prefixIcon: const Icon(Icons.terminal, color: kGreenScan, size: 16),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close, color: kSteel, size: 16),
                  onPressed: () => setState(() => _searchQuery = ''),
                )
              : null,
          filled: true,
          fillColor: const Color(0xFF050E05),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(2),
            borderSide: BorderSide(color: kGreenScan.withOpacity(0.3)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(2),
            borderSide: const BorderSide(color: kGreenScan, width: 1),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(2),
            borderSide: BorderSide(color: kGreenScan.withOpacity(0.2)),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        onChanged: (v) => setState(() => _searchQuery = v),
      ),
    );
  }

  // ── TOOLBAR ───────────────────────────────────────────────────────────────
  Widget _buildToolbar(bool mobile) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: mobile ? 12 : 16,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: kSurface.withOpacity(0.95),
        border: Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          Text(
            '${_getFilteredFiles().length} RESULTADO${_getFilteredFiles().length != 1 ? "S" : ""}',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 9,
              color: kSteel,
              letterSpacing: 1,
            ),
          ),
          const Spacer(),
          _ToolbarButton(
            icon: Icons.filter_list,
            label: 'TIPO',
            active: _filterType != null,
            onTap: () => _showFilterMenu(context),
          ),
          const SizedBox(width: 4),
          _ToolbarButton(
            icon: _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
            label: _sortBy.toUpperCase(),
            active: false,
            onTap: () => _showSortMenu(context),
          ),
        ],
      ),
    );
  }

  void _showFilterMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(4)),
        side: BorderSide(color: kBorder),
      ),
      builder: (_) => _FilterBottomSheet(
        current: _filterType,
        onSelect: (t) {
          setState(() => _filterType = t);
          Navigator.pop(context);
        },
      ),
    );
  }

  void _showSortMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(4)),
        side: BorderSide(color: kBorder),
      ),
      builder: (_) => _SortBottomSheet(
        currentSort: _sortBy,
        ascending: _sortAscending,
        onSelect: (s, asc) {
          setState(() {
            _sortBy = s;
            _sortAscending = asc;
          });
          Navigator.pop(context);
        },
      ),
    );
  }

  // ── LISTA DE ARCHIVOS ─────────────────────────────────────────────────────
  List<MaterialFile> _getFilteredFiles() {
    var files = _material.getFilesInFolder(_currentFolderId);
    if (_searchQuery.isNotEmpty) {
      files = files.where(
        (f) => f.name.toLowerCase().contains(_searchQuery.toLowerCase()),
      ).toList();
    }
    if (_filterType != null) {
      files = files.where((f) => f.type == _filterType).toList();
    }
    files.sort((a, b) {
      if (a.type == MaterialFileType.folder && b.type != MaterialFileType.folder) return -1;
      if (a.type != MaterialFileType.folder && b.type == MaterialFileType.folder) return 1;
      int r;
      switch (_sortBy) {
        case 'name': r = a.name.compareTo(b.name); break;
        case 'date': r = a.uploadedAt.compareTo(b.uploadedAt); break;
        case 'size': r = a.fileSize.compareTo(b.fileSize); break;
        default: r = 0;
      }
      return _sortAscending ? r : -r;
    });
    return files;
  }

  Widget _buildFileList(bool mobile) {
    final files = _getFilteredFiles();
    if (files.isEmpty) return _buildEmptyState();
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        mobile ? 8 : 16,
        8,
        mobile ? 8 : 16,
        _canManage ? 100 : 20,
      ),
      itemCount: files.length,
      itemBuilder: (_, i) => _FileCard(
        file: files[i],
        canManage: _canManage,
        onTap: () => _handleFileTap(files[i]),
        onAction: (action) => _handleFileAction(files[i], action),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                Icons.inventory_2_outlined,
                size: 72,
                color: kRedDeep.withOpacity(0.3),
              ),
              Transform.rotate(
                angle: -0.3,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    border: Border.all(color: kRed.withOpacity(0.5), width: 2),
                  ),
                  child: Text(
                    'VACÍO',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: kRed.withOpacity(0.5),
                      letterSpacing: 4,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'SIN EXPEDIENTES EN ESTE SECTOR',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: kSteel,
              letterSpacing: 2,
            ),
          ),
          if (_canManage) ...[
            const SizedBox(height: 8),
            Text(
              'USE LOS CONTROLES INFERIORES PARA AGREGAR',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                color: kSteel.withOpacity(0.5),
                letterSpacing: 1,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── FAB EXPANDIBLE ────────────────────────────────────────────────────────
  Widget _buildExpandableFab() {
    return AnimatedBuilder(
      animation: _fabCtrl,
      builder: (_, __) {
        final v = _fabCtrl.value;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (v > 0.1)
              Opacity(
                opacity: v,
                child: Transform.translate(
                  offset: Offset(0, (1 - v) * 20),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _FabItem(
                      icon: Icons.create_new_folder_outlined,
                      label: 'NUEVA CARPETA',
                      onTap: () {
                        _toggleFab();
                        _createFolder();
                      },
                    ),
                  ),
                ),
              ),
            if (v > 0.1)
              Opacity(
                opacity: v,
                child: Transform.translate(
                  offset: Offset(0, (1 - v) * 10),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _FabItem(
                      icon: Icons.upload_file_outlined,
                      label: 'SUBIR ARCHIVO',
                      onTap: () {
                        _toggleFab();
                        _pickAndUploadFile();
                      },
                    ),
                  ),
                ),
              ),
            GestureDetector(
              onTap: _toggleFab,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _fabOpen ? kRedDeep : kRed,
                  border: Border.all(
                    color: _fabOpen ? kRedGlow : kRed,
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: kRed.withOpacity(_fabOpen ? 0.5 : 0.3),
                      blurRadius: _fabOpen ? 20 : 8,
                      spreadRadius: _fabOpen ? 2 : 0,
                    ),
                  ],
                ),
                child: AnimatedRotation(
                  turns: _fabOpen ? 0.125 : 0,
                  duration: const Duration(milliseconds: 220),
                  child: const Icon(Icons.add, color: kCold, size: 24),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _toggleFab() {
    setState(() => _fabOpen = !_fabOpen);
    if (_fabOpen) {
      _fabCtrl.forward();
    } else {
      _fabCtrl.reverse();
    }
  }

  // ── ACCIONES ──────────────────────────────────────────────────────────────

  /// Abre carpetas navegando, archivos descargados con la app del sistema,
  /// archivos no descargados los descarga primero.
  void _handleFileTap(MaterialFile file) {
    // Carpeta → navegar dentro
    if (file.type == MaterialFileType.folder) {
      setState(() => _currentFolderId = file.id);
      return;
    }

    // No descargado → iniciar descarga y avisar
    if (!file.isDownloaded || file.filePath == null) {
      _material.downloadFile(file.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(
                  color: kGreenScan, strokeWidth: 2,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'DESCARGANDO ${file.name.toUpperCase()}...',
                style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 11, color: kCold,
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF0A0505),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(2),
            side: BorderSide(color: kRed.withOpacity(0.4)),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    // Verificar que el archivo exista físicamente en disco
    final path = file.filePath!;
    if (!File(path).existsSync()) {
      // Archivo perdido del disco → resetear y re-descargar
      _material.downloadFile(file.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'ARCHIVO NO ENCONTRADO — RE-DESCARGANDO...',
            style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: kCold),
          ),
          backgroundColor: const Color(0xFF0A0505),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(2),
            side: BorderSide(color: kRed.withOpacity(0.4)),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    // ── Abrir con la app del sistema, sin importar el tipo ─────────────────
    OpenFilex.open(path);
  }

  void _handleFileAction(MaterialFile file, String action) {
    switch (action) {
      case 'rename':   _showRenameDialog(file); break;
      case 'delete_all': _showDeleteDialog(file, DeleteMode.forEveryone); break;
      case 'delete_me':  _showDeleteDialog(file, DeleteMode.onlyForMe); break;
    }
  }

  void _showRenameDialog(MaterialFile file) {
    final ctrl = TextEditingController(text: file.name);
    showDialog(
      context: context,
      builder: (_) => _CorpDialog(
        title: 'RENOMBRAR EXPEDIENTE',
        titleColor: kAmber,
        content: _CorpTextField(controller: ctrl, hint: 'NUEVO DESIGNADOR', autofocus: true),
        actions: [
          _CorpDialogAction(label: 'CANCELAR', onTap: () => Navigator.pop(context)),
          _CorpDialogAction(
            label: 'CONFIRMAR',
            color: kAmber,
            onTap: () {
              if (ctrl.text.trim().isNotEmpty) {
                _material.renameFile(file.id, ctrl.text.trim());
                Navigator.pop(context);
              }
            },
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog(MaterialFile file, DeleteMode mode) {
    final forAll = mode == DeleteMode.forEveryone;
    showDialog(
      context: context,
      builder: (_) => _CorpDialog(
        title: forAll ? 'PURGAR EXPEDIENTE' : 'BORRADO LOCAL',
        titleColor: forAll ? kRedGlow : kAmber,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              forAll
                  ? 'El expediente ${_fileCode(file.id)} será PURGADO de todos los nodos de la red. Acción irreversible.'
                  : 'El expediente se eliminará de tu dispositivo. Podrás descargarlo nuevamente.',
              style: const TextStyle(
                fontFamily: 'monospace', fontSize: 11, color: kSteel, height: 1.5,
              ),
            ),
            if (forAll) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: kRedGlow.withOpacity(0.4)),
                  color: kRedDeep.withOpacity(0.15),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber, color: kRedGlow, size: 14),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'REQUIERE AUTORIZACIÓN NIVEL 7+',
                        style: TextStyle(
                          fontFamily: 'monospace', fontSize: 9,
                          color: kRedGlow, letterSpacing: 1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          _CorpDialogAction(label: 'CANCELAR', onTap: () => Navigator.pop(context)),
          _CorpDialogAction(
            label: forAll ? 'PURGAR' : 'BORRAR LOCAL',
            color: forAll ? kRedGlow : kAmber,
            onTap: () {
              _material.deleteFile(file.id, mode);
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndUploadFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any, allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null) return;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'TRANSMITIENDO A LA RED...',
            style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: kCold),
          ),
          backgroundColor: Color(0xFF0A0505),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
    await _material.uploadFile(path, _currentFolderId ?? '');
  }

  Future<void> _createFolder() async {
    final ctrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (_) => _CorpDialog(
        title: 'CREAR SECTOR',
        titleColor: kGreenScan,
        content: _CorpTextField(
          controller: ctrl,
          hint: 'DESIGNADOR DE SECTOR',
          autofocus: true,
          color: kGreenScan,
          onSubmit: (v) {
            if (v.trim().isNotEmpty) {
              _material.createFolder(v.trim(), _currentFolderId ?? '');
              Navigator.pop(context);
            }
          },
        ),
        actions: [
          _CorpDialogAction(label: 'CANCELAR', onTap: () => Navigator.pop(context)),
          _CorpDialogAction(
            label: 'CREAR SECTOR',
            color: kGreenScan,
            onTap: () {
              if (ctrl.text.trim().isNotEmpty) {
                _material.createFolder(ctrl.text.trim(), _currentFolderId ?? '');
                Navigator.pop(context);
              }
            },
          ),
        ],
      ),
    );
  }
}

// ─── FILE CARD ────────────────────────────────────────────────────────────────
class _FileCard extends StatefulWidget {
  final MaterialFile file;
  final bool canManage;
  final VoidCallback onTap;
  final void Function(String) onAction;

  const _FileCard({
    required this.file,
    required this.canManage,
    required this.onTap,
    required this.onAction,
  });

  @override
  State<_FileCard> createState() => _FileCardState();
}

class _FileCardState extends State<_FileCard>
    with SingleTickerProviderStateMixin {

  late AnimationController _hoverCtrl;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _hoverCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 160),
    );
  }

  @override
  void dispose() {
    _hoverCtrl.dispose();
    super.dispose();
  }

  Color get _typeAccent {
    switch (widget.file.type) {
      case MaterialFileType.folder:   return kAmber;
      case MaterialFileType.image:    return const Color(0xFF4FC3F7);
      case MaterialFileType.video:    return const Color(0xFFCE93D8);
      case MaterialFileType.audio:    return const Color(0xFF80CBC4);
      case MaterialFileType.document: return const Color(0xFFFFCC80);
      default: return kSteel;
    }
  }

  IconData get _typeIcon {
    switch (widget.file.type) {
      case MaterialFileType.folder:   return Icons.folder_special_outlined;
      case MaterialFileType.image:    return Icons.image_outlined;
      case MaterialFileType.video:    return Icons.movie_outlined;
      case MaterialFileType.audio:    return Icons.graphic_eq;
      case MaterialFileType.document: return Icons.article_outlined;
      default: return Icons.insert_drive_file_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final isFolder = file.type == MaterialFileType.folder;

    return GestureDetector(
      onTapDown: (_) { setState(() => _pressed = true); _hoverCtrl.forward(); },
      onTapUp: (_)   { setState(() => _pressed = false); _hoverCtrl.reverse(); },
      onTapCancel: () { setState(() => _pressed = false); _hoverCtrl.reverse(); },
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _hoverCtrl,
        builder: (_, __) {
          final t = _hoverCtrl.value;
          return Container(
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: Color.lerp(kSurface, kPanel, t),
              border: Border(
                left: BorderSide(
                  color: Color.lerp(
                    _typeAccent.withOpacity(0.3),
                    _typeAccent,
                    t,
                  )!,
                  width: 3,
                ),
                top: BorderSide(color: kBorder),
                right: BorderSide(color: kBorder),
                bottom: BorderSide(color: kBorder),
              ),
              boxShadow: t > 0 ? [
                BoxShadow(
                  color: _typeAccent.withOpacity(0.08 * t),
                  blurRadius: 12,
                  offset: const Offset(0, 2),
                ),
              ] : null,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  // ── Icono ──
                  Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      color: _typeAccent.withOpacity(0.08),
                      border: Border.all(color: _typeAccent.withOpacity(0.25)),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    // Para imágenes descargadas: miniatura real
                    child: file.type == MaterialFileType.image &&
                        file.isDownloaded && file.filePath != null &&
                        File(file.filePath!).existsSync()
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: Image.file(
                              File(file.filePath!),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                Icon(_typeIcon, color: _typeAccent, size: 20),
                            ),
                          )
                        : Icon(_typeIcon, color: _typeAccent, size: 20),
                  ),
                  const SizedBox(width: 12),
                  // ── Info ──
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          file.name,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: kCold,
                            letterSpacing: 0.5,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Text(
                              _fileCode(file.id),
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 8,
                                color: _typeAccent.withOpacity(0.7),
                                letterSpacing: 1,
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (!isFolder)
                              Text(
                                file.formattedSize,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 8,
                                  color: kSteel,
                                ),
                              ),
                            const Spacer(),
                            Text(
                              _militaryTime(file.uploadedAt),
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 8,
                                color: kSteel,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            _StatusBadge(
                              label: 'por ${file.uploadedByName.toUpperCase()}',
                              color: kSteel,
                            ),
                            const SizedBox(width: 4),
                            if (isFolder)
                              _StatusBadge(label: 'SECTOR', color: kAmber)
                            else if (file.isDownloaded && file.filePath != null &&
                                File(file.filePath!).existsSync())
                              _StatusBadge(label: 'LOCAL', color: kGreenScan)
                            else
                              _StatusBadge(label: '⬇ PENDIENTE', color: kRedGlow, pulse: true),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildActionMenu(file),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildActionMenu(MaterialFile file) {
    final items = <PopupMenuEntry<String>>[];

    if (widget.canManage) {
      items.addAll([
        const PopupMenuItem(
          value: 'rename',
          child: _MenuRow(icon: Icons.edit_outlined, label: 'RENOMBRAR', color: kAmber),
        ),
        const PopupMenuDivider(height: 1),
        const PopupMenuItem(
          value: 'delete_all',
          child: _MenuRow(icon: Icons.delete_sweep_outlined, label: 'PURGAR (TODOS)', color: kRedGlow),
        ),
      ]);
    }
    items.add(
      const PopupMenuItem(
        value: 'delete_me',
        child: _MenuRow(icon: Icons.delete_outline, label: 'BORRAR LOCAL', color: kSteel),
      ),
    );

    return PopupMenuButton<String>(
      onSelected: widget.onAction,
      color: kPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(2),
        side: const BorderSide(color: kBorder),
      ),
      icon: const Icon(Icons.more_vert, color: kSteel, size: 18),
      itemBuilder: (_) => items,
    );
  }
}

// ─── WIDGETS AUXILIARES ───────────────────────────────────────────────────────

class _StatusBadge extends StatefulWidget {
  final String label;
  final Color color;
  final bool pulse;
  const _StatusBadge({required this.label, required this.color, this.pulse = false});

  @override
  State<_StatusBadge> createState() => _StatusBadgeState();
}

class _StatusBadgeState extends State<_StatusBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))
      ..repeat(reverse: true);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (!widget.pulse) return _badge(1.0);
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => _badge(0.4 + _ctrl.value * 0.6),
    );
  }

  Widget _badge(double opacity) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: widget.color.withOpacity(opacity * 0.5)),
        color: widget.color.withOpacity(opacity * 0.1),
        borderRadius: BorderRadius.circular(1),
      ),
      child: Text(
        widget.label,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 7,
          color: widget.color.withOpacity(opacity),
          letterSpacing: 0.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _HeaderButton({required this.icon, required this.onTap, this.color = kSteel});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32, height: 32,
        decoration: BoxDecoration(
          border: Border.all(color: color.withOpacity(0.3)),
          borderRadius: BorderRadius.circular(2),
          color: color.withOpacity(0.05),
        ),
        child: Icon(icon, color: color, size: 16),
      ),
    );
  }
}

class _ClearanceChip extends StatelessWidget {
  final int level;
  const _ClearanceChip({required this.level});

  Color get _color {
    if (level >= 9) return kRedGlow;
    if (level >= 7) return kAmber;
    if (level >= 4) return kGreenScan;
    return kSteel;
  }

  String get _label {
    if (level >= 9) return 'Ω';
    return 'J$level';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: _color.withOpacity(0.6)),
        color: _color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        _label,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: _color,
          fontWeight: FontWeight.w900,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

class _StatusDot extends StatefulWidget {
  final bool active;
  const _StatusDot({required this.active});

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..repeat(reverse: true);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      return Container(
        width: 6, height: 6,
        decoration: BoxDecoration(shape: BoxShape.circle, color: kSteel),
      );
    }
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Container(
        width: 6, height: 6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: kGreenScan,
          boxShadow: [
            BoxShadow(
              color: kGreenScan.withOpacity(0.3 + _ctrl.value * 0.4),
              blurRadius: 4 + _ctrl.value * 4,
            ),
          ],
        ),
      ),
    );
  }
}

class _BreadcrumbItem extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _BreadcrumbItem({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 10,
          color: active ? kCold : kSteel,
          letterSpacing: 1,
          fontWeight: active ? FontWeight.w700 : FontWeight.normal,
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ToolbarButton({required this.icon, required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(
            color: active ? kRedGlow.withOpacity(0.6) : kBorder,
          ),
          color: active ? kRedDeep.withOpacity(0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: active ? kRedGlow : kSteel),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                color: active ? kRedGlow : kSteel,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FabItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _FabItem({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: kPanel,
              border: Border.all(color: kBorder),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: kCold,
                letterSpacing: 1,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: kSurface,
              border: Border.all(color: kRed.withOpacity(0.5)),
            ),
            child: Icon(icon, color: kCold, size: 18),
          ),
        ],
      ),
    );
  }
}

// ─── CORP DIALOG ─────────────────────────────────────────────────────────────
class _CorpDialog extends StatelessWidget {
  final String title;
  final Color titleColor;
  final Widget content;
  final List<Widget> actions;
  const _CorpDialog({
    required this.title, required this.titleColor,
    required this.content, required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: kPanel,
          border: Border.all(color: titleColor.withOpacity(0.3)),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: titleColor.withOpacity(0.08),
                border: Border(bottom: BorderSide(color: titleColor.withOpacity(0.3))),
              ),
              child: Row(
                children: [
                  Container(
                    width: 3, height: 16,
                    color: titleColor,
                    margin: const EdgeInsets.only(right: 10),
                  ),
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: titleColor,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: content,
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: kBorder)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: actions
                    .map((a) => Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: a,
                        ))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CorpTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool autofocus;
  final Color color;
  final void Function(String)? onSubmit;

  const _CorpTextField({
    required this.controller,
    required this.hint,
    this.autofocus = false,
    this.color = kCold,
    this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: color),
      cursorColor: color,
      onSubmitted: onSubmit,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
          fontFamily: 'monospace', fontSize: 11,
          color: kSteel.withOpacity(0.6), letterSpacing: 1,
        ),
        filled: true,
        fillColor: kBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
          borderSide: BorderSide(color: color.withOpacity(0.3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
          borderSide: BorderSide(color: color, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
          borderSide: BorderSide(color: color.withOpacity(0.2)),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }
}

class _CorpDialogAction extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _CorpDialogAction({required this.label, required this.onTap, this.color = kSteel});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          border: Border.all(color: color.withOpacity(0.4)),
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 10,
            color: color,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _MenuRow({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 14),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: color,
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }
}

// ─── FILTER / SORT BOTTOM SHEETS ──────────────────────────────────────────────
class _FilterBottomSheet extends StatelessWidget {
  final MaterialFileType? current;
  final void Function(MaterialFileType?) onSelect;
  const _FilterBottomSheet({required this.current, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final opts = <(MaterialFileType?, String, IconData)>[
      (null,                       'TODOS',      Icons.all_inclusive),
      (MaterialFileType.folder,    'SECTORES',   Icons.folder_outlined),
      (MaterialFileType.image,     'IMÁGENES',   Icons.image_outlined),
      (MaterialFileType.video,     'VIDEO',      Icons.movie_outlined),
      (MaterialFileType.audio,     'AUDIO',      Icons.graphic_eq),
      (MaterialFileType.document,  'DOCUMENTOS', Icons.article_outlined),
      (MaterialFileType.other,     'OTROS',      Icons.insert_drive_file_outlined),
    ];
    return _BottomSheetContainer(
      title: 'FILTRAR POR TIPO',
      child: Column(
        children: opts.map((o) {
          final active = current == o.$1;
          return ListTile(
            dense: true,
            leading: Icon(o.$3, color: active ? kRedGlow : kSteel, size: 18),
            title: Text(
              o.$2,
              style: TextStyle(
                fontFamily: 'monospace', fontSize: 11,
                color: active ? kCold : kSteel, letterSpacing: 1,
              ),
            ),
            trailing: active ? const Icon(Icons.check, color: kRedGlow, size: 14) : null,
            onTap: () => onSelect(o.$1),
          );
        }).toList(),
      ),
    );
  }
}

class _SortBottomSheet extends StatelessWidget {
  final String currentSort;
  final bool ascending;
  final void Function(String, bool) onSelect;
  const _SortBottomSheet({
    required this.currentSort, required this.ascending, required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final opts = <(String, String, IconData)>[
      ('date', 'FECHA',   Icons.access_time),
      ('name', 'NOMBRE',  Icons.sort_by_alpha),
      ('size', 'TAMAÑO',  Icons.data_usage),
    ];
    return _BottomSheetContainer(
      title: 'ORDENAR POR',
      child: Column(
        children: [
          ...opts.map((o) {
            final active = currentSort == o.$1;
            return ListTile(
              dense: true,
              leading: Icon(o.$3, color: active ? kAmber : kSteel, size: 18),
              title: Text(
                o.$2,
                style: TextStyle(
                  fontFamily: 'monospace', fontSize: 11,
                  color: active ? kCold : kSteel, letterSpacing: 1,
                ),
              ),
              trailing: active
                  ? Icon(
                      ascending ? Icons.arrow_upward : Icons.arrow_downward,
                      color: kAmber, size: 14,
                    )
                  : null,
              onTap: () => onSelect(o.$1, active ? !ascending : false),
            );
          }),
        ],
      ),
    );
  }
}

class _BottomSheetContainer extends StatelessWidget {
  final String title;
  final Widget child;
  const _BottomSheetContainer({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: kBorder)),
          ),
          child: Row(
            children: [
              Container(width: 3, height: 14, color: kRed, margin: const EdgeInsets.only(right: 10)),
              Text(
                title,
                style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 11,
                  color: kCold, letterSpacing: 2, fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: const Icon(Icons.close, color: kSteel, size: 16),
              ),
            ],
          ),
        ),
        child,
        SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
      ],
    );
  }
}

// ─── SCANLINE PAINTER ─────────────────────────────────────────────────────────
class _ScanlinePainter extends CustomPainter {
  final double t;
  _ScanlinePainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()..color = Colors.black.withOpacity(0.12);
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), linePaint);
    }
    final scanY = (t * size.height * 1.2) % (size.height + 60) - 30;
    final scanPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          kRed.withOpacity(0.04),
          kRed.withOpacity(0.07),
          kRed.withOpacity(0.04),
          Colors.transparent,
        ],
      ).createShader(Rect.fromLTWH(0, scanY, size.width, 60));
    canvas.drawRect(Rect.fromLTWH(0, scanY, size.width, 60), scanPaint);
  }

  @override
  bool shouldRepaint(_ScanlinePainter old) => old.t != t;
}