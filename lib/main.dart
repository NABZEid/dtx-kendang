import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ───────────────────────── SKINS ─────────────────────────

String _hex(Color c) => '#${(c.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

Color? _parseHex(dynamic v) {
  if (v is! String) return null;
  var h = v.replaceAll('#', '').trim();
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return null;
  final n = int.tryParse(h, radix: 16);
  return n == null ? null : Color(n);
}

String skinIdFor(String n) => 'c_${n.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}';

class Skin {
  final String id, name, pattern; // pattern: carbon | rings | plain
  final Color a, b, glow, text;
  final bool custom;
  const Skin(this.id, this.name, this.a, this.b, this.glow,
      {this.text = Colors.white, this.pattern = 'rings', this.custom = false});
  bool get carbon => pattern == 'carbon';

  Map<String, dynamic> toJson() => {
        'name': name,
        'a': _hex(a),
        'b': _hex(b),
        'glow': _hex(glow),
        'text': _hex(text),
        'pattern': pattern,
      };

  static Skin? fromJson(dynamic m) {
    if (m is! Map) return null;
    final name = (m['name'] ?? '').toString().trim();
    final a = _parseHex(m['a']), b = _parseHex(m['b']), glow = _parseHex(m['glow']);
    if (name.isEmpty || a == null || b == null || glow == null) return null;
    final pat = const ['carbon', 'rings', 'plain'].contains(m['pattern']) ? m['pattern'] as String : 'rings';
    return Skin(skinIdFor(name), name, a, b, glow, text: _parseHex(m['text']) ?? Colors.white, pattern: pat, custom: true);
  }
}

const skins = <Skin>[
  Skin('carbon', 'CARBON', Color(0xFF232326), Color(0xFF09090A), Color(0xFF00E5FF), pattern: 'carbon'),
  Skin('neon', 'NEON', Color(0xFF2A0F4A), Color(0xFF0B0620), Color(0xFFFF2BD6)),
  Skin('kendang', 'KENDANG KAYU', Color(0xFF7A4A21), Color(0xFF3A200C), Color(0xFFFFC857)),
  Skin('api', 'API', Color(0xFF8B1A10), Color(0xFF2B0603), Color(0xFFFF7A00)),
  Skin('es', 'ES', Color(0xFF1C4E80), Color(0xFF08182B), Color(0xFF7DF9FF)),
  Skin('matrix', 'MATRIX', Color(0xFF0B3D1B), Color(0xFF03130A), Color(0xFF39FF14)),
];

// ───────────────────────── ENGINE ─────────────────────────

const padNames = ['DUNG', 'TAK', 'TUNG', 'TET', 'PLAK', 'DENG', 'GONG', 'KEMPUL', 'CENG', 'TONG', 'PRANG', 'SLAP'];

class PadSlot {
  String? path;
  String label = '';
  String pack = '';
  AudioSource? src;
}

class LcdState {
  final int pad;
  final String title, sample, pack;
  final double vel;
  final int hits;
  const LcdState(this.pad, this.title, this.sample, this.pack, this.vel, this.hits);
  static const idle = LcdState(-1, 'SIAP', '-', '-', 0, 0);
}

class DrumEngine {
  final slots = List.generate(12, (_) => PadSlot());
  final lcd = ValueNotifier<LcdState>(LcdState.idle);
  final skin = ValueNotifier<Skin>(skins.first);
  final customSkins = <Skin>[];
  List<Skin> get allSkins => [...skins, ...customSkins];
  late Directory root;
  late SharedPreferences prefs;
  int _hits = 0;

