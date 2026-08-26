import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// CJx Travel Log — เปลือกแอป Android
///
/// ทำไมเป็นเปลือกครอบเว็บ ไม่เขียน UI ใหม่
///   หน้าตาและตรรกะทั้งหมดอยู่ในเว็บแอปชุดเดียว แก้ที่เดียวได้ทั้ง Android
///   และ iPhone พร้อมกัน ไม่ต้องไล่ตามกันสองชุดเหมือนที่เคยเป็นมา
///
/// แล้วทำไมยังต้องมีแอป
///   เบราว์เซอร์หยุดเก็บ GPS ทันทีที่สลับแอปหรือล็อกหน้าจอ ปิดพฤติกรรมนี้ไม่ได้
///   แอปนี้จึงมีหน้าที่เดียวที่เว็บทำเองไม่ได้ — เปิด foreground service
///   เก็บพิกัดต่อเนื่องแม้ล็อกจอ แล้วส่งให้เว็บตอนกลับมาหน้าจอ
///
/// แบ่งหน้าที่ให้ชัด
///   เว็บ   : หน้าจอทั้งหมด · เข้าระบบ · คิวออฟไลน์ · ส่งขึ้น Supabase
///   เปลือก : เก็บพิกัดตอนอยู่เบื้องหลัง แล้วพักไว้ในหน่วยความจำ
///   เปลือกไม่แตะ token ไม่คุยกับ Supabase เอง — ลดพื้นที่ที่จะพลาดเรื่องสิทธิ์
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ShellApp());
}

/// ที่อยู่เว็บแอป — เปลี่ยนตอน build ได้ด้วย
///   flutter build apk --dart-define=WEB_URL=https://...
const kWebUrl = String.fromEnvironment(
  'WEB_URL',
  defaultValue: 'https://lolipopkung.github.io/CJX-travel-log-web/',
);

class ShellApp extends StatelessWidget {
  const ShellApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CJx Travel Log',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFFFD400),
        scaffoldBackgroundColor: const Color(0xFFF6F7F9),
      ),
      home: const ShellPage(),
    );
  }
}

// =====================================================================
//  ตัวเก็บพิกัดเบื้องหลัง
// =====================================================================

/// พิกัดที่เก็บได้ระหว่างที่เว็บมองไม่เห็น พักไว้ตรงนี้จนกว่าเว็บจะมาดึง
class _Tracker {
  _Tracker._();
  static final _Tracker instance = _Tracker._();

  StreamSubscription<Position>? _sub;
  final List<Map<String, dynamic>> _buffer = [];
  String? sessionId;

  bool get running => _sub != null;
  int get pending => _buffer.length;

  Future<String?> start(String session) async {
    if (_sub != null && sessionId == session) return null;
    await stop();
    sessionId = session;

    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'ยังไม่ได้เปิด GPS ของเครื่อง';
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
      return 'ยังไม่ได้อนุญาตให้เข้าถึงตำแหน่ง';
    }

    // ต้องขอ "ตลอดเวลา" แยกอีกครั้งบน Android 10 ขึ้นไป
    // ไม่ได้สิทธิ์นี้ = พอล็อกจอก็หยุดเก็บ เหมือนเว็บเปล่า ๆ
    if (await Permission.locationAlways.isDenied) {
      await Permission.locationAlways.request();
    }

    final settings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 15,
      intervalDuration: const Duration(seconds: 5),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'CJx Travel Log — กำลังบันทึกการเดินทาง',
        notificationText:
            'บันทึกเฉพาะช่วงปฏิบัติงาน · กด "สิ้นสุดการทำงาน" ในแอปเมื่อเสร็จ',
        enableWakeLock: true,
        setOngoing: true,
      ),
    );

    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      (pos) {
        _buffer.add({
          'at': pos.timestamp.toUtc().toIso8601String(),
          'lat': pos.latitude,
          'lng': pos.longitude,
          'acc': pos.accuracy,
          'spd': pos.speed,
          'hdg': pos.heading,
          'alt': pos.altitude,
        });
        // กันหน่วยความจำบวมถ้าเว็บไม่ได้มาดึงนาน ๆ (เช่นทริป 10 ชม.)
        // 20,000 จุด ~ 5 วินาที/จุด = ครอบคลุมเกิน 27 ชั่วโมง
        if (_buffer.length > 20000) _buffer.removeRange(0, 5000);
      },
      onError: (Object e) => debugPrint('gps $e'),
    );
    return null;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    sessionId = null;
  }

  /// เว็บมาดึงพิกัดที่พักไว้ — ดึงแล้วล้างทิ้ง กันนับซ้ำ
  List<Map<String, dynamic>> drain() {
    final out = List<Map<String, dynamic>>.from(_buffer);
    _buffer.clear();
    return out;
  }
}

