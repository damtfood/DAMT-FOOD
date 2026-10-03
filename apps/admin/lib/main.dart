import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';

SupabaseClient get supabase => Supabase.instance.client;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: AppConfig.supabaseUrl, anonKey: AppConfig.supabasePublishableKey);
  runApp(const DamtAdminApp());
}

String errText(Object e) {
  if (e is FunctionException) {
    final d = e.details;
    if (d is Map && d['error'] != null) return d['error'].toString();
  }
  return e.toString();
}

class DamtAdminApp extends StatelessWidget {
  const DamtAdminApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'DAMT Food Admin',
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
            supabase.auth.currentSession == null ? const LoginScreen() : const OrdersScreen(),
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
      if (p['role'] != 'admin' || p['is_active'] != true) {
        await supabase.auth.signOut();
        throw 'This account is not an active admin';
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
                Text('Admin', style: Theme.of(context).textTheme.headlineSmall),
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

// Admin-controlled next steps (mirrors update-order-status). PACKED -> assign partner.
const nextSteps = <String, List<String>>{
  'PENDING': ['CONFIRMED', 'CANCELLED'],
  'CONFIRMED': ['PREPARING', 'CANCELLED'],
  'PREPARING': ['PACKED', 'CANCELLED'],
  'PACKED': ['CANCELLED'],
  'ASSIGNED': ['CANCELLED'],
  'OUT_FOR_DELIVERY': ['CANCELLED'],
};

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});
  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  late Future<List<Map<String, dynamic>>> _future = _load();

  Future<List<Map<String, dynamic>>> _load() => supabase
      .from('orders')
      .select('id, order_number, order_status, final_amount, payment_method, created_at')
      .order('created_at', ascending: false)
      .limit(50);

  void _refresh() => setState(() => _future = _load());
  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<String?> _askReason() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancellation reason'),
        content: TextField(controller: c, autofocus: true, maxLength: 300),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('Cancel order')),
        ],
      ),
    );
  }

  Future<void> _change(String id, String status) async {
    try {
      final body = <String, dynamic>{'order_id': id, 'status': status};
      if (status == 'CANCELLED') {
        final reason = await _askReason();
        if (reason == null) return;
        body['reason'] = reason;
      }
      await supabase.functions.invoke('update-order-status', body: body);
      _refresh();
    } catch (e) {
      _snack(errText(e));
    }
  }

  Future<void> _assign(String orderId) async {
    final partners = await supabase.from('profiles').select('id, full_name, email').eq('role', 'delivery_partner').eq('is_active', true);
    if (!mounted) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Assign delivery partner'),
        children: [
          if (partners.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No active delivery partners')),
          for (final p in partners)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, p['id'] as String),
              child: Text(p['full_name'] ?? p['email'] ?? p['id']),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    try {
      await supabase.functions.invoke('update-order-status',
          body: {'order_id': orderId, 'status': 'ASSIGNED', 'partner_id': chosen});
      _refresh();
    } catch (e) {
      _snack(errText(e));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Orders'),
          actions: [
            IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
            IconButton(onPressed: () => supabase.auth.signOut(), icon: const Icon(Icons.logout)),
          ],
        ),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
            final orders = snap.data ?? [];
            if (orders.isEmpty) return const Center(child: Text('No orders yet'));
            return ListView.separated(
              itemCount: orders.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final o = orders[i];
                final id = o['id'] as String;
                final status = o['order_status'] as String;
                return ListTile(
                  title: Text('#${o['order_number']}  •  ₹${o['final_amount']}'),
                  subtitle: Text('$status  •  ${o['payment_method']}'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) => v == 'ASSIGN' ? _assign(id) : _change(id, v),
                    itemBuilder: (_) => [
                      for (final s in nextSteps[status] ?? const <String>[]) PopupMenuItem(value: s, child: Text(s)),
                      if (status == 'PACKED' || status == 'ASSIGNED')
                        PopupMenuItem(value: 'ASSIGN', child: Text(status == 'ASSIGNED' ? 'REASSIGN DELIVERY' : 'ASSIGN DELIVERY')),
                    ],
                  ),
                );
              },
            );
          },
        ),
      );
}