  Future<void> init(void Function(double, String) progress) async {
    progress(0.05, 'Menyalakan audio engine...');
    try {
      await SoLoud.instance.init(bufferSize: 512);
    } catch (_) {
      await SoLoud.instance.init();
    }
    progress(0.2, 'Menyiapkan penyimpanan...');
    root = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'dtx'));
    await Directory(p.join(root.path, 'packs')).create(recursive: true);
    prefs = await SharedPreferences.getInstance();
    final cs = prefs.getString('customSkins');
    if (cs != null) {
      try {
        for (final m in jsonDecode(cs) as List) {
          final sk = Skin.fromJson(m);
          if (sk != null) customSkins.add(sk);
        }
      } catch (_) {}
    }
    skin.value = allSkins.firstWhere((s) => s.id == prefs.getString('skin'), orElse: () => skins.first);

    progress(0.3, 'Membuat sample bawaan...');
    final fdir = Directory(p.join(root.path, 'packs', 'FACTORY'));
    await fdir.create(recursive: true);
    for (var i = 0; i < 12; i++) {
      final f = File(p.join(fdir.path, '${(i + 1).toString().padLeft(2, '0')}_${padNames[i]}.wav'));
      if (!await f.exists()) await f.writeAsBytes(_factory(i));
    }

    progress(0.5, 'Memuat mapping pad...');
    List<dynamic>? saved;
    final raw = prefs.getString('map');
    if (raw != null) {
      try {
        saved = jsonDecode(raw) as List<dynamic>;
      } catch (_) {}
    }
    for (var i = 0; i < 12; i++) {
      Map<String, dynamic>? m;
      if (saved != null && i < saved.length && saved[i] != null) m = Map<String, dynamic>.from(saved[i]);
      if (m != null && File(m['path']).existsSync()) {
        await _load(i, m['path'], m['label'], m['pack']);
      } else {
        final path = p.join(fdir.path, '${(i + 1).toString().padLeft(2, '0')}_${padNames[i]}.wav');
        await _load(i, path, p.basename(path), 'FACTORY');
      }
      progress(0.5 + 0.45 * (i + 1) / 12, 'Memuat sample ${i + 1}/12');
    }
    progress(1, 'Siap!');
  }

  Future<void> _load(int i, String path, String label, String pack) async {
    final s = slots[i];
    final old = s.src;
    s.src = null;
    if (old != null) {
      try {
        await SoLoud.instance.disposeSource(old);
      } catch (_) {}
    }
    try {
      s.src = await SoLoud.instance.loadFile(path);
      s.path = path;
      s.label = label;
      s.pack = pack;
    } catch (_) {
      s.path = null;
      s.label = '';
      s.pack = '';
    }
  }

  void trigger(int i, double vel) {
    final s = slots[i];
    final src = s.src;
    if (src != null) SoLoud.instance.play(src, volume: vel.clamp(0.25, 1.0));
    _hits++;
    lcd.value = LcdState(i, '${(i + 1).toString().padLeft(2, '0')} ${padNames[i]}',
        src == null ? '— KOSONG —' : s.label, s.pack.isEmpty ? '-' : s.pack, vel, _hits);
  }

  Future<void> assign(int i, String? path, String pack) async {
    if (path == null) {
      final old = slots[i].src;
      slots[i].src = null;
      slots[i].path = null;
      slots[i].label = '';
      slots[i].pack = '';
      if (old != null) await SoLoud.instance.disposeSource(old);
    } else {
      await _load(i, path, p.basename(path), pack);
    }
    _save();
  }

  void _save() {
    prefs.setString(
        'map',
        jsonEncode(slots
            .map((s) => s.path == null ? null : {'path': s.path, 'label': s.label, 'pack': s.pack})
            .toList()));
  }

  void setSkin(Skin s) {
    skin.value = s;
    prefs.setString('skin', s.id);
  }

  void _saveSkins() => prefs.setString('customSkins', jsonEncode(customSkins.map((s) => s.toJson()).toList()));

  void addSkin(Skin s, {Skin? replacing}) {
    customSkins.removeWhere((e) => e.id == s.id || (replacing != null && e.id == replacing.id));
    customSkins.add(s);
    _saveSkins();
    setSkin(s);
  }

  void deleteSkin(Skin s) {
    customSkins.removeWhere((e) => e.id == s.id);
    _saveSkins();
    if (skin.value.id == s.id) setSkin(skins.first);
  }

  /// Import skin dari file .json (satu skin, list, atau {"skins":[...]}).
  Future<String> importSkin() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = r?.files.single.path;
    if (path == null) return 'Dibatalkan';
    try {
      final data = jsonDecode(await File(path).readAsString());
      final items = data is List ? data : (data is Map && data['skins'] is List ? data['skins'] as List : [data]);
      var n = 0;
      Skin? last;
      for (final m in items) {
        final sk = Skin.fromJson(m);
        if (sk != null) {
          customSkins.removeWhere((e) => e.id == sk.id);
          customSkins.add(sk);
          last = sk;
          n++;
        }
      }
      if (n == 0) return 'File skin tidak valid';
      _saveSkins();
      setSkin(last!);
      return '$n skin diimpor & dipakai';
    } catch (e) {
      return 'Gagal baca skin: $e';
    }
  }

  List<String> packs() {
    final d = Directory(p.join(root.path, 'packs'));
    final l = d.listSync().whereType<Directory>().map((e) => p.basename(e.path)).toList()..sort();
    return l;
  }

  List<File> packFiles(String pack) {
    final d = Directory(p.join(root.path, 'packs', pack));
    if (!d.existsSync()) return [];
    final l = d
        .listSync()
        .whereType<File>()
        .where((f) => const ['.wav', '.mp3'].contains(p.extension(f.path).toLowerCase()))
        .toList()
      ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    return l;
  }

  /// Import ZIP → ekstrak wav/mp3 ke packs/<namaZip>. Return nama pack.
  Future<String?> importZip() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    final path = r?.files.single.path;
    if (path == null) return null;
    final bytes = await File(path).readAsBytes();
    final arc = ZipDecoder().decodeBytes(bytes);
    final name = p.basenameWithoutExtension(path).replaceAll(RegExp(r'[^\w\- ]'), '_');
    final dir = Directory(p.join(root.path, 'packs', name));
    await dir.create(recursive: true);
    var n = 0;
    for (final e in arc) {
      if (!e.isFile) continue;
      final base = p.basename(e.name); // flatten, aman dari zip-slip
      final ext = p.extension(base).toLowerCase();
      if (base.startsWith('.') || (ext != '.wav' && ext != '.mp3')) continue;
      await File(p.join(dir.path, base)).writeAsBytes(e.content as List<int>);
      n++;
    }
    return n == 0 ? null : name;
  }

  /// Import 1 file wav/mp3 untuk satu pad.
  Future<void> importSingle(int i) async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['wav', 'mp3']);
    final path = r?.files.single.path;
    if (path == null) return;
    final dir = Directory(p.join(root.path, 'packs', 'FILE_SENDIRI'));
    await dir.create(recursive: true);
    final dest = p.join(dir.path, p.basename(path));
    await File(path).copy(dest);
    await assign(i, dest, 'FILE_SENDIRI');
  }

  Future<void> autoMap(String pack) async {
    final files = packFiles(pack);
    for (var i = 0; i < 12; i++) {
      await assign(i, i < files.length ? files[i].path : null, pack);
    }
  }

  // sample bawaan sintetis
  Uint8List _factory(int i) {
    const prm = [
      [140.0, 60.0, 7.0, 0.05, 0.7],
      [900.0, 500.0, 35.0, 0.5, 0.15],
      [220.0, 110.0, 10.0, 0.05, 0.5],
      [1200.0, 700.0, 45.0, 0.4, 0.12],
      [600.0, 300.0, 28.0, 0.7, 0.2],
      [320.0, 160.0, 12.0, 0.05, 0.45],
      [90.0, 70.0, 3.0, 0.02, 1.4],
      [120.0, 100.0, 4.0, 0.02, 1.0],
      [3000.0, 2500.0, 18.0, 0.9, 0.4],
      [260.0, 200.0, 9.0, 0.05, 0.5],
      [2000.0, 1500.0, 10.0, 0.9, 0.7],
      [450.0, 200.0, 30.0, 0.8, 0.2],
    ];
    final q = prm[i];
    const sr = 44100;
    final n = (sr * q[4]).round();
    final bd = ByteData(44 + n * 2);
    void str(int o, String s) {
      for (var k = 0; k < s.length; k++) {
        bd.setUint8(o + k, s.codeUnitAt(k));
      }
    }

    str(0, 'RIFF');
    bd.setUint32(4, 36 + n * 2, Endian.little);
    str(8, 'WAVEfmt ');
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little);
    bd.setUint16(22, 1, Endian.little);
    bd.setUint32(24, sr, Endian.little);
    bd.setUint32(28, sr * 2, Endian.little);
    bd.setUint16(32, 2, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    str(36, 'data');
    bd.setUint32(40, n * 2, Endian.little);
    final rnd = math.Random(i + 7);
    var ph = 0.0;
    for (var k = 0; k < n; k++) {
      final t = k / sr;
      final f = q[0] * math.pow(q[1] / q[0], t / q[4]);
      ph += 2 * math.pi * f / sr;
      final env = math.exp(-t * q[2]);
      final v = (math.sin(ph) * (1 - q[3]) + (rnd.nextDouble() * 2 - 1) * q[3]) * env * 0.9;
      bd.setInt16(44 + k * 2, (v.clamp(-1.0, 1.0) * 32767).round(), Endian.little);
    }
    return bd.buffer.asUint8List();
  }
}

