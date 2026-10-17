import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../core/api_client.dart';
import '../core/tema.dart';
import 'termos_page.dart';

/// Conta do entregador: os termos de uso e a exclusão da conta.
class ContaPage extends StatelessWidget {
  const ContaPage({super.key, required this.auth, required this.api});

  final AuthController auth;
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    final sessao = auth.sessao;
    return Scaffold(
      appBar: AppBar(title: const Text('Conta e termos')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (sessao != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const CircleAvatar(
                      radius: 26,
                      backgroundColor: Cores.primaria,
                      child: Icon(Icons.person, color: Colors.white, size: 30),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            sessao.entregadorNome,
                            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'ID ${sessao.entregadorCodigo} · ${sessao.lojaNome}',
                            style: const TextStyle(color: Cores.apagado),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              key: const Key('abrir-termos'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              leading: const Icon(Icons.description_outlined, color: Cores.primaria),
              title: const Text(
                'Termos de uso',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              subtitle: const Text('Seus dados, quem responde por eles e seus direitos'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => TermosPage(api: api))),
            ),
          ),
          const SizedBox(height: 28),
          const Text('Excluir conta', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'Remove os seus dados da loja em que você está logado'
            '${sessao == null ? '' : ' (${sessao.lojaNome})'}. '
            'Em outras lojas em que você trabalha, o seu cadastro continua. '
            'Leia o que acontece antes de confirmar.',
            style: const TextStyle(fontSize: 15, height: 1.4, color: Cores.apagado),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            key: const Key('excluir-conta'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              foregroundColor: Cores.perigo,
              side: const BorderSide(color: Cores.perigo, width: 1.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Excluir minha conta'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => ExcluirContaDialog(auth: auth),
            ),
          ),
        ],
      ),
    );
  }
}

/// Aviso do que muda e confirmação com a senha. Sem volta, então a senha é pedida de novo.
class ExcluirContaDialog extends StatefulWidget {
  const ExcluirContaDialog({super.key, required this.auth});

  final AuthController auth;

  @override
  State<ExcluirContaDialog> createState() => _ExcluirContaDialogState();
}

class _ExcluirContaDialogState extends State<ExcluirContaDialog> {
  final _senha = TextEditingController();
  bool _enviando = false;
  bool _mostrarSenha = false;
  String? _erro;

  @override
  void dispose() {
    _senha.dispose();
    super.dispose();
  }

  Future<void> _excluir() async {
    if (_enviando) return;
    if (_senha.text.isEmpty) {
      setState(() => _erro = 'Digite a sua senha para confirmar.');
      return;
    }
    setState(() {
      _enviando = true;
      _erro = null;
    });
    try {
      await widget.auth.excluirConta(_senha.text);
      // A sessão acabou e o app volta ao login: fecha o aviso e a tela de conta.
      if (mounted) Navigator.of(context).popUntil((rota) => rota.isFirst);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _erro = e.mensagem;
          _enviando = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const texto = TextStyle(fontSize: 16, height: 1.4, color: Cores.texto);
    final loja = widget.auth.sessao?.lojaNome ?? 'atual';
    Widget item(String frase) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Text('•', style: texto),
          ),
          Expanded(child: Text(frase, style: texto)),
        ],
      ),
    );
    return AlertDialog(
      title: const Text('Excluir a sua conta?'),
      scrollable: true,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          item(
            'Seus dados (nome, CPF, telefone, e-mail e as localizações das suas entregas) serão '
            'removidos da loja $loja, a loja em que você está logado.',
          ),
          item('Você não poderá mais entrar nessa loja.'),
          item(
            'Em outras lojas em que você trabalha, o seu cadastro continua: a decisão vale '
            'só para esta.',
          ),
          item(
            'A loja guarda apenas um registro inativo e anônimo, para o histórico das entregas.',
          ),
          item('Não dá para desfazer.'),
          const SizedBox(height: 6),
          const Text(
            'Para confirmar, digite a sua senha.',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Cores.texto),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('senha-exclusao'),
            controller: _senha,
            obscureText: !_mostrarSenha,
            enabled: !_enviando,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _excluir(),
            decoration: InputDecoration(
              labelText: 'Senha',
              suffixIcon: IconButton(
                tooltip: _mostrarSenha ? 'Esconder senha' : 'Mostrar senha',
                icon: Icon(_mostrarSenha ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _mostrarSenha = !_mostrarSenha),
              ),
            ),
          ),
          if (_erro != null) ...[
            const SizedBox(height: 10),
            Semantics(
              liveRegion: true,
              child: Text(
                _erro!,
                key: const Key('erro-exclusao'),
                style: const TextStyle(color: Cores.perigo, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _enviando ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('confirmar-exclusao'),
          style: FilledButton.styleFrom(
            backgroundColor: Cores.perigo,
            minimumSize: const Size(150, 52),
          ),
          onPressed: _enviando ? null : _excluir,
          child: _enviando
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                )
              : const Text('Excluir conta'),
        ),
      ],
    );
  }
}
