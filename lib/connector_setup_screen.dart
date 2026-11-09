import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';


const _kYellow = Color(0xFFFFC107);
const _kYellowLight = Color(0xFFFFF4E5);
const _kYellowDark = Color(0xFFB38600);
const _kGreen = Color(0xFF4CAF50);
const _kGray = Color(0xFFAAAAAA);

const String _kBase = 'https://ridgeboticsapp.onrender.com';




const String kConnectorDownloadUrl = '';

class _Slide {
  final IconData icon;
  final String title;
  final String body;
  final List<String> steps;

  const _Slide({
    required this.icon,
    required this.title,
    this.body = '',
    this.steps = const [],
  });
}






class ConnectorSetupScreen extends StatefulWidget {
  final bool instructionsOnly;

  const ConnectorSetupScreen({super.key, this.instructionsOnly = false});

  @override
  State<ConnectorSetupScreen> createState() => _ConnectorSetupScreenState();
}

class _ConnectorSetupScreenState extends State<ConnectorSetupScreen> {
  final PageController _controller = PageController();
  int _page = 0;

  String? _team;
  String? _passcode;
  bool _connected = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _loadSession();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final team = prefs.getString('battery_team');
      final pass = prefs.getString('battery_passcode');
      if (!mounted) return;
      setState(() {
        _team = team;
        _passcode = pass;
      });
      if (team != null && pass != null) {
        _check();
        _poll = Timer.periodic(const Duration(seconds: 3), (_) => _check());
      }
    } catch (_) {}
  }



  Future<void> _check() async {
    final team = _team;
    final pass = _passcode;
    if (team == null || pass == null) return;
    try {
      final res = await http
          .get(
            Uri.parse(
                '$_kBase/battery/list?teamNumber=${Uri.encodeQueryComponent(team)}'),
            headers: {'X-Team-Passcode': pass},
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200 || !mounted) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final ok = data['connectorConnected'] == true;
      if (ok != _connected) setState(() => _connected = ok);
    } catch (_) {

    }
  }

  List<_Slide> _slides() {
    final team = _team == null ? 'your team number' : 'team $_team';
    return [
      _Slide(
        icon: Icons.computer,
        title: 'Install the desktop app',
        body: 'Marble Connector Desktop reads your robot\'s match logs and keeps '
            'track of your batteries, so there is nothing to tap by hand.',
        steps: [
          kConnectorDownloadUrl.isEmpty
              ? 'Get the Marble Collector installer from your team\'s programming lead and run it on a Windows laptop that comes to every event.'
              : 'On a Windows laptop that comes to every event, download and run the installer: $kConnectorDownloadUrl',
          'Leave \"Start with Windows\" on in its Settings. It then waits quietly in the system tray.',
        ],
      ),
      _Slide(
        icon: Icons.login,
        title: 'Sign in with your team',
        steps: [
          'Open Marble Collector and enter $team and the same passcode you use for the Battery tracker here.',
          'Click Connect. When it works, the dot at the bottom of this screen turns green.',
          'If it says the team is not set to Marble Connector Desktop, the switch in this app did not go through. Close this screen and switch again.',
        ],
      ),
      const _Slide(
        icon: Icons.usb,
        title: 'Plug in the log USB after a match',
        steps: [
          'Take the USB stick out of the roboRIO and plug it into the laptop. The app finds new logs by itself.',
          'It asks which battery was in the robot. Tap that battery. Not sure? Tap \"Not sure\" and assign it later.',
          'Logs saved somewhere else? In the app\'s Settings, use \"Add folder\".',
        ],
      ),
      const _Slide(
        icon: Icons.check_circle_outline,
        title: 'Back here in Marble',
        steps: [
          'A battery turns green when its sensor node is sending readings, and dark grey when it is not. This works even with the laptop off.',
          'Tap any battery for its voltage graph and how Marble reads it. That is also where you rename it.',
          'To track by hand again, open the ... menu at the top right and choose \"Switch to manual tracking\".',
        ],
      ),
    ];
  }

  void _go(int page) {
    _controller.animateToPage(
      page,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _finish() => Navigator.pop(context, true);

  @override
  Widget build(BuildContext context) {
    final slides = _slides();
    final last = _page == slides.length - 1;

    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 255, 255, 248),
      body: SafeArea(
        child: Column(children: [
          _topBar(slides.length),
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: slides.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (_, i) => _slidePage(slides[i]),
            ),
          ),
          _statusRow(),
          _dots(slides.length),
          _buttons(last),
        ]),
      ),
    );
  }

  Widget _topBar(int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 16, 0),
      child: Row(children: [
        IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close, color: _kYellowDark),
          onPressed: () => Navigator.pop(context, false),
        ),
        Expanded(
          child: Text(
            widget.instructionsOnly ? 'Instructions' : 'Set up automatic mode',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
        ),
        Text('${_page + 1} of $count',
            style: TextStyle(fontSize: 12, color: Colors.grey[600])),
      ]),
    );
  }

  Widget _slidePage(_Slide slide) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: _kYellowLight,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(slide.icon, color: _kYellowDark, size: 28),
        ),
        const SizedBox(height: 16),
        Text(slide.title,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
        if (slide.body.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(slide.body,
              style: TextStyle(
                  fontSize: 15, height: 1.4, color: Colors.grey[800])),
        ],
        if (slide.steps.isNotEmpty) const SizedBox(height: 14),
        for (var i = 0; i < slide.steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                    color: _kYellow, shape: BoxShape.circle),
                child: Text('${i + 1}',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(slide.steps[i],
                    style: const TextStyle(fontSize: 15, height: 1.4)),
              ),
            ]),
          ),
      ]),
    );
  }

  Widget _statusRow() {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.circle, size: 9, color: _connected ? _kGreen : _kGray),
        const SizedBox(width: 6),
        Text(_connected ? 'Desktop app connected' : 'Waiting for desktop app',
            style: TextStyle(fontSize: 11, color: Colors.grey[600])),
      ]),
    );
  }

  Widget _dots(int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < count; i++)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == _page ? 18 : 7,
            height: 7,
            decoration: BoxDecoration(
              color: i == _page ? _kYellow : Colors.black.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ]),
    );
  }

  Widget _buttons(bool last) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Row(children: [
        if (_page > 0)
          TextButton(
            onPressed: () => _go(_page - 1),
            child: const Text('Back'),
          ),
        const Spacer(),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _kYellow),
          onPressed: last ? _finish : () => _go(_page + 1),
          child: Text(last
              ? (widget.instructionsOnly ? 'Close' : 'Done')
              : 'Next'),
        ),
      ]),
    );
  }
}