// ───────────────────────── APP ─────────────────────────

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: const SplashScreen(),
  ));
}

// ───────────────────────── SPLASH ─────────────────────────

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();
  final eng = DrumEngine();
  final prog = ValueNotifier<double>(0);
  final status = ValueNotifier<String>('Memulai...');
  double _shown = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final t0 = DateTime.now();
    try {
      await eng.init((v, s) {
        prog.value = v;
        status.value = s;
      });
    } catch (e) {
      status.value = 'Error: $e';
      return;
    }
    final left = 2600 - DateTime.now().difference(t0).inMilliseconds;
    if (left > 0) await Future.delayed(Duration(milliseconds: left));
    prog.value = 1;
    await Future.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 700),
      pageBuilder: (_, __, ___) => DrumScreen(eng: eng),
      transitionsBuilder: (_, a, __, child) => FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 1.08, end: 1.0).animate(a), child: child),
      ),
    ));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF05060A),
      body: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final pulse = 0.5 + 0.5 * math.sin(_c.value * 2 * math.pi * 3);
          return Stack(children: [
            Positioned.fill(child: CustomPaint(painter: _SplashPainter(_c.value))),
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(height: 40),
                Text('DTX',
                    style: TextStyle(
                        fontSize: 54,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 14,
                        color: Colors.white,
                        shadows: [Shadow(color: Color.lerp(const Color(0xFF00E5FF), const Color(0xFFFF2BD6), pulse)!, blurRadius: 12 + 22 * pulse)])),
                const Text('KENDANG', style: TextStyle(fontSize: 18, letterSpacing: 10, color: Colors.white70)),
                const SizedBox(height: 90),
                SizedBox(
                  width: 280,
                  child: ValueListenableBuilder<double>(
                    valueListenable: prog,
                    builder: (_, v, __) {
                      _shown += (v - _shown) * 0.2;
                      return TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: v),
                        duration: const Duration(milliseconds: 350),
                        builder: (_, val, __) => ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Stack(children: [
                            Container(height: 8, color: Colors.white12),
                            FractionallySizedBox(
                              widthFactor: val.clamp(0.02, 1.0),
                              child: Container(
                                height: 8,
                                decoration: const BoxDecoration(
                                    gradient: LinearGradient(colors: [Color(0xFF00E5FF), Color(0xFFFF2BD6)])),
                              ),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                ValueListenableBuilder<String>(
                  valueListenable: status,
                  builder: (_, s, __) => Text(s, style: const TextStyle(fontSize: 12, color: Colors.white54, letterSpacing: 2)),
                ),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

class _SplashPainter extends CustomPainter {
  final double t;
  _SplashPainter(this.t);
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * 0.42);
    final r = math.min(size.width, size.height) * 0.32;
    final cols = [const Color(0xFF00E5FF), const Color(0xFFFF2BD6), const Color(0xFFFFC857)];
    for (var i = 0; i < 3; i++) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 - i * 0.6
        ..strokeCap = StrokeCap.round
        ..color = cols[i].withOpacity(0.8);
      final rr = r + i * 22;
      final dir = i.isEven ? 1 : -1;
      final start = t * 2 * math.pi * (i + 1) * dir;
      canvas.drawArc(Rect.fromCircle(center: c, radius: rr), start, 1.6, false, paint);
      canvas.drawArc(Rect.fromCircle(center: c, radius: rr), start + math.pi, 0.9, false, paint);
    }
    for (var i = 0; i < 14; i++) {
      final a = t * 2 * math.pi + i * math.pi * 2 / 14;
      final rr = r + 70 + 12 * math.sin(t * 2 * math.pi * 4 + i);
      canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * rr, 2.5,
          Paint()..color = cols[i % 3].withOpacity(0.7));
    }
    // bar equalizer bawah
    for (var i = 0; i < 40; i++) {
      final h = 8 + 26 * (0.5 + 0.5 * math.sin(t * 2 * math.pi * 3 + i * 0.5));
      final x = size.width / 2 - 20 * 8 + i * 8.0;
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(x, size.height - 20 - h, 4, h), const Radius.circular(2)),
          Paint()..color = cols[i % 3].withOpacity(0.35));
    }
  }

  @override
  bool shouldRepaint(_SplashPainter o) => true;
}

// ───────────────────────── DRUM SCREEN ─────────────────────────

class DrumScreen extends StatefulWidget {
  final DrumEngine eng;
  const DrumScreen({super.key, required this.eng});
  @override
  State<DrumScreen> createState() => _DrumScreenState();
}

class _DrumScreenState extends State<DrumScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _bg = AnimationController(vsync: this, duration: const Duration(seconds: 24))..repeat();
  DrumEngine get eng => widget.eng;

  @override
  void dispose() {
    _bg.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ValueListenableBuilder<Skin>(
        valueListenable: eng.skin,
        builder: (_, skin, __) => Stack(children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _bg,
                builder: (_, __) => CustomPaint(painter: _BgPainter(_bg.value, skin)),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              child: Column(children: [
                _topBar(skin),
                Expanded(
                  child: Column(children: [
                    for (var r = 0; r < 2; r++)
                      Expanded(
                        child: Row(children: [
                          for (var c = 0; c < 6; c++)
                            Expanded(child: Padding(padding: const EdgeInsets.all(4), child: PadWidget(index: r * 6 + c, eng: eng, skin: skin))),
                        ]),
                      ),
                  ]),
                ),
                LcdPanel(eng: eng, skin: skin),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _topBar(Skin skin) {
    return SizedBox(
      height: 40,
      child: Row(children: [
        Text('DTX KENDANG',
            style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 4, color: Colors.white, shadows: [Shadow(color: skin.glow, blurRadius: 12)])),
        const Spacer(),
        _btn(Icons.palette_outlined, 'Skin', () => _skinSheet()),
        _btn(Icons.folder_zip_outlined, 'Import ZIP', () => _importZip()),
        _btn(Icons.tune, 'Mapping', () => _mapSheet()),
      ]),
    );
  }

  Widget _btn(IconData i, String tip, VoidCallback f) => IconButton(icon: Icon(i, color: Colors.white), tooltip: tip, onPressed: f);

  void _skinSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111114),
      builder: (_) => SkinSheet(eng: eng),
    );
  }

  Future<void> _importZip() async {
    final m = ScaffoldMessenger.of(context);
    m.showSnackBar(const SnackBar(content: Text('Mengimpor ZIP...'), duration: Duration(seconds: 1)));
    try {
      final name = await eng.importZip();
      if (!mounted) return;
      if (name == null) {
        m.showSnackBar(const SnackBar(content: Text('Tidak ada wav/mp3 di ZIP atau dibatalkan')));
      } else {
        m.showSnackBar(SnackBar(content: Text('ZIP "$name" diimpor. Atur mapping.')));
        _mapSheet(initialPack: name);
      }
    } catch (e) {
      m.showSnackBar(SnackBar(content: Text('Gagal import: $e')));
    }
  }

  void _mapSheet({String? initialPack}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111114),
      builder: (_) => MappingSheet(eng: eng, initialPack: initialPack),
    );
  }
}

