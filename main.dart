import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:pdfx/pdfx.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppTheme {
  final String name; final Color seed; final Brightness b;
  const AppTheme(this.name, this.seed, this.b);
}
const themes = [
  AppTheme('Light', Color(0xFF6C5CE7), Brightness.light),
  AppTheme('Dark', Color(0xFF6C5CE7), Brightness.dark),
  AppTheme('Ocean', Color(0xFF0288D1), Brightness.light),
  AppTheme('Forest', Color(0xFF2E7D32), Brightness.dark),
  AppTheme('Sunset', Color(0xFFEF6C00), Brightness.light),
];
// inch -> dots at 203 dpi
const dotsFor = {2: 384, 3: 576, 4: 832};

final themeIdx = ValueNotifier<int>(0);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final p = await SharedPreferences.getInstance();
  themeIdx.value = p.getInt('theme') ?? 0;
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => ValueListenableBuilder<int>(
        valueListenable: themeIdx,
        builder: (_, i, __) => MaterialApp(
          title: 'ABH Printer',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(
                  seedColor: themes[i].seed, brightness: themes[i].b)),
          home: const Home(),
        ),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  List<BluetoothInfo> devices = [];
  BluetoothInfo? selected;
  bool connected = false;
  int inch = 2;
  final text = TextEditingController();
  double fontScale = 1;
  bool bold = false;
  int align = 0; // 0 left 1 center 2 right

  static const ch = MethodChannel('abh/text');
  String _lastClip = '';

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _checkClip();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkClip() async {
    try {
      final d = await Clipboard.getData('text/plain');
      final t = d?.text ?? '';
      if (t.trim().isNotEmpty && t != _lastClip && mounted) {
        _lastClip = t;
        setState(() => text.text = t);
        _msg('Copy pannina text vanthuchu - Print Text press pannunga');
      }
    } catch (_) {}
  }

  Future<void> _pull() async {
    try {
      final t = await ch.invokeMethod<String>('get');
      if (t != null && t.isNotEmpty && mounted) {
        setState(() => text.text = t);
        _msg('Text vanthuchu - Print Text press pannunga');
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ch.setMethodCallHandler((c) async { if (c.method == 'new') _pull(); });
    _pull();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkClip());
    _loadPrefs();
    ReceiveSharingIntent.instance.getInitialMedia().then(_onShared);
    ReceiveSharingIntent.instance.getMediaStream().listen(_onShared);
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() => inch = p.getInt('inch') ?? 2);
  }

  void _msg(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  // Notes / gallery / files shared into the app
  Future<void> _onShared(List<SharedMediaFile> files) async {
    for (final f in files) {
      if (f.type == SharedMediaType.text || f.type == SharedMediaType.url) {
        setState(() => text.text = f.path);
        _msg('Shared text vanthuchu - Print Text press pannunga');
      } else if (f.type == SharedMediaType.image) {
        await _printImage(await File(f.path).readAsBytes());
      } else if (f.path.toLowerCase().endsWith('.pdf')) {
        await _printPdf(f.path);
      } else {
        try {
          final t = await File(f.path).readAsString();
          setState(() => text.text = t);
          _msg('Notes text vanthuchu - Print Text press pannunga');
        } catch (_) {
          _msg('Intha file type support illa');
        }
      }
    }
  }

  Future<void> _scan() async {
    await [Permission.bluetoothConnect, Permission.bluetoothScan, Permission.location].request();
    final l = await PrintBluetoothThermal.pairedBluetooths;
    setState(() => devices = l);
    if (l.isEmpty) _msg('Phone Bluetooth settings-la first printer pair pannunga');
  }

  Future<void> _connect(BluetoothInfo d) async {
    final ok = await PrintBluetoothThermal.connect(macPrinterAddress: d.macAdress);
    setState(() { selected = d; connected = ok; });
    _msg(ok ? 'Connected: ${d.name}' : 'Connect aagala');
  }

  Future<Generator> _gen() async {
    final profile = await CapabilityProfile.load();
    return Generator(inch == 2 ? PaperSize.mm58 : PaperSize.mm80, profile);
  }

  Future<void> _send(List<int> bytes) async {
    if (!connected) { _msg('First printer connect pannunga'); return; }
    for (var i = 0; i < bytes.length; i += 1024) {
      final end = (i + 1024 < bytes.length) ? i + 1024 : bytes.length;
      await PrintBluetoothThermal.writeBytes(bytes.sublist(i, end));
      await Future.delayed(const Duration(milliseconds: 30));
    }
  }

  List<int> _imageBytes(Generator g, img.Image im) {
    final w = dotsFor[inch]!;
    final r = img.grayscale(img.copyResize(im, width: w));
    return g.imageRaster(r, align: PosAlign.center);
  }

  Future<void> _printImage(Uint8List data) async {
    final im = img.decodeImage(data);
    if (im == null) { _msg('Image read aagala'); return; }
    final g = await _gen();
    await _send([...g.reset(), ..._imageBytes(g, im), ...g.feed(3), ...g.cut()]);
  }

  Future<void> _printPdf(String path) async {
    final doc = await PdfDocument.openFile(path);
    final g = await _gen();
    List<int> out = g.reset();
    for (var i = 1; i <= doc.pagesCount; i++) {
      final page = await doc.getPage(i);
      final scale = dotsFor[inch]! / page.width;
      final pi = await page.render(
          width: page.width * scale, height: page.height * scale,
          format: PdfPageImageFormat.png, backgroundColor: '#FFFFFF');
      await page.close();
      final im = img.decodePng(pi!.bytes);
      if (im != null) out += _imageBytes(g, im);
    }
    await doc.close();
    await _send([...out, ...g.feed(3), ...g.cut()]);
  }

  Future<void> _printText() async {
    if (text.text.trim().isEmpty) { _msg('Text type pannunga'); return; }
    final g = await _gen();
    final size = fontScale >= 2 ? PosTextSize.size2 : PosTextSize.size1;
    final a = [PosAlign.left, PosAlign.center, PosAlign.right][align];
    await _send([
      ...g.reset(),
      ...g.text(text.text, styles: PosStyles(bold: bold, align: a, height: size, width: size)),
      ...g.feed(3), ...g.cut()
    ]);
  }

  Future<void> _pickImage() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x != null) await _printImage(await x.readAsBytes());
  }

  Future<void> _pickPdf() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (r?.files.single.path != null) await _printPdf(r!.files.single.path!);
  }

  @override
  Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ABH Printer', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          PopupMenuButton<int>(
            icon: const Icon(Icons.palette),
            onSelected: (i) async {
              themeIdx.value = i;
              (await SharedPreferences.getInstance()).setInt('theme', i);
            },
            itemBuilder: (_) => [
              for (var i = 0; i < themes.length; i++)
                PopupMenuItem(value: i, child: Row(children: [
                  CircleAvatar(radius: 8, backgroundColor: themes[i].seed),
                  const SizedBox(width: 10), Text(themes[i].name)]))
            ],
          )
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.bluetooth, color: connected ? Colors.green : cs.outline),
            const SizedBox(width: 8),
            Expanded(child: Text(connected ? 'Connected: ${selected?.name}' : 'Not connected')),
            FilledButton.tonal(onPressed: _scan, child: const Text('Scan')),
          ]),
          for (final d in devices)
            ListTile(dense: true, title: Text(d.name), subtitle: Text(d.macAdress), onTap: () => _connect(d)),
        ]))),
        const SizedBox(height: 12),
        const Text('Paper size'),
        const SizedBox(height: 6),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 2, label: Text('2 inch')),
            ButtonSegment(value: 3, label: Text('3 inch')),
            ButtonSegment(value: 4, label: Text('4 inch')),
          ],
          selected: {inch},
          onSelectionChanged: (s) async {
            setState(() => inch = s.first);
            (await SharedPreferences.getInstance()).setInt('inch', inch);
          },
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: FilledButton.icon(onPressed: _pickImage, icon: const Icon(Icons.image), label: const Text('Image'))),
          const SizedBox(width: 12),
          Expanded(child: FilledButton.icon(onPressed: _pickPdf, icon: const Icon(Icons.picture_as_pdf), label: const Text('PDF'))),
        ]),
        const SizedBox(height: 16),
        TextField(controller: text, maxLines: 6, decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Text inga type / paste pannunga')),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          FilterChip(label: const Text('Bold'), selected: bold, onSelected: (v) => setState(() => bold = v)),
          FilterChip(label: const Text('Big'), selected: fontScale >= 2, onSelected: (v) => setState(() => fontScale = v ? 2 : 1)),
          ChoiceChip(label: const Text('Left'), selected: align == 0, onSelected: (_) => setState(() => align = 0)),
          ChoiceChip(label: const Text('Center'), selected: align == 1, onSelected: (_) => setState(() => align = 1)),
          ChoiceChip(label: const Text('Right'), selected: align == 2, onSelected: (_) => setState(() => align = 2)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: () async {
              final d = await Clipboard.getData('text/plain');
              if (d?.text != null) setState(() => text.text = d!.text!);
            },
            icon: const Icon(Icons.paste), label: const Text('Paste'))),
          const SizedBox(width: 12),
          Expanded(child: FilledButton.icon(onPressed: _printText, icon: const Icon(Icons.print), label: const Text('Print Text'))),
        ]),
        const SizedBox(height: 12),
        Text('Tip: Notes app-la Share -> ABH Printer select pannunga.', style: TextStyle(color: cs.outline)),
      ]),
    );
  }
}
