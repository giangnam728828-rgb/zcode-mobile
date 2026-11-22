import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Scans the QR code the desktop shows in its Mobile Remote Control dialog and
/// returns the raw payload. Validation of the payload happens at the call
/// site, so a wrong code can produce a specific, useful error there.
Future<String?> scanDesktopQr(BuildContext context) async {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(builder: (_) => const _QrScanPage()),
  );
}

class _QrScanPage extends StatefulWidget {
  const _QrScanPage({Key? key}) : super(key: key);

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final Barcode b in capture.barcodes) {
      final String? value = b.rawValue;
      if (value == null || value.trim().isEmpty) continue;
      _done = true;
      Navigator.of(context).pop(value.trim());
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('扫描桌面二维码'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.flashlight_on_outlined),
            tooltip: '手电筒',
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              color: Colors.black54,
              padding: EdgeInsets.fromLTRB(
                  18, 14, 18, MediaQuery.paddingOf(context).bottom + 16),
              child: const Text(
                '对准桌面端「移动远程控制」弹窗里的二维码\n'
                '链接等同于桌面窗口的操作凭证，不要截图外传',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, height: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