// ───────────────────────── PAD ─────────────────────────

class PadWidget extends StatefulWidget {
  final int index;
  final DrumEngine eng;
  final Skin skin;
  const PadWidget({super.key, required this.index, required this.eng, required this.skin});
  @override
  State<PadWidget> createState() => _PadWidgetState();
}

class _PadWidgetState extends State<PadWidget> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 380), value: 1);
  bool _down = false;
  Offset _hit = Offset.zero;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _onDown(PointerDownEvent e) {
    final size = context.size ?? const Size(100, 100);
    final d = (e.localPosition - size.center(Offset.zero));
    final nd = math.sqrt(math.pow(d.dx / (size.width / 2), 2) + math.pow(d.dy / (size.height / 2), 2));
    final vel = (1.0 - nd * 0.35).clamp(0.5, 1.0);
    widget.eng.trigger(widget.index, vel); // langsung bunyi, tanpa menunggu gesture
    _hit = e.localPosition;
    _c.forward(from: 0);
    setState(() => _down = true);
  }

  @override
  Widget build(BuildContext context) {
    final skin = widget.skin;
    final slot = widget.eng.slots[widget.index];
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerUp: (_) => setState(() => _down = false),
      onPointerCancel: (_) => setState(() => _down = false),
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, child) {
          final g = 1 - Curves.easeOut.transform(_c.value);
          return Transform.scale(
            scale: _down ? 0.96 : 1 - 0.03 * g,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                boxShadow: [BoxShadow(color: skin.glow.withOpacity(0.15 + 0.7 * g), blurRadius: 6 + 26 * g, spreadRadius: 1 + 3 * g)],
              ),
              child: Stack(fit: StackFit.expand, children: [
                RepaintBoundary(child: CustomPaint(painter: PadPainter(skin))),
                CustomPaint(painter: _RipplePainter(_hit, 1 - g, g, skin.glow)),
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: skin.glow.withOpacity(0.28 * g + (_down ? 0.12 : 0)),
                  ),
                ),
                child!,
              ]),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${widget.index + 1}', style: TextStyle(fontSize: 11, color: skin.text.withOpacity(0.6), fontWeight: FontWeight.bold)),
            Center(child: Text(padNames[widget.index], style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2, fontSize: 16, color: skin.text))),
            Text(slot.label.isEmpty ? '-' : slot.label,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 8.5, color: skin.text.withOpacity(0.6))),
          ]),
        ),
      ),
    );
  }
}