Future<String?> promptCollectorPassword(BuildContext context) async {
  String? team;
  String? pass;
  try {
    final prefs = await SharedPreferences.getInstance();
    team = prefs.getString('battery_team');
    pass = prefs.getString('battery_passcode');
  } catch (_) {}
  if (!context.mounted) return null;

  final ctrl = TextEditingController();
  String? error;
  bool checking = false;

  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) {
        Future<void> submit() async {
          final entered = ctrl.text.trim();
          if (entered.isEmpty || checking) return;
          if (team == null || pass == null) {
            setD(() => error = 'Log in to your team first');
            return;
          }
          setD(() {
            checking = true;
            error = null;
          });
          try {
            final res = await http
                .post(Uri.parse('$_kBase/battery/collector/unlock'),
                    headers: {'Content-Type': 'application/json'},
                    body: jsonEncode({
                      'teamNumber': team,
                      'passcode': pass,
                      'collectorPassword': entered,
                    }))
                .timeout(const Duration(seconds: 15));
            if (res.statusCode == 200) {
              if (ctx.mounted) Navigator.pop(ctx, entered);
              return;
            }
            String message = 'Could not check the passcode';
            try {
              message = (jsonDecode(res.body) as Map<String, dynamic>)['error']
                      as String? ??
                  message;
            } catch (_) {}
            setD(() {
              checking = false;
              error = res.statusCode == 403 ? 'Wrong passcode' : message;
            });
          } catch (_) {
            setD(() {
              checking = false;
              error = 'Could not connect, try again';
            });
          }
        }

        return AlertDialog(
          title: const Text('Marble Collector'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'The Marble Collector is going to do it all. The Collector is still in alpha. Enter the passcode to continue.'),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                obscureText: true,
                autofocus: true,
                onSubmitted: (_) => submit(),
                decoration: InputDecoration(
                  labelText: 'Passcode',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _kYellow),
              onPressed: checking ? null : submit,
              child: Text(checking ? 'Checking…' : 'Continue'),
            ),
          ],
        );
      },
    ),
  );
  return result;
}
