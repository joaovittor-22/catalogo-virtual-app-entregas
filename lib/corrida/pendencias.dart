import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/armazem.dart';
import '../core/espera.dart';

enum TipoAcao { concluir, devolver, enviarComprovante, removerComprovante }

/// Algo que o entregador fez e a API ainda nao recebeu.
class AcaoPendente {
  AcaoPendente({
    required this.tipo,
    required this.entregaId,
    required this.numero,
    this.corpo = const {},
    this.arquivo,
    this.nomeDoArquivo,
    this.bytes,
    DateTime? criadaEm,
  }) : criadaEm = criadaEm ?? DateTime.now();

  final TipoAcao tipo;
  final int entregaId;

  /// Numero do pedido, para os avisos.
  final String numero;
  final Map<String, dynamic> corpo;

  /// Foto do comprovante: o caminho no aparelho fica guardado; os [bytes], so
  /// na memoria, para a primeira tentativa nao ler o arquivo de novo.
  final String? arquivo;
  final String? nomeDoArquivo;
  final Uint8List? bytes;
  final DateTime criadaEm;

  /// Concluir ou devolver: a entrega acabou no aparelho.
  bool get encerra => tipo == TipoAcao.concluir || tipo == TipoAcao.devolver;

  Map<String, dynamic> toJson() => {
    'tipo': tipo.name,
    'entregaId': entregaId,
    'numero': numero,
    'corpo': corpo,
    'arquivo': ?arquivo,
    'nomeDoArquivo': ?nomeDoArquivo,
    'criadaEm': criadaEm.toIso8601String(),
  };

  factory AcaoPendente.fromJson(Map<String, dynamic> json) => AcaoPendente(
    tipo: TipoAcao.values.byName(json['tipo'] as String),
    entregaId: (json['entregaId'] as num).toInt(),
    numero: json['numero'] as String? ?? '',
    corpo: (json['corpo'] as Map?)?.cast<String, dynamic>() ?? const {},
    arquivo: json['arquivo'] as String?,
    nomeDoArquivo: json['nomeDoArquivo'] as String?,
    criadaEm: DateTime.tryParse(json['criadaEm'] as String? ?? ''),
  );
}

/// RF-E12: acoes feitas sem rede ficam guardadas no aparelho e seguem para a
/// API, na ordem em que foram feitas, quando a conexao volta.
///
/// Sobrevive ao app fechado: a lista e gravada a cada mudanca. A nova tentativa
/// vem com a rede de volta (outra chamada do app teve resposta), ao voltar ao
/// app ou depois de uma espera que cresce ate [esperaMaxima].
class Pendencias extends ChangeNotifier {
  Pendencias({required this.api, required this.dados}) {
    api.conectado.addListener(_aoMudarConexao);
  }

  static const esperaMaxima = Duration(seconds: 30);

  final ApiClient api;
  final DadosLocais dados;

  final List<AcaoPendente> _acoes = [];
  final List<String> _avisos = [];
  final _espera = Espera(base: const Duration(seconds: 3), maximo: esperaMaxima);
  Timer? _novaTentativa;
  bool _enviando = false;
  bool _descartada = false;

  List<AcaoPendente> get acoes => List.unmodifiable(_acoes);
  bool get vazia => _acoes.isEmpty;

  /// A entrega foi concluida ou devolvida no aparelho e isso ainda nao chegou a
  /// API: para ela, a entrega continua em andamento, mas o app nao a reabre.
  bool encerradaAqui(int entregaId) => _acoes.any((a) => a.encerra && a.entregaId == entregaId);

  /// Recusas definitivas da API ao reenviar (a loja encerrou antes, por
  /// exemplo). Quem mostra tira da lista.
  List<String> tirarAvisos() {
    final avisos = List.of(_avisos);
    _avisos.clear();
    return avisos;
  }

  /// Le o que ficou guardado e ja tenta enviar.
  Future<void> carregar() async {
    final guardado = await dados.ler('pendencias');
    if (_descartada) return;
    for (final item in guardado?.dados as List? ?? const []) {
      try {
        _acoes.add(AcaoPendente.fromJson((item as Map).cast<String, dynamic>()));
      } catch (_) {
        // Formato antigo ou corrompido: nao ha como reenviar.
      }
    }
    if (_acoes.isNotEmpty) {
      _avisar();
      unawaited(enviar());
    }
  }

