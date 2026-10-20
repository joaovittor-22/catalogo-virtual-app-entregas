import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/armazem.dart';
import 'cofre.dart';
import 'sessao.dart';

/// Estado de login do app.
class AuthController extends ChangeNotifier {
  AuthController(this._api, this._cofre, {Armazem? armazem})
    : armazem = armazem ?? ArmazemEmMemoria() {
    _api.aoPerderSessao = sair;
    _api.aoExigirTermos = _termosMudaram;
  }

  final ApiClient _api;
  final Cofre _cofre;

  /// Fila, corrida e acoes por enviar guardadas no aparelho (ver [DadosLocais]).
  final Armazem armazem;

  Sessao? _sessao;
  bool _carregando = true;

  /// Recado para a tela de login (ex.: conta excluída). Some na próxima entrada.
  String? aviso;

  Sessao? get sessao => _sessao;

  /// Verdadeiro ate a sessao guardada ser lida, na abertura do app.
  bool get carregando => _carregando;

  Future<void> restaurar() async {
    _sessao = await _cofre.lerSessao();
    _api.token = _sessao?.token;
    _carregando = false;
    notifyListeners();
  }

  /// Empresa em que já marcou o aceite neste aparelho: nela a tela de entrada não pede de novo.
  Future<String?> empresaComAceite() => _cofre.lerEmpresaComAceite();

  /// Entra com empresa + identificador + senha. Com [aceitouTermos], manda junto a versão em
  /// vigor dos termos de uso (obrigatória no primeiro acesso a cada empresa e quando os termos
  /// mudam). Lança [ApiException] com a mensagem pronta; [ApiException.termosPendentes] diz que
  /// falta marcar o aceite.
  Future<void> entrar(
    String empresa,
    String identificador,
    String senha, {
    bool aceitouTermos = false,
  }) async {
    aviso = null;
    final codigoEmpresa = empresa.trim();
    int? versao;
    if (aceitouTermos) {
      final termos = await _api.get('/api/legal/entregador');
      versao = (termos as Map)['versao'] as int?;
    }
    final Object? resposta;
    try {
      resposta = await _api.post('/api/entregador/auth/login', {
        'empresa': codigoEmpresa,
        'identificador': identificador.trim(),
        'senha': senha,
        'termosVersao': ?versao,
      });
    } on ApiException catch (e) {
      // O aceite guardado não vale mais (termos novos ou outra pessoa no aparelho).
      if (e.termosPendentes) await _cofre.gravarEmpresaComAceite(null);
      rethrow;
    }
    final sessao = Sessao.daResposta(resposta as Map<String, dynamic>);
    _api.token = sessao.token;
    _sessao = sessao;
    await _cofre.gravarSessao(sessao);
    await _cofre.gravarUltimoAcesso(codigoEmpresa, identificador.trim());
    await _cofre.gravarEmpresaComAceite(codigoEmpresa);
    notifyListeners();
  }

  /// Os termos mudaram com a sessão aberta: volta ao login, que pede o aceite de novo.
  Future<void> _termosMudaram() async {
    if (_sessao == null) return;
    aviso = 'Os termos de uso foram atualizados. Leia e marque o aceite para entrar de novo.';
    await _cofre.gravarEmpresaComAceite(null);
    await sair();
  }

  /// Exclui a conta: os dados saem da loja em que o entregador está logado, e só dela. Pede a
  /// senha de novo. Lança [ApiException] com a mensagem pronta (senha errada, entrega em
  /// andamento). Com sucesso a sessão acaba e o app volta ao login.
  Future<void> excluirConta(String senha) async {
    final resposta = await _api.post('/api/entregador/conta/excluir', {'senha': senha});
    final loja = resposta is Map ? resposta['loja'] as String? : null;
    aviso =
        'Conta excluída. Seus dados foram removidos da loja ${loja ?? 'em que você estava'}. '
        'Em outras lojas, o seu cadastro continua.';
    // Se a loja cadastrar de novo, o aceite é pedido outra vez.
    await _cofre.gravarEmpresaComAceite(null);
    await sairDoAparelho();
  }

  /// Sair de propósito (botão Sair, conta excluída): o aparelho fica sem dado de cliente e sem
  /// ação por enviar. Já a sessão que expira ([sair]) guarda tudo, para seguir depois de entrar
  /// de novo.
  Future<void> sairDoAparelho() async {
    final dono = _sessao?.dono;
    if (dono != null) await DadosLocais.apagarTudo(armazem, dono);
    await sair();
  }

  Future<void> sair() async {
    if (_sessao == null) return;
    _sessao = null;
    _api.token = null;
    await _cofre.apagarSessao();
    notifyListeners();
  }

  Future<({String empresa, String identificador})?> ultimoAcesso() => _cofre.lerUltimoAcesso();
}