class PadPainter extends CustomPainter {
  final Skin s;
  PadPainter(this.s);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rr = RRect.fromRectAndRadius(rect, const Radius.circular(14));
    canvas.save();
    canvas.clipRRect(rr);
    canvas.drawRect(rect, Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [s.a, s.b]).createShader(rect));
    if (s.carbon) {
      const c = 6.0;
      final light = Paint()..color = const Color(0x1EFFFFFF);
      final dark = Paint()..color = const Color(0x40000000);
      for (var i = 0; i < size.width / c; i++) {
        for (var j = 0; j < size.height / c; j++) {
          if ((i + j).isEven) {
            canvas.drawRect(Rect.fromLTWH(i * c, j * c, c, c / 2), light);
            canvas.drawRect(Rect.fromLTWH(i * c, j * c + c / 2, c, c / 2), dark);
          } else {
            canvas.drawRect(Rect.fromLTWH(i * c, j * c, c / 2, c), light);
            canvas.drawRect(Rect.fromLTWH(i * c + c / 2, j * c, c / 2, c), dark);
          }
        }
      }
    } else if (s.pattern == 'rings') {
      final light = s.a.computeLuminance() > 0.5;
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = (light ? Colors.black : Colors.white).withOpacity(light ? 0.08 : 0.07);
      final m = math.min(size.width, size.height);
      for (var k = 1; k <= 4; k++) {
        canvas.drawCircle(size.center(Offset.zero), m * 0.15 * k, ring);
      }
    }
    // kilau atas
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height * 0.4),
        Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.white.withOpacity(0.10), Colors.transparent]).createShader(Rect.fromLTWH(0, 0, size.width, size.height * 0.4)));
    canvas.restore();
    canvas.drawRRect(rr, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = s.glow.withOpacity(0.55));
  }

  @override
  bool shouldRepaint(PadPainter o) => !identical(o.s, s);
}

class _RipplePainter extends CustomPainter {
  final Offset o;
  final double t, g;
  final Color color;
  _RipplePainter(this.o, this.t, this.g, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    if (g <= 0.01) return;
    canvas.drawCircle(o, 10 + t * size.width * 0.7, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 * g
      ..color = color.withOpacity(0.8 * g));
  }

