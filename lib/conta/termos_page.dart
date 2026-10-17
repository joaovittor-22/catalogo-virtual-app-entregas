import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/tema.dart';
import 'texto_legal.dart';

/// Termos de uso do entregador, só para ler: aberta pelo link da tela de entrada (e da conta),
/// volta com o botão de voltar. O texto é o que o super admin publica no painel.
class TermosPage extends StatefulWidget {
  const TermosPage({super.key, required this.api});

  final ApiClient api;

  @override
  State<TermosPage> createState() => _TermosPageState();
}

class _TermosPageState extends State<TermosPage> {
  Map<String, dynamic>? _documento;
  String? _erro;
  bool _carregando = true;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    setState(() {
      _carregando = true;
      _erro = null;
    });
    try {
      final dados = await widget.api.get('/api/legal/entregador');
      if (!mounted) return;
      setState(() => _documento = dados as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (mounted) setState(() => _erro = e.mensagem);
    } finally {
      if (mounted) setState(() => _carregando = false);
    }
  }

  static String _data(String? iso) {
    final data = DateTime.tryParse(iso ?? '')?.toLocal();
    if (data == null) return '';
    String dois(int n) => n.toString().padLeft(2, '0');
    return '${dois(data.day)}/${dois(data.month)}/${data.year}';
  }

  @override
  Widget build(BuildContext context) {
    final doc = _documento;
    return Scaffold(
      appBar: AppBar(title: const Text('Termos de uso')),
      body: _carregando
          ? const Center(child: CircularProgressIndicator())
          : doc == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _erro ?? 'Não foi possível carregar os termos.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size(200, 52)),
                      onPressed: _carregar,
                      child: const Text('Tentar de novo'),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
              children: [
                Text(
                  doc['titulo'] as String? ?? 'Termos de uso',
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  'Versão ${doc['versao']} · publicada em ${_data(doc['publicadoEm'] as String?)}',
                  key: const Key('versao-termos'),
                  style: const TextStyle(color: Cores.apagado),
                ),
                const SizedBox(height: 8),
                TextoLegal(texto: doc['conteudo'] as String? ?? ''),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('voltar-dos-termos'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Voltar'),
                ),
              ],
            ),
    );
  }
}
