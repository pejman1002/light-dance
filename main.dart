import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() => runApp(const App());

enum Mode { solid, rainbow, breathe, chase, strobe, sparkle, seq, hw }

const names = {
  Mode.solid: 'رنگ ثابت',
  Mode.rainbow: 'رنگین‌کمان',
  Mode.breathe: 'تنفس',
  Mode.chase: 'تعقیب',
  Mode.strobe: 'چشمک',
  Mode.sparkle: 'جرقه',
  Mode.seq: 'سکانس من',
  Mode.hw: 'افکت داخلی',
};

int b8(double v) => v.round().clamp(0, 255).toInt();

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFF7A3CFF),
            brightness: Brightness.dark),
        builder: (c, w) =>
            Directionality(textDirection: TextDirection.rtl, child: w!),
        home: const Home(),
      );
}

class Step {
  List<int> c;
  double t;
  Step(this.c, this.t);
}

class Strip extends CustomPainter {
  final List<List<double>> l;
  Strip(this.l);
  @override
  void paint(Canvas cv, Size s) {
    cv.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF0C0B14));
    for (var i = 0; i < l.length; i++) {
      final c = l[i];
      final col = Color.fromARGB(255, b8(c[0]), b8(c[1]), b8(c[2]));
      final o = Offset((i + .5) * s.width / l.length, s.height / 2);
      cv.drawCircle(o, 11,
          Paint()
            ..color = col
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      cv.drawCircle(o, 7, Paint()..color = col);
    }
  }

  @override
  bool shouldRepaint(Strip o) => true;
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _H();
}

class _H extends State<Home> {
  static const n = 24;
  List<int> col = [122, 60, 255];
  double bri = 100, spd = 5;
  Mode mode = Mode.rainbow;
  bool fade = true;
  List<Step> seq = [
    Step([255, 0, 0], 1),
    Step([0, 255, 0], 1),
    Step([0, 0, 255], 1)
  ];
  String ord = 'RGB';
  int hw = 1;
  final hwC = TextEditingController(text: '1');
  BluetoothCharacteristic? ch;
  BluetoothDevice? dev;
  String status = 'متصل نیست';
  bool needStatic = true, busy = false;
  final sk = List<double>.filled(n, 0);
  final rnd = Random();
  final sw = Stopwatch()..start();
  Timer? tm;
  List<List<double>> L = [];