  @override
  bool shouldRepaint(_RipplePainter o) => true;
}

// ───────────────────────── LCD ─────────────────────────

class LcdPanel extends StatelessWidget {
  final DrumEngine eng;
  final Skin skin;
  const LcdPanel({super.key, required this.eng, required this.skin});

  @override
  Widget build(BuildContext context) {
    const lcdColor = Color(0xFF9CFF7A);
    return Container(
      height: 74,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF061106),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: skin.glow.withOpacity(0.6), width: 1.5),
        boxShadow: [BoxShadow(color: skin.glow.withOpacity(0.25), blurRadius: 14)],
      ),
      child: ValueListenableBuilder<LcdState>(
        valueListenable: eng.lcd,
        builder: (_, s, __) => Row(children: [
          SizedBox(
            width: 170,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('PAD', style: TextStyle(fontSize: 9, color: Color(0x889CFF7A), fontFamily: 'monospace')),
              Text(s.title, style: const TextStyle(fontSize: 22, color: lcdColor, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
            ]),
          ),
          Container(width: 1, color: const Color(0x449CFF7A), margin: const EdgeInsets.symmetric(horizontal: 10)),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('SAMPLE: ${s.sample}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: lcdColor, fontFamily: 'monospace')),
              const SizedBox(height: 4),
              Text('ZIP   : ${s.pack}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: lcdColor, fontFamily: 'monospace')),
            ]),
          ),
          Container(width: 1, color: const Color(0x449CFF7A), margin: const EdgeInsets.symmetric(horizontal: 10)),
          SizedBox(
            width: 190,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              // LED level (animasi turun cepat)
              TweenAnimationBuilder<double>(
                key: ValueKey(s.hits),
                tween: Tween(begin: s.vel, end: 0),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOut,
                builder: (_, v, __) => Row(children: [
                  for (var i = 0; i < 16; i++)
                    Expanded(
                      child: Container(
                        height: 10,
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(2),
                          color: i < v * 16
                              ? (i < 10 ? const Color(0xFF39FF14) : i < 14 ? const Color(0xFFFFE600) : const Color(0xFFFF3B30))
                              : Colors.white10,
                        ),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 8),
              // indikator 12 pad
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                for (var i = 0; i < 12; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 90),
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: s.pad == i ? skin.glow : Colors.white12,
                      boxShadow: s.pad == i ? [BoxShadow(color: skin.glow, blurRadius: 8)] : null,
                    ),
                  ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ───────────────────────── MAPPING ─────────────────────────

class MappingSheet extends StatefulWidget {
  final DrumEngine eng;
  final String? initialPack;
  const MappingSheet({super.key, required this.eng, this.initialPack});
  @override
  State<MappingSheet> createState() => _MappingSheetState();
}

class _MappingSheetState extends State<MappingSheet> {
  late String pack;
  DrumEngine get eng => widget.eng;

  @override
  void initState() {
    super.initState();
    final all = eng.packs();
    pack = widget.initialPack ?? (eng.slots.first.pack.isNotEmpty && all.contains(eng.slots.first.pack) ? eng.slots.first.pack : (all.isNotEmpty ? all.first : 'FACTORY'));
  }

  @override
  Widget build(BuildContext context) {
    final packs = eng.packs();
    if (!packs.contains(pack) && packs.isNotEmpty) pack = packs.first;
    final files = eng.packFiles(pack);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.92,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(children: [
              const Text('MAPPING SAMPLE', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2)),
              const SizedBox(width: 16),
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: packs.contains(pack) ? pack : null,
                  items: [for (final k in packs) DropdownMenuItem(value: k, child: Text(k, overflow: TextOverflow.ellipsis))],
                  onChanged: (v) => setState(() => pack = v!),
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.auto_fix_high, size: 18),
                label: const Text('Auto'),
                onPressed: () async {
                  await eng.autoMap(pack);
                  setState(() {});
                },
              ),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: 12,
              itemBuilder: (_, i) {
                final slot = eng.slots[i];
                final cur = files.any((f) => f.path == slot.path) ? slot.path : null;
                return ListTile(
                  dense: true,
                  leading: CircleAvatar(radius: 14, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
                  title: Row(children: [
                    SizedBox(width: 70, child: Text(padNames[i], style: const TextStyle(fontWeight: FontWeight.bold))),
                    Expanded(
                      child: DropdownButton<String?>(
                        isExpanded: true,
                        value: cur,
                        hint: Text(slot.path == null ? '— kosong —' : '${slot.label} (${slot.pack})', overflow: TextOverflow.ellipsis),
                        items: [
                          const DropdownMenuItem<String?>(value: null, child: Text('— kosong —')),
                          for (final f in files) DropdownMenuItem<String?>(value: f.path, child: Text(p.basename(f.path), overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: (v) async {
                          await eng.assign(i, v, pack);
                          setState(() {});
                        },
                      ),
                    ),
                  ]),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(icon: const Icon(Icons.play_arrow), onPressed: () => eng.trigger(i, 0.9)),
                    IconButton(
                      icon: const Icon(Icons.audio_file_outlined),
                      tooltip: 'Pilih file wav/mp3',
                      onPressed: () async {
                        await eng.importSingle(i);
                        setState(() {});
                      },
                    ),
                  ]),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

// ───────────────────────── BACKGROUND ─────────────────────────

class _BgPainter extends CustomPainter {
  final double t;
  final Skin s;
  _BgPainter(this.t, this.s);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [const Color(0xFF07080D), Color.lerp(const Color(0xFF07080D), s.glow, 0.08)!]).createShader(rect));
    for (var i = 0; i < 6; i++) {
      final a = t * 2 * math.pi + i * 1.05;
      final o = Offset(size.width * (0.5 + 0.42 * math.sin(a * (0.6 + i * 0.1))), size.height * (0.5 + 0.4 * math.cos(a * 0.8 + i)));
      canvas.drawCircle(o, 90 + i * 12, Paint()
        ..color = s.glow.withOpacity(0.05)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 50));
    }
  }

  @override
  bool shouldRepaint(_BgPainter o) => true;
}


// ───────────────────────── SKIN SHEET / EDITOR ─────────────────────────

class SkinSheet extends StatefulWidget {
  final DrumEngine eng;
  const SkinSheet({super.key, required this.eng});
  @override
  State<SkinSheet> createState() => _SkinSheetState();
}

class _SkinSheetState extends State<SkinSheet> {
  DrumEngine get eng => widget.eng;
  String msg = 'Tekan lama skin buatanmu untuk edit / hapus.';

  Future<void> _edit(Skin? s) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111114),
      builder: (_) => SkinEditor(eng: eng, editing: s),
    );
    if (mounted) setState(() {});
  }

  Future<void> _menu(Skin s) async {
    final act = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(title: Text(s.name), children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(context, 'edit'), child: const Text('Edit')),
        SimpleDialogOption(onPressed: () => Navigator.pop(context, 'del'), child: const Text('Hapus')),
      ]),
    );
    if (act == 'edit') {
      await _edit(s);
    } else if (act == 'del') {
      eng.deleteSkin(s);
      setState(() => msg = 'Skin "${s.name}" dihapus');
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = eng.allSkins;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(children: [
              const Text('SKIN', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 3)),
              const Spacer(),
              TextButton.icon(icon: const Icon(Icons.brush, size: 18), label: const Text('Buat skin'), onPressed: () => _edit(null)),
              TextButton.icon(
                icon: const Icon(Icons.file_open_outlined, size: 18),
                label: const Text('Import .json'),
                onPressed: () async {
                  final m = await eng.importSkin();
                  if (mounted) setState(() => msg = m);
                },
              ),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Wrap(spacing: 12, runSpacing: 12, children: [for (final s in all) _tile(s)]),
            ),
          ),
          Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(msg, style: const TextStyle(fontSize: 12, color: Colors.white54))),
        ]),
      ),
    );
  }

  Widget _tile(Skin s) {
    final sel = eng.skin.value.id == s.id;
    return GestureDetector(
      onTap: () {
        eng.setSkin(s);
        Navigator.pop(context);
      },
      onLongPress: s.custom ? () => _menu(s) : null,
      child: Container(
        width: 120,
        height: 70,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [s.a, s.b]),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: s.glow, width: sel ? 3 : 1),
          boxShadow: sel ? [BoxShadow(color: s.glow.withOpacity(0.5), blurRadius: 10)] : null,
        ),
        child: Text(s.name, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: s.text)),
      ),
    );
  }
}