  /// Envia [acao] agora ou, sem rede, guarda para depois. Devolve a resposta da
  /// API, ou `guardada` quando ficou para depois. A recusa definitiva da API
  /// sai como [ApiException], e nada fica guardado.
  ///
  /// Com outras acoes na frente, entra no fim da lista: a ordem importa (a
  /// foto do comprovante depois da conclusao, por exemplo).
  Future<({bool guardada, Object? resposta})> executar(AcaoPendente acao) async {
    // Sem rede na ultima chamada: guarda direto, sem o entregador esperar o
    // tempo limite de uma requisicao que quase certamente vai falhar.
    if (_acoes.isEmpty && !_enviando && api.conectado.value) {
      try {
        return (guardada: false, resposta: await _executar(acao));
      } on ApiException catch (e) {
        if (!_guardavel(e)) rethrow;
      }
    }
    _acoes.add(acao);
    await _gravar();
    _avisar();
    _agendar(null);
    return (guardada: true, resposta: null);
  }

  /// Tira da lista o que ainda nao saiu (ex.: a foto que o entregador trocou).
  Future<bool> cancelar(bool Function(AcaoPendente acao) teste) async {
    final antes = _acoes.length;
    _acoes.removeWhere(teste);
    if (_acoes.length == antes) return false;
    await _gravar();
    _avisar();
    return true;
  }

  /// Envia o que esta guardado, na ordem. Para na primeira falha de rede e
  /// tenta de novo mais tarde. Devolve se a lista ficou vazia.
  Future<bool> enviar() async {
    if (_enviando || _descartada) return _acoes.isEmpty;
    _enviando = true;
    _novaTentativa?.cancel();
    try {
      while (_acoes.isNotEmpty && !_descartada) {
        final acao = _acoes.first;
        try {
          await _executar(acao);
        } on ApiException catch (e) {
          if (_guardavel(e)) {
            // Sessao perdida: a lista fica guardada e sai depois do novo login.
            if (e.status != 401 && !e.termosPendentes) {
              _agendar(e.status == 429 ? esperaMaxima : _espera.depoisDeFalhar());
            }
            return false;
          }
          _avisos.add(_recusa(acao, e.mensagem));
        } on FileSystemException {
          _avisos.add(
            'A foto do comprovante da entrega #${acao.numero} não foi encontrada no aparelho. '
            'Avise a loja.',
          );
        }
        _acoes.removeAt(0);
        _espera.zerar();
        await _gravar();
        _avisar();
      }
      return _acoes.isEmpty;
    } finally {
      _enviando = false;
    }
  }

  static bool _guardavel(ApiException e) => e.passageiro || e.status == 401 || e.termosPendentes;

  Future<Object?> _executar(AcaoPendente acao) async {
    final base = '/api/entregador/entregas/${acao.entregaId}';
    switch (acao.tipo) {
      case TipoAcao.concluir:
        return api.post('$base/concluir', acao.corpo);
      case TipoAcao.devolver:
        try {
          return await api.post('$base/devolver', acao.corpo);
        } on ApiException catch (e) {
          // A devolucao anterior chegou e so a resposta se perdeu: a API recusa
          // a repeticao porque a entrega ja nao esta em andamento.
          if (!e.conflito) rethrow;
          final atual = await api.get(base);
          if (atual is Map && atual['status'] == 'devolvida') return atual;
          rethrow;
        }
      case TipoAcao.enviarComprovante:
        final bytes = acao.bytes ?? await File(acao.arquivo!).readAsBytes();
        return api.enviarArquivo(
          '$base/comprovante',
          bytes,
          acao.nomeDoArquivo ?? 'comprovante.jpg',
        );
      case TipoAcao.removerComprovante:
        return api.delete('$base/comprovante');
    }
  }

  static String _recusa(AcaoPendente acao, String motivo) {
    final numero = acao.numero;
    return switch (acao.tipo) {
      TipoAcao.concluir => 'A conclusão da entrega #$numero não foi aceita pela loja: $motivo',
      TipoAcao.devolver => 'A devolução da entrega #$numero não foi aceita pela loja: $motivo',
      TipoAcao.enviarComprovante => 'O comprovante da entrega #$numero não foi aceito: $motivo',
      TipoAcao.removerComprovante =>
        'Não foi possível remover o comprovante da entrega #$numero: $motivo',
    };
  }

  /// Com [espera] nula, mantem a tentativa ja marcada.
  void _agendar(Duration? espera) {
    if (_descartada || _acoes.isEmpty) return;
    if (espera == null && _novaTentativa != null) return;
    _novaTentativa?.cancel();
    _novaTentativa = Timer(espera ?? _espera.depoisDeFalhar(), enviar);
  }

  void _aoMudarConexao() {
    if (api.conectado.value && _acoes.isNotEmpty) unawaited(enviar());
  }

  Future<void> _gravar() => _acoes.isEmpty
      ? dados.apagar('pendencias')
      : dados.gravar('pendencias', [for (final a in _acoes) a.toJson()]);

  void _avisar() {
    if (!_descartada) notifyListeners();
  }

  @override
  void dispose() {
    _descartada = true;
    _novaTentativa?.cancel();
    api.conectado.removeListener(_aoMudarConexao);
    super.dispose();
  }
}