  @override
  void initState() {
    super.initState();
    L = frame(0);
    tm = Timer.periodic(const Duration(milliseconds: 80), (_) {
      L = frame(sw.elapsedMilliseconds / 1000);
      tick();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    tm?.cancel();
    super.dispose();
  }

  List<double> hsv(double h, double s, double v) {
    double f(int k0) {
      final k = (k0 + h / 60) % 6;
      return (v - v * s * max(0.0, min(min(k, 4 - k), 1.0))) * 255;
    }

    return [f(5), f(3), f(1)];
  }

  List<double> seqAt(double u) {
    if (seq.isEmpty) return [0, 0, 0];
    final total = seq.fold<double>(0, (s, e) => s + e.t);
    u = u % total;
    var i = 0;
    while (i < seq.length - 1 && u >= seq[i].t) {
      u -= seq[i].t;
      i++;
    }
    final a = seq[i].c, b = seq[(i + 1) % seq.length].c;
    final f = fade ? (u / seq[i].t).clamp(0.0, 1.0).toDouble() : 0.0;
    return List.generate(3, (k) => a[k] + (b[k] - a[k]) * f);
  }

  List<List<double>> frame(double t) {
    final a = spd / 5;
    final c = col.map((e) => e.toDouble()).toList();
    final o = <List<double>>[];
    for (var i = 0; i < n; i++) {
      List<double> x;
      switch (mode) {
        case Mode.rainbow:
          x = hsv((i / n * 360 + t * a * 60) % 360, 1, 1);
          break;
        case Mode.breathe:
          final k = .5 + .5 * sin(t * a * 2);
          x = c.map((v) => v * k).toList();
          break;
        case Mode.chase:
          final d = ((t * a * 6 - i) % n + n) % n;
          final k = max(0.0, 1 - d / 6);
          x = c.map((v) => v * k).toList();
          break;
        case Mode.strobe:
          x = ((t * a * 4).floor() % 2 == 1) ? c : [0.0, 0.0, 0.0];
          break;
        case Mode.sparkle:
          sk[i] = max(sk[i] * .92, rnd.nextDouble() < .03 * a ? 1.0 : 0.0);
          x = c.map((v) => v * sk[i]).toList();
          break;
        case Mode.seq:
          x = seqAt(t * a);
          break;
        default:
          x = c;
      }
      o.add(x.map((v) => v * bri / 100).toList());
    }
    return o;
  }

  // ---- بلوتوث (پروتکل BanlanX برای SP621E) ----
  List<int> hexb(String s) => RegExp(r'[0-9a-fA-F]{2}')
      .allMatches(s)
      .map((m) => int.parse(m.group(0)!, radix: 16))
      .toList();

  Future<void> send(List<int> d) async {
    if (ch == null) return;
    try {
      await ch!.write(d, withoutResponse: true);
    } catch (_) {}
  }

  Future<void> tick() async {
    if (ch == null || busy || mode == Mode.hw || L.isEmpty) return;
    busy = true;
    try {
      if (needStatic) {
        await send(hexb('A0 63 01 BE'));
        needStatic = false;
      }
      final c = L[0].map((v) => b8(v)).toList();
      final o = ord.split('').map((k) => c['RGB'.indexOf(k)]).toList();
      await send([0xA0, 0x69, 0x04, o[0], o[1], o[2], 0xFF]);
    } finally {
      busy = false;
    }
  }

  Future<void> connect() async {
    try {
      setState(() => status = 'در حال اسکن...');
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
      await FlutterBluePlus.isScanning.where((s) => s == false).first;
      final list = FlutterBluePlus.lastScanResults
          .where((r) => r.device.platformName.isNotEmpty)
          .toList();
      if (!mounted) return;
      if (list.isEmpty) {
        setState(() => status = 'دستگاهی پیدا نشد. بلوتوث و موقعیت را روشن کن.');
        return;
      }
      final pick = await showDialog<BluetoothDevice>(
          context: context,
          builder: (c) => SimpleDialog(
                title: const Text('انتخاب دستگاه'),
                children: [
                  for (final r in list)
                    SimpleDialogOption(
                        onPressed: () => Navigator.pop(c, r.device),
                        child: Text(r.device.platformName))
                ],
              ));
      if (pick == null) {
        setState(() => status = 'متصل نیست');
        return;
      }
      setState(() => status = 'در حال اتصال...');
      await pick.connect();
      final ss = await pick.discoverServices();
      for (final s in ss) {
        if (s.uuid.toString().toLowerCase().contains('ffe0')) {
          for (final x in s.characteristics) {
            if (x.uuid.toString().toLowerCase().contains('ffe1')) ch = x;
          }
        }
      }
      if (ch == null) {
        setState(() => status = 'سرویس FFE0 پیدا نشد');
        await pick.disconnect();
        return;
      }
      dev = pick;
      pick.connectionState.listen((st) {
        if (st == BluetoothConnectionState.disconnected && mounted) {
          ch = null;
          setState(() => status = 'اتصال قطع شد');
        }
      });
      await send(hexb('A0 62 01 01'));
      await send(hexb('A0 63 01 BE'));
      needStatic = false;
      setState(() => status = 'متصل به ${pick.platformName}');
    } catch (e) {
      setState(() => status = 'خطا: $e');
    }
  }

  Future<void> disconnect() async {
    await dev?.disconnect();
    setState(() {
      ch = null;
      status = 'متصل نیست';
    });
  }

  // ---- رابط کاربری ----
  void _solid() {
    if (mode == Mode.rainbow || mode == Mode.seq || mode == Mode.hw) {
      mode = Mode.solid;
      needStatic = true;
    }
  }

  Widget card(String t, List<Widget> c) => Card(
      child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t, style: const TextStyle(fontWeight: FontWeight.bold)),
                ...c
              ])));

  Widget sl(String t, double v, double lo, double hi, void Function(double) f,
          [Color? c]) =>
      Row(children: [
        SizedBox(width: 56, child: Text(t)),
        Expanded(
            child: Slider(
                value: v,
                min: lo,
                max: hi,
                activeColor: c,
                onChanged: (x) => setState(() => f(x)))),
        SizedBox(width: 34, child: Text(v.round().toString())),
      ]);

  @override
  Widget build(BuildContext ctx) {
    final hexS = '#${col.map((v) => v.toRadixString(16).padLeft(2, '0')).join()}';
    return Scaffold(
      appBar: AppBar(title: const Text('رقص نور'), actions: [
        TextButton(
            onPressed: ch == null ? connect : disconnect,
            child: Text(ch == null ? 'اتصال' : 'قطع'))
      ]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Text(status),
        const SizedBox(height: 8),
        SizedBox(
            height: 64,
            child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CustomPaint(painter: Strip(L)))),
        card('رنگ', [
          Row(children: [
            Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                    color: Color.fromARGB(255, col[0], col[1], col[2]),
                    borderRadius: BorderRadius.circular(10))),
            const SizedBox(width: 12),
            SizedBox(
                width: 130,
                child: TextFormField(
                    key: ValueKey(hexS),
                    initialValue: hexS,
                    decoration: const InputDecoration(labelText: 'HEX'),
                    onFieldSubmitted: (s) {
                      final m = RegExp(r'^#?([0-9a-fA-F]{6})$')
                          .firstMatch(s.trim());
                      if (m != null) {
                        final v = int.parse(m.group(1)!, radix: 16);
                        setState(() {
                          col = [(v >> 16) & 255, (v >> 8) & 255, v & 255];
                          _solid();
                        });
                      }
                    })),
          ]),
          sl('قرمز', col[0].toDouble(), 0, 255, (x) {
            col[0] = x.round();
            _solid();
          }, Colors.red),
          sl('سبز', col[1].toDouble(), 0, 255, (x) {
            col[1] = x.round();
            _solid();
          }, Colors.green),
          sl('آبی', col[2].toDouble(), 0, 255, (x) {
            col[2] = x.round();
            _solid();
          }, Colors.blue),
          sl('روشنایی', bri, 1, 100, (x) {
            bri = x;
            if (mode == Mode.hw) send([0xA0, 0x66, 0x01, b8(bri * 2.55)]);
          }),
          sl('سرعت', spd, 1, 10, (x) => spd = x),
        ]),
        card('افکت', [
          Wrap(spacing: 8, children: [
            for (final m in Mode.values.where((m) => m != Mode.hw))
              ChoiceChip(
                  label: Text(names[m]!),
                  selected: mode == m,
                  onSelected: (_) => setState(() {
                        mode = m;
                        needStatic = true;
                      }))
          ]),
        ]),
        card('سکانس من', [
          for (var i = 0; i < seq.length; i++)
            Row(children: [
              Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                      color: Color.fromARGB(
                          255, seq[i].c[0], seq[i].c[1], seq[i].c[2]),
                      shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Text('${seq[i].t.toStringAsFixed(1)} ثانیه'),
              const Spacer(),
              IconButton(
                  icon: const Icon(Icons.remove),
                  onPressed: () =>
                      setState(() => seq[i].t = max(.2, seq[i].t - .2))),
              IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () => setState(() => seq[i].t += .2)),
              IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => seq.removeAt(i))),
            ]),
          Wrap(spacing: 8, children: [
            FilledButton.tonal(
                onPressed: () => setState(() => seq.add(Step([...col], 1))),
                child: const Text('افزودن رنگ فعلی')),
            FilledButton(
                onPressed: () => setState(() {
                      mode = Mode.seq;
                      needStatic = true;
                    }),
                child: const Text('اجرای سکانس')),
          ]),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('محو نرم بین رنگ‌ها'),
              value: fade,
              onChanged: (v) => setState(() => fade = v)),
        ]),
        card('افکت داخلی کنترلر', [
          const Text('شمارهٔ افکت ذخیره‌شده در SP621E (190 = رنگ ثابت)'),
          Row(children: [
            SizedBox(
                width: 90,
                child: TextField(
                    controller: hwC,
                    keyboardType: TextInputType.number,
                    onChanged: (s) => hw = int.tryParse(s) ?? hw)),
            const SizedBox(width: 12),
            FilledButton(
                onPressed: () => setState(() {
                      mode = Mode.hw;
                      needStatic = true;
                      send([0xA0, 0x63, 0x01, hw.clamp(0, 255).toInt()]);
                    }),
                child: const Text('اجرا')),
          ]),
        ]),
        card('ترتیب رنگ', [
          const Text('اگر قرمز و سبز جابه‌جا دیده شد، ترتیب را عوض کن.'),
          DropdownButton<String>(
              value: ord,
              items: [
                for (final o in ['RGB', 'GRB', 'BGR', 'RBG', 'GBR', 'BRG'])
                  DropdownMenuItem(value: o, child: Text(o))
              ],
              onChanged: (v) => setState(() => ord = v!)),
        ]),
      ]),
    );
  }
}