class SkinEditor extends StatefulWidget {
  final DrumEngine eng;
  final Skin? editing;
  const SkinEditor({super.key, required this.eng, this.editing});
  @override
  State<SkinEditor> createState() => _SkinEditorState();
}

class _SkinEditorState extends State<SkinEditor> {
  late final TextEditingController nameC;
  late Color a, b, glow, text;
  late String pattern;
  String msg = '';

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    nameC = TextEditingController(text: e?.name ?? 'SKIN BARU');
    a = e?.a ?? const Color(0xFF2B2B33);
    b = e?.b ?? const Color(0xFF0B0B10);
    glow = e?.glow ?? const Color(0xFF00E5FF);
    text = e?.text ?? Colors.white;
    pattern = e?.pattern ?? 'rings';
  }

  @override
  void dispose() {
    nameC.dispose();
    super.dispose();
  }

  Skin get draft {
    final n = nameC.text.trim().isEmpty ? 'SKIN' : nameC.text.trim();
    return Skin(skinIdFor(n), n, a, b, glow, text: text, pattern: pattern, custom: true);
  }

  void _white() => setState(() {
        nameC.text = 'PUTIH';
        a = const Color(0xFFFFFFFF);
        b = const Color(0xFFD5D9E0);
        glow = const Color(0xFF00A2FF);
        text = const Color(0xFF1A1A1A);
        pattern = 'rings';
      });

  Widget _colorRow(String label, Color c, ValueChanged<Color> set) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Container(width: 30, height: 30, decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: Colors.white54))),
      title: Text(label),
      subtitle: Text(_hex(c), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      trailing: const Icon(Icons.colorize, size: 18),
      onTap: () async {
        final r = await showDialog<Color>(context: context, builder: (_) => _ColorDialog(initial: c));
        if (r != null) setState(() => set(r));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = draft;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.92,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 220,
              child: Column(children: [
                Container(
                  width: 200,
                  height: 125,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), boxShadow: [BoxShadow(color: d.glow.withOpacity(0.5), blurRadius: 18)]),
                  child: Stack(fit: StackFit.expand, children: [
                    CustomPaint(painter: PadPainter(d)),
                    Center(child: Text('KENDANG', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2, fontSize: 18, color: d.text))),
                  ]),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.check),
                    label: const Text('Simpan & pakai'),
                    onPressed: () {
                      widget.eng.addSkin(draft, replacing: widget.editing);
                      Navigator.pop(context);
                    },
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Salin JSON'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(draft.toJson())));
                    setState(() => msg = 'JSON disalin');
                  },
                ),
                TextButton.icon(icon: const Icon(Icons.format_color_reset, size: 16), label: const Text('Mulai dari putih'), onPressed: _white),
                Text(msg, style: const TextStyle(fontSize: 11, color: Colors.white54)),
              ]),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: ListView(children: [
                TextField(controller: nameC, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Nama skin', isDense: true)),
                const SizedBox(height: 8),
                _colorRow('Warna pad A (atas)', a, (c) => a = c),
                _colorRow('Warna pad B (bawah)', b, (c) => b = c),
                _colorRow('Warna glow / garis', glow, (c) => glow = c),
                _colorRow('Warna teks', text, (c) => text = c),
                const SizedBox(height: 8),
                const Text('Pola', style: TextStyle(fontSize: 12, color: Colors.white54)),
                const SizedBox(height: 4),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'carbon', label: Text('Karbon')),
                    ButtonSegment(value: 'rings', label: Text('Ring')),
                    ButtonSegment(value: 'plain', label: Text('Polos')),
                  ],
                  selected: {pattern},
                  onSelectionChanged: (v) => setState(() => pattern = v.first),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ColorDialog extends StatefulWidget {
  final Color initial;
  const _ColorDialog({required this.initial});
  @override
  State<_ColorDialog> createState() => _ColorDialogState();
}

class _ColorDialogState extends State<_ColorDialog> {
  late int r, g, b;
  late final TextEditingController hex;
  static const palette = [
    0xFFFFFFFF, 0xFFD5D9E0, 0xFF9AA0A6, 0xFF111111, 0xFF000000, 0xFFFF2BD6, 0xFFFF3B30,
    0xFFFF7A00, 0xFFFFC857, 0xFF39FF14, 0xFF00E5FF, 0xFF00A2FF, 0xFF1C4E80, 0xFF7A4A21, 0xFF7B2FFF,
  ];

  @override
  void initState() {
    super.initState();
    final v = widget.initial.value;
    r = (v >> 16) & 255;
    g = (v >> 8) & 255;
    b = v & 255;
    hex = TextEditingController(text: _hex(widget.initial));
  }

  @override
  void dispose() {
    hex.dispose();
    super.dispose();
  }

  Color get color => Color.fromARGB(255, r, g, b);

  void _set(int rr, int gg, int bb, {bool syncText = true}) {
    setState(() {
      r = rr;
      g = gg;
      b = bb;
    });
    if (syncText) hex.text = _hex(color);
  }

  Widget _sl(String l, int v, Color c, ValueChanged<int> f) => Row(children: [
        SizedBox(width: 18, child: Text(l)),
        Expanded(child: Slider(value: v.toDouble(), min: 0, max: 255, activeColor: c, onChanged: (x) => f(x.round()))),
        SizedBox(width: 30, child: Text('$v', style: const TextStyle(fontSize: 12))),
      ]);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pilih warna'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(height: 36, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white38))),
            _sl('R', r, Colors.red, (v) => _set(v, g, b)),
            _sl('G', g, Colors.green, (v) => _set(r, v, b)),
            _sl('B', b, Colors.blue, (v) => _set(r, g, v)),
            TextField(
              controller: hex,
              decoration: const InputDecoration(labelText: 'Hex (#RRGGBB)', isDense: true),
              onChanged: (t) {
                final c = _parseHex(t);
                if (c != null) _set((c.value >> 16) & 255, (c.value >> 8) & 255, c.value & 255, syncText: false);
              },
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in palette)
                GestureDetector(
                  onTap: () => _set((p >> 16) & 255, (p >> 8) & 255, p & 255),
                  child: Container(width: 28, height: 28, decoration: BoxDecoration(color: Color(p), shape: BoxShape.circle, border: Border.all(color: Colors.white38))),
                ),
            ]),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(onPressed: () => Navigator.pop(context, color), child: const Text('OK')),
      ],
    );
  }
}
