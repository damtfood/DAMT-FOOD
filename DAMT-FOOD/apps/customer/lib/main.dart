import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';

SupabaseClient get supabase => Supabase.instance.client;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabasePublishableKey,
  );
  runApp(const DamtCustomerApp());
}

String errText(Object e) {
  if (e is FunctionException) {
    final d = e.details;
    if (d is Map && d['error'] != null) return d['error'].toString();
  }
  return e.toString();
}

class DamtCustomerApp extends StatelessWidget {
  const DamtCustomerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'DAMT Food',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFFB8860B), useMaterial3: true),
        home: const SplashScreen(),
      );
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const AuthGate()));
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(child: Image.asset('assets/logo.png', width: 220)),
      );
}

// Session is restored automatically by supabase_flutter, so app restarts stay signed in.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<AuthState>(
        stream: supabase.auth.onAuthStateChange,
        builder: (context, _) => supabase.auth.currentSession == null
            ? const LoginScreen()
            : const VerificationGate(),
      );
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _busy = false;

  Future<void> _google() async {
    setState(() => _busy = true);
    try {
      final googleUser = await GoogleSignIn(serverClientId: AppConfig.googleWebClientId).signIn();
      if (googleUser == null) return; // user cancelled
      final auth = await googleUser.authentication;
      final idToken = auth.idToken;
      if (idToken == null) throw 'Google did not return an ID token';
      await supabase.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: auth.accessToken,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sign in failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Image.asset('assets/logo.png', width: 180),
                const SizedBox(height: 16),
                Text('DAMT Food', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: _busy ? null : _google,
                  icon: const Icon(Icons.login),
                  label: Text(_busy ? 'Please wait…' : 'Continue with Google'),
                ),
              ]),
            ),
          ),
        ),
      );
}

class VerificationGate extends StatefulWidget {
  const VerificationGate({super.key});
  @override
  State<VerificationGate> createState() => _VerificationGateState();
}

class _VerificationGateState extends State<VerificationGate> {
  late Future<bool> _future = _check();

  Future<bool> _check() async {
    final p = await supabase
        .from('profiles')
        .select('is_verified')
        .eq('id', supabase.auth.currentUser!.id)
        .single();
    return p['is_verified'] == true;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          if (snap.hasError) {
            return Scaffold(
              body: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('Something went wrong: ${snap.error}'),
                  TextButton(onPressed: () => setState(() => _future = _check()), child: const Text('Retry')),
                  TextButton(onPressed: () => supabase.auth.signOut(), child: const Text('Sign out')),
                ]),
              ),
            );
          }
          return snap.data == true
              ? const HomeScreen()
              : VerifyMobileScreen(onVerified: () => setState(() => _future = _check()));
        },
      );
}

class VerifyMobileScreen extends StatefulWidget {
  final VoidCallback onVerified;
  const VerifyMobileScreen({super.key, required this.onVerified});
  @override
  State<VerifyMobileScreen> createState() => _VerifyMobileScreenState();
}

class _VerifyMobileScreenState extends State<VerifyMobileScreen> {
  final _mobile = TextEditingController();
  final _otp = TextEditingController();
  bool _sent = false, _busy = false;

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _send() async {
    if (_busy) return; // guards double taps; the server also enforces a 60s cooldown
    setState(() => _busy = true);
    try {
      await supabase.functions.invoke('send-otp', body: {'mobile': _mobile.text.trim()});
      setState(() => _sent = true);
      _snack('OTP sent to your WhatsApp');
    } catch (e) {
      _snack(errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await supabase.functions.invoke('verify-otp', body: {'otp': _otp.text.trim()});
      widget.onVerified();
    } catch (e) {
      _snack(errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Verify mobile'),
          actions: [IconButton(onPressed: () => supabase.auth.signOut(), icon: const Icon(Icons.logout))],
        ),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            Image.asset('assets/logo.png', width: 120),
            const SizedBox(height: 16),
            TextField(
              controller: _mobile,
              keyboardType: TextInputType.phone,
              maxLength: 10,
              decoration: const InputDecoration(labelText: 'WhatsApp number', prefixText: '+91 ', border: OutlineInputBorder()),
            ),
            FilledButton(onPressed: _busy ? null : _send, child: Text(_sent ? 'Resend OTP' : 'Send OTP')),
            if (_sent) ...[
              const SizedBox(height: 24),
              TextField(
                controller: _otp,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(labelText: '6-digit OTP', border: OutlineInputBorder()),
              ),
              FilledButton(onPressed: _busy ? null : _verify, child: const Text('Verify')),
            ],
          ]),
        ),
      );
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('DAMT Food'),
          actions: [IconButton(onPressed: () => supabase.auth.signOut(), icon: const Icon(Icons.logout))],
        ),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: supabase.from('products').select('id, name, base_price').eq('is_active', true).order('name'),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
            final items = snap.data ?? [];
            if (items.isEmpty) return const Center(child: Text('No products yet'));
            return ListView(
              children: [
                for (final p in items)
                  ListTile(title: Text(p['name']), trailing: Text('₹${p['base_price']}')),
              ],
            );
          },
        ),
      );
}
