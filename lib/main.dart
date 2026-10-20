import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'chat_screen.dart';
import 'login_screen.dart';

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();

    // بدل الشاشة الرمادية/البيضاء، اعرض الخطأ على الشاشة.
    ErrorWidget.builder = (details) => Material(
          color: Colors.white,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Text(
                'حصل خطأ:\n${details.exceptionAsString()}',
                textDirection: TextDirection.ltr,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ),
          ),
        );

    runApp(const LynoxApp());
  }, (error, stack) {
    debugPrint('Uncaught: $error\n$stack');
  });
}

class _Boot {
  final bool loggedIn;
  final String? error;
  const _Boot(this.loggedIn, [this.error]);
}

class LynoxApp extends StatefulWidget {
  const LynoxApp({super.key});

  @override
  State<LynoxApp> createState() => _LynoxAppState();
}

class _LynoxAppState extends State<LynoxApp> {
  late final Future<_Boot> _boot = _start();

  Future<_Boot> _start() async {
    try {
      final ok = await LynoxApi.instance
          .restore()
          .timeout(const Duration(seconds: 10), onTimeout: () => false);
      return _Boot(ok);
    } catch (e) {
      return _Boot(false, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lynox Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5B5BD6)),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5B5BD6),
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child ?? const SizedBox.shrink(),
      ),
      home: FutureBuilder<_Boot>(
        future: _boot,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final b = snap.data ?? const _Boot(false);
          if (b.error != null) {
            return Scaffold(
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('مشكلة في بدء التطبيق:'),
                      const SizedBox(height: 8),
                      Text(b.error!,
                          textDirection: TextDirection.ltr,
                          style: const TextStyle(color: Colors.red)),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                              builder: (_) => const LoginScreen()),
                        ),
                        child: const Text('متابعة'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          return b.loggedIn ? const ChatScreen() : const LoginScreen();
        },
      ),
    );
  }
}