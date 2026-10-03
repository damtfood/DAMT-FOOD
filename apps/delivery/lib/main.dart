import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';

SupabaseClient get supabase => Supabase.instance.client;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: AppConfig.supabaseUrl, anonKey: AppConfig.supabasePublishableKey);
  runApp(const DamtDeliveryApp());
}

class DamtDeliveryApp extends StatelessWidget {
  const DamtDeliveryApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'DAMT Food Delivery',
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
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Image.asset('assets/logo.png', width: 220)));
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<AuthState>(
        stream: supabase.auth.onAuthStateChange,
        builder: (context, _) =>
            supabase.auth.currentSession == null ? const LoginScreen() : const AssignedOrdersScreen(),
      );
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;

  Future<void> _login() async {
    setState(() => _busy = true);
    try {
      await supabase.auth.signInWithPassword(
        email: '${_user.text.trim().toLowerCase()}@${AppConfig.staffEmailDomain}',
        password: _pass.text,
      );
      final p = await supabase.from('profiles').select('role, is_active').eq('id', supabase.auth.currentUser!.id).single();
      if (p['role'] != 'delivery_partner' || p['is_active'] != true) {
        await supabase.auth.signOut();
        throw 'Not an active delivery partner';
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Login failed. Check username and password.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(children: [
                Image.asset('assets/logo.png', width: 160),
                const SizedBox(height: 8),
                Text('Delivery Partner', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 24),
                TextField(controller: _user, decoration: const InputDecoration(labelText: 'Username', border: OutlineInputBorder())),
                const SizedBox(height: 12),
                TextField(controller: _pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder())),
                const SizedBox(height: 16),
                FilledButton(onPressed: _busy ? null : _login, child: Text(_busy ? 'Please wait…' : 'Login')),
              ]),
            ),
          ),
        ),
      );
}

class AssignedOrdersScreen extends StatefulWidget {
  const AssignedOrdersScreen({super.key});
  @override
  State<AssignedOrdersScreen> createState() => _AssignedOrdersScreenState();
}

class _AssignedOrdersScreenState extends State<AssignedOrdersScreen> {
  late Future<List<dynamic>> _future = supabase.rpc('delivery_orders');

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('My deliveries'),
          actions: [
            IconButton(onPressed: () => setState(() => _future = supabase.rpc('delivery_orders')), icon: const Icon(Icons.refresh)),
            IconButton(onPressed: () => supabase.auth.signOut(), icon: const Icon(Icons.logout)),
          ],
        ),
        body: FutureBuilder<List<dynamic>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
            final rows = snap.data ?? [];
            if (rows.isEmpty) return const Center(child: Text('No assigned orders'));
            return ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final o = rows[i] as Map<String, dynamic>;
                final cod = (o['cod_amount'] as num?) ?? 0;
                final addr = (o['address'] as Map?) ?? const {};
                return ListTile(
                  title: Text('#${o['order_number']}  •  ${o['customer_name'] ?? 'Customer'}'),
                  subtitle: Text('${addr['address_line_1'] ?? ''}, ${addr['city'] ?? ''}\n${o['customer_mobile'] ?? ''}'
                      '${cod > 0 ? '\nCollect COD: ₹$cod' : ''}'),
                  isThreeLine: true,
                  trailing: Text(o['order_status']),
                );
              },
            );
          },
        ),
      );
}