// =====================================================================
//  หน้าจอเดียวของแอป — WebView เต็มจอ
// =====================================================================
class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> with WidgetsBindingObserver {
  late final WebViewController _web;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _build();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // กลับมาหน้าจอแล้วบอกเว็บให้มาดึงพิกัดที่เก็บไว้ระหว่างที่ไม่ได้ดู
    if (state == AppLifecycleState.resumed && _Tracker.instance.running) {
      _web.runJavaScript(
          'window.cjxNativeResumed && window.cjxNativeResumed();');
    }
  }

  void _build() {
    final params = const PlatformWebViewControllerCreationParams();
    final c = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFF6F7F9))
      ..addJavaScriptChannel('CJXNative', onMessageReceived: _onMessage)
      ..setNavigationDelegate(NavigationDelegate(
        // ลิงก์ที่ออกนอกเว็บแอป (เช่น Google Maps จากรายงาน) -> เปิดในแอปภายนอก
        // ไม่ให้ WebView นำทางออกไปเอง (maps redirect เป็น intent:// -> ERR_UNKNOWN_URL_SCHEME
        // แล้วหน้าแอปพังทั้งจอ) · ลิงก์ภายในเว็บแอปเดิมปล่อยผ่านปกติ
        onNavigationRequest: (req) {
          final u = Uri.tryParse(req.url);
          final host = u?.host ?? '';
          final internal = host.isEmpty || host == Uri.parse(kWebUrl).host
              || host.contains('localhost') || req.url.startsWith('about:');
          if (!internal) {
            launchUrl(Uri.parse(req.url), mode: LaunchMode.externalApplication)
                .catchError((Object _) => false);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        // ตั้งธงตั้งแต่หน้าเริ่มโหลด เพื่อลดช่วงที่เว็บยังไม่รู้ว่าอยู่ในเปลือก
        // ถ้าไม่ทัน เว็บมี listener 'cjx-native-ready' คอยสลับให้อีกชั้น
        onPageStarted: (_) {
          _web.runJavaScript('window.CJX_NATIVE = true;');
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
          // บอกเว็บว่ากำลังรันอยู่ในเปลือก จะได้ใช้ GPS ของแอปแทนของเบราว์เซอร์
          _web.runJavaScript(
              'window.CJX_NATIVE = true;'
              'window.dispatchEvent(new Event("cjx-native-ready"));');
        },
        onWebResourceError: (e) {
          if (!mounted || e.isForMainFrame != true) return;
          setState(() {
            _loading = false;
            _error = 'เปิดเว็บแอปไม่ได้ (${e.description})';
          });
        },
      ));

    if (c.platform is AndroidWebViewController) {
      final a = c.platform as AndroidWebViewController;

      // แยกช่อง <input type=file> 2 แบบ:
      //   · รูป (accept="image/*" capture) เช่น เลขไมล์/สลิป -> บังคับกล้องถ่ายสด
      //     (แน่นอนกว่าเช็กเวลาไฟล์ฝั่งเว็บ เพราะไม่มีทางเลือกจากอัลบั้มเลย)
      //   · เอกสาร (accept=".txt,.csv" ฯลฯ) เช่น แนบไฟล์ตอน create user batch
      //     -> เปิดตัวเลือกไฟล์เอกสาร ไม่ใช่กล้อง
      a.setOnShowFileSelector((params) async {
        final types = params.acceptTypes.map((t) => t.toLowerCase()).toList();
        final wantsCamera = params.isCaptureEnabled ||
            types.any((t) => t.startsWith('image'));
        if (wantsCamera) {
          try {
            final shot = await ImagePicker().pickImage(
              source: ImageSource.camera, imageQuality: 78, maxWidth: 1600);
            return shot == null ? <String>[] : <String>[Uri.file(shot.path).toString()];
          } catch (e) {
            debugPrint('camera $e');
            return <String>[];
          }
        }
        // ช่องแนบเอกสาร -> เปิดหน้าเลือกไฟล์ (ไม่ใช่กล้อง)
        try {
          final res = await FilePicker.platform.pickFiles(withData: false);
          final p = (res == null || res.files.isEmpty) ? null : res.files.single.path;
          return p == null ? <String>[] : <String>[Uri.file(p).toString()];
        } catch (e) {
          debugPrint('filepicker $e');
          return <String>[];
        }
      });

      // ไม่ตั้งอันนี้ = เว็บขอตำแหน่งไม่ผ่าน แผนที่และการจับพิกัดใช้ไม่ได้
      AndroidWebViewController.enableDebugging(false);
      a.setGeolocationPermissionsPromptCallbacks(
        onShowPrompt: (request) async =>
            const GeolocationPermissionsResponse(allow: true, retain: true),
      );
      a.setMediaPlaybackRequiresUserGesture(false);
    }

    // ต้องกำหนดก่อนสั่งโหลด ไม่งั้น callback ของ NavigationDelegate
    // อาจอ้าง _web ตอนที่ยังไม่ถูกกำหนดค่า แล้วแอปพังตั้งแต่เปิด
    _web = c;
    c.loadRequest(Uri.parse(kWebUrl));
  }

  /// ข้อความจากเว็บ — รูปแบบ {"cmd": "...", ...}
  /// อ่านสถานะสิทธิ์ตำแหน่ง คืนให้เว็บตัดสินใจว่าบล็อกหรือปล่อย
  ///   always  = อนุญาตตลอดเวลา (พร้อมเก็บเบื้องหลัง) — ผ่าน
  ///   whenInUse = ขณะใช้แอปเท่านั้น — ต้องอัปเป็นตลอดเวลา
  ///   denied / permanentlyDenied / serviceOff = ยังใช้ไม่ได้
  Future<Map<String, dynamic>> _permStatus() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return {'ok': true, 'level': 'serviceOff'};
    }
    final always = await Permission.locationAlways.status;
    if (always.isGranted) return {'ok': true, 'level': 'always'};

    final fine = await Permission.locationWhenInUse.status;
    if (fine.isGranted) return {'ok': true, 'level': 'whenInUse'};
    if (fine.isPermanentlyDenied || always.isPermanentlyDenied) {
      return {'ok': true, 'level': 'permanentlyDenied'};
    }
    return {'ok': true, 'level': 'denied'};
  }

  /// ขอสิทธิ์แบบเป็นขั้น: ตำแหน่งขณะใช้ก่อน แล้วค่อยขอ "ตลอดเวลา"
  /// (Android 11+ บังคับ 2 ขั้นแบบนี้ ขอรวดเดียวไม่ได้)
  Future<void> _requestAllLocation() async {
    var fine = await Permission.locationWhenInUse.status;
    if (!fine.isGranted) fine = await Permission.locationWhenInUse.request();
    if (fine.isGranted) {
      final always = await Permission.locationAlways.status;
      if (!always.isGranted) await Permission.locationAlways.request();
    }
  }

  Future<void> _onMessage(JavaScriptMessage msg) async {
    Map<String, dynamic> m;
    try {
      m = Map<String, dynamic>.from(jsonDecode(msg.message) as Map);
    } catch (_) {
      return;
    }
    final cmd = '${m['cmd']}';
    final reqId = m['reqId'];

    Future<void> reply(Object payload) async {
      if (reqId == null) return;
      final js = jsonEncode(payload);
      await _web.runJavaScript(
          'window.cjxNativeReply && window.cjxNativeReply(${jsonEncode(reqId)}, $js);');
    }

    switch (cmd) {
      case 'start':
        final err = await _Tracker.instance.start('${m['sessionId']}');
        await reply({'ok': err == null, 'error': err});
        break;

      case 'stop':
        await _Tracker.instance.stop();
        await reply({'ok': true});
        break;

      case 'drain':
        await reply({
          'ok': true,
          'running': _Tracker.instance.running,
          'points': _Tracker.instance.drain(),
        });
        break;

      case 'status':
        await reply({
          'ok': true,
          'running': _Tracker.instance.running,
          'pending': _Tracker.instance.pending,
          'sessionId': _Tracker.instance.sessionId,
        });
        break;

      // เว็บถามว่าสิทธิ์ตำแหน่งอยู่ระดับไหน เพื่อบังคับก่อนเริ่มงาน
      case 'perm_status':
        await reply(await _permStatus());
        break;

      // ขอสิทธิ์อีกครั้ง (ครั้งแรก Android ให้ขอผ่าน dialog ได้)
      case 'perm_request':
        await _requestAllLocation();
        await reply(await _permStatus());
        break;

      // พาไปหน้าตั้งค่าแอป — ใช้เมื่อผู้ใช้เคยปฏิเสธถาวร ต้องเปลี่ยนเองใน Settings
      case 'open_settings':
        await openAppSettings();
        await reply({'ok': true});
        break;

      // เว็บส่งไฟล์รายงาน (Excel/CSV) มาให้เปลือกบันทึก — WebView ดาวน์โหลดเองไม่ได้
      // เขียนไฟล์ลงที่ชั่วคราวแล้วเปิดเมนูแชร์/บันทึก ให้ผู้ใช้เลือกปลายทาง
      case 'save_file':
        await reply(await _saveFile(
            '${m['name']}', '${m['mime']}', '${m['b64']}'));
        break;
    }
  }

  /// รับไฟล์ที่เว็บส่งมาเป็น base64 -> เขียนไฟล์ -> เปิดเมนูแชร์/บันทึก
  /// ตอบกลับทันทีหลังเขียนไฟล์เสร็จ (ไม่รอผู้ใช้เลือกปลายทาง) กันเว็บ timeout
  Future<Map<String, dynamic>> _saveFile(
      String name, String mime, String b64) async {
    try {
      final bytes = base64Decode(b64);
      // ตัดเฉพาะอักขระที่ตั้งชื่อไฟล์ไม่ได้ — คงภาษาไทยไว้ (ชื่อพนักงานในชื่อไฟล์)
      final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/$safe');
      await f.writeAsBytes(bytes, flush: true);
      // ไม่ await — ให้เมนูแชร์เปิดคู่ขนานไป เว็บจะได้รับ ok ทันที
      Share.shareXFiles([XFile(f.path, mimeType: mime)], subject: name);
      return {'ok': true};
    } catch (e) {
      debugPrint('save_file $e');
      return {'ok': false, 'error': '$e'};
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // ปุ่มย้อนกลับของ Android ให้ย้อนหน้าในเว็บก่อน ไม่ใช่ปิดแอปทิ้ง
        if (await _web.canGoBack()) {
          await _web.goBack();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              if (_error == null) WebViewWidget(controller: _web),
              if (_error != null) _ErrorView(
                message: _error!,
                onRetry: () {
                  setState(() {
                    _error = null;
                    _loading = true;
                  });
                  _web.loadRequest(Uri.parse(kWebUrl));
                },
              ),
              if (_loading && _error == null)
                const ColoredBox(
                  color: Color(0xFFF6F7F9),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 14),
                        Text('กำลังเปิดแอป…'),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.wifi_off, size: 48, color: Color(0xFF9A6100)),
            const SizedBox(height: 14),
            const Text('เปิดแอปไม่สำเร็จ',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(height: 1.5)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('ลองใหม่'),
            ),
            const SizedBox(height: 12),
            const Text(
              'ครั้งแรกที่เปิดต้องมีอินเทอร์เน็ต หลังจากนั้นใช้งานออฟไลน์ได้',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
            ),
          ],
        ),
      ),
    );
  }
}
