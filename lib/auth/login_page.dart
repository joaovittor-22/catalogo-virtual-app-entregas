import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/tema.dart';
import '../conta/termos_page.dart';
import 'auth_controller.dart';

/// Login: empresa + identificador + senha.
///
/// O identificador aceita, no mesmo campo, celular, CPF, e-mail, usuario ou o
/// ID gerado pelo sistema — o entregador usa o que lembrar.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.auth, this.api});

  final AuthController auth;

  /// Para abrir os termos de uso, que qualquer um lê antes de entrar.
  final ApiClient? api;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formulario = GlobalKey<FormState>();
  final _empresa = TextEditingController();
  final _identificador = TextEditingController();
  final _senha = TextEditingController();
  bool _enviando = false;
  bool _mostrarSenha = false;
  String? _erro;

  /// Empresa em que já marcou o aceite neste aparelho; nela o checkbox não aparece.
  String? _empresaComAceite;

  /// A API pediu o aceite mesmo com o checkbox escondido (termos novos, outra pessoa).
  bool _apiPediuAceite = false;
  bool _aceitouTermos = false;

  /// Primeiro acesso, outra empresa ou termos novos: mostra "Li e aceito os termos".
  bool get _pedirAceite =>
      _apiPediuAceite || _empresaComAceite == null || _empresa.text.trim() != _empresaComAceite;

  @override
  void initState() {
    super.initState();
    // Trocou a empresa: o checkbox volta (e some de novo se voltar para a que já aceitou).
    _empresa.addListener(() => setState(() {}));
    widget.auth.ultimoAcesso().then((acesso) {
      if (!mounted || acesso == null) return;
      _empresa.text = acesso.empresa;
      _identificador.text = acesso.identificador;
    });
    widget.auth.empresaComAceite().then((empresa) {
      if (mounted) setState(() => _empresaComAceite = empresa);
    });
  }

  @override
  void dispose() {
    _empresa.dispose();
    _identificador.dispose();
    _senha.dispose();
    super.dispose();
  }

  Future<void> _entrar() async {
    if (_enviando || !(_formulario.currentState?.validate() ?? false)) return;
    final pedirAceite = _pedirAceite;
    if (pedirAceite && !_aceitouTermos) {
      setState(() => _erro = 'Marque que leu e aceita os termos de uso para entrar.');
      return;
    }
    setState(() {
      _enviando = true;
      _erro = null;
    });
    try {
      await widget.auth.entrar(
        _empresa.text,
        _identificador.text,
        _senha.text,
        aceitouTermos: pedirAceite && _aceitouTermos,
      );
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _erro = e.mensagem;
          if (e.termosPendentes) {
            _apiPediuAceite = true;
            _aceitouTermos = false;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  static String? _obrigatorio(String? valor) =>
      (valor == null || valor.trim().isEmpty) ? 'Preencha este campo' : null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formulario,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.delivery_dining, size: 64, color: Cores.primaria),
                      const SizedBox(height: 12),
                      Text(
                        'Entregas',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: Cores.texto,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Entre com os dados que a loja passou para você.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Cores.apagado),
                      ),
                      if (widget.auth.aviso case final aviso?) ...[
                        const SizedBox(height: 16),
                        Container(
                          key: const Key('aviso-login'),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Cores.sucesso.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            aviso,
                            style: const TextStyle(
                              color: Cores.sucesso,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 28),
                      TextFormField(
                        key: const Key('empresa'),
                        controller: _empresa,
                        // Teclado de texto: alem do codigo numerico, aceita o
                        // apelido (slug) da loja.
                        keyboardType: TextInputType.visiblePassword,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Empresa',
                          hintText: 'Código da empresa',
                          prefixIcon: Icon(Icons.storefront_outlined),
                        ),
                        validator: _obrigatorio,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        key: const Key('identificador'),
                        controller: _identificador,
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.username],
                        decoration: const InputDecoration(
                          labelText: 'Seu acesso',
                          hintText: 'Celular, CPF, e-mail, usuário ou ID',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: _obrigatorio,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        key: const Key('senha'),
                        controller: _senha,
                        obscureText: !_mostrarSenha,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.password],
                        onFieldSubmitted: (_) => _entrar(),
                        decoration: InputDecoration(
                          labelText: 'Senha',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _mostrarSenha ? 'Esconder senha' : 'Mostrar senha',
                            icon: Icon(_mostrarSenha ? Icons.visibility_off : Icons.visibility),
                            onPressed: () => setState(() => _mostrarSenha = !_mostrarSenha),
                          ),
                        ),
                        validator: _obrigatorio,
                      ),
                      if (_pedirAceite) ...[
                        const SizedBox(height: 10),
                        _AceiteDosTermos(
                          marcado: _aceitouTermos,
                          aoMarcar: (valor) => setState(() {
                            _aceitouTermos = valor;
                            if (valor) _erro = null;
                          }),
                          aoAbrirTermos: widget.api == null
                              ? null
                              : () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => TermosPage(api: widget.api!),
                                  ),
                                ),
                        ),
                      ],
                      if (_erro != null) ...[
                        const SizedBox(height: 14),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _erro!,
                            style: const TextStyle(
                              color: Cores.perigo,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 22),
                      FilledButton(
                        onPressed: _enviando ? null : _entrar,
                        child: _enviando
                            ? const SizedBox.square(
                                dimension: 22,
                                child: CircularProgressIndicator(strokeWidth: 2.5),
                              )
                            : const Text('Entrar'),
                      ),
                      // Depois do aceite o checkbox some; os termos continuam a um toque.
                      if (!_pedirAceite && widget.api != null)
                        TextButton(
                          key: const Key('ler-termos'),
                          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(builder: (_) => TermosPage(api: widget.api!)),
                          ),
                          child: const Text('Termos de uso'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Li e aceito os termos de uso", com o link que abre o texto e volta para cá.
class _AceiteDosTermos extends StatelessWidget {
  const _AceiteDosTermos({required this.marcado, required this.aoMarcar, this.aoAbrirTermos});

  final bool marcado;
  final ValueChanged<bool> aoMarcar;
  final VoidCallback? aoAbrirTermos;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const Key('aceite-termos'),
      children: [
        Checkbox(
          key: const Key('marcar-aceite'),
          value: marcado,
          onChanged: (valor) => aoMarcar(valor ?? false),
        ),
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              GestureDetector(
                onTap: () => aoMarcar(!marcado),
                child: const Text('Li e aceito os ', style: TextStyle(fontSize: 16)),
              ),
              if (aoAbrirTermos != null)
                InkWell(
                  key: const Key('ler-termos'),
                  onTap: aoAbrirTermos,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'termos de uso',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Cores.primaria,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                )
              else
                const Text('termos de uso', style: TextStyle(fontSize: 16)),
            ],
          ),
        ),
      ],
    );
  }
}
