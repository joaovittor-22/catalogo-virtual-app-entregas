import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/armazem.dart';
import '../core/geo.dart';
import '../core/localizacao.dart';
import 'corrida.dart';
import 'pendencias.dart';
import 'rastreador.dart';
import 'rota_service.dart';

/// Uma corrida em andamento: rastreio, chegada, conclusao.
class CorridaController extends ChangeNotifier {
  CorridaController({
    required this.api,
    required this.localizacao,
    required RotaService rotas,
    required this.corrida,
    Pendencias? pendencias,
  }) : pendencias = pendencias ?? Pendencias(api: api, dados: DadosLocais(ArmazemEmMemoria(), '')),
       _pendenciasProprias = pendencias == null,
       rastreador = Rastreador(
         api: api,
         localizacao: localizacao,
         rotas: rotas,
         entregaId: corrida.id,
         destino: corrida.destino,
       ) {
    rastreador.estado.addListener(_avisar);
    rastreador.aoEncerrarPelaLoja = _encerradaPelaLoja;
  }

  /// De quanto em quanto tempo confere se a loja encerrou a corrida.
  static const intervaloDeConferencia = Duration(seconds: 25);

  final ApiClient api;
  final Localizacao localizacao;
  final Rastreador rastreador;

  /// RF-E12: concluir, devolver e o comprovante passam por aqui e, sem rede,
  /// ficam guardados para depois.
  final Pendencias pendencias;
  final bool _pendenciasProprias;
  Corrida corrida;

  bool enviando = false;

  /// Concluida ou devolvida sem rede: ja acabou para o entregador, e a API
  /// recebe quando a conexao voltar.
  bool guardadaParaEnviar = false;

  /// Foto do comprovante tirada sem rede, esperando para subir.
  bool comprovanteGuardado = false;

  /// O que o entregador fez no comprovante e a API ainda nao sabe.
  bool? _comprovanteLocal;

  bool get temComprovante => _comprovanteLocal ?? corrida.temComprovante;

  /// Envio ou remocao da foto do comprovante em andamento.
  bool enviandoComprovante = false;

  /// Foto enviada nesta sessao, para mostrar na tela sem baixar de novo.
  Uint8List? fotoDoComprovante;

  /// A loja concluiu, cancelou ou liberou o pedido por conta propria.
  bool encerradaPelaLoja = false;

  Timer? _conferencia;
  bool _descartado = false;

  EstadoRastreio get rastreio => rastreador.estado.value;

  /// Distancia em linha reta ate o destino, quando as duas pontas sao conhecidas.
  double? get distanciaAoDestinoM {
    final destino = corrida.destino;
    final posicao = rastreio.posicao;
    return destino == null || posicao == null ? null : distanciaM(posicao.ponto, destino);
  }

  /// Chegou perto o bastante para liberar "Concluir entrega".
  bool get pertoDoDestino {
    final distancia = distanciaAoDestinoM;
    return distancia != null && distancia <= corrida.raioChegadaM;
  }

  /// Comeca o rastreio. [explicar] mostra para que serve a localizacao e
  /// devolve se o entregador aceitou ver o pedido de permissao.
  ///
  /// RF-E11: negada a permissao, a corrida segue normalmente, sem rastreio.
  Future<void> comecar({required Future<bool> Function() explicar}) async {
    _conferencia ??= Timer.periodic(intervaloDeConferencia, (_) => _conferir());
    if (await localizacao.situacao() == Permissao.aPedir && await explicar()) {
      await localizacao.pedir();
    }
    if (!_descartado) await rastreador.iniciar();
  }

  /// O entregador liberou a localizacao depois, pelos ajustes ou pelo aviso.
  Future<void> ativarLocalizacao() async {
    final situacao = await localizacao.pedir();
    if (situacao == Permissao.bloqueada || situacao == Permissao.gpsDesligado) {
      await localizacao.abrirAjustes();
    }
    await rastreador.iniciar();
  }

  /// RF-E08: conclui a entrega. Sem rede, a conclusao fica guardada com a
  /// hora em que aconteceu e o entregador segue para a proxima (RF-E12). So
  /// uma recusa da API (a loja encerrou antes, por exemplo) mantem a corrida
  /// aberta, com o motivo.
  Future<void> concluir({String? observacao}) => _encerrar(() async {
    // As ultimas posicoes vao antes, enquanto ainda ha corrida para recebe-las.
    if (api.conectado.value) await rastreador.enviar();
    final posicao = rastreio.posicao?.ponto;
    return _acao(TipoAcao.concluir, {
      if (observacao != null && observacao.trim().isNotEmpty) 'observacao': observacao.trim(),
      if (posicao != null) 'latitude': posicao.latitude,
      if (posicao != null) 'longitude': posicao.longitude,
    });
  });

  /// Foto opcional do comprovante de pagamento. Sem rede, guarda o [caminho]
  /// da foto no aparelho e envia depois. Lanca [ApiException] com a mensagem
  /// pronta se a API recusar (formato, tamanho).
  Future<void> enviarComprovante(Uint8List foto, String nomeDoArquivo, {String? caminho}) =>
      _comprovante(() async {
        // Foto trocada antes de subir: so a ultima interessa.
        await pendencias.cancelar(_fotoDestaCorrida);
        final acao = _acao(
          TipoAcao.enviarComprovante,
          const {},
          arquivo: caminho,
          nomeDoArquivo: nomeDoArquivo,
          bytes: foto,
        );
        final resultado = caminho == null
            // Sem arquivo no aparelho nao ha o que reenviar: so na hora.
            ? (
                guardada: false,
                resposta: await api.enviarArquivo(
                  '/api/entregador/entregas/${corrida.id}/comprovante',
                  foto,
                  nomeDoArquivo,
                ),
              )
            : await pendencias.executar(acao);
        fotoDoComprovante = foto;
        comprovanteGuardado = resultado.guardada;
        if (resultado.guardada) _comprovanteLocal = true;
        return resultado;
      });

  Future<void> removerComprovante() => _comprovante(() async {
    final ({bool guardada, Object? resposta}) resultado;
    if (comprovanteGuardado && await pendencias.cancelar(_fotoDestaCorrida)) {
      // A foto nem tinha subido.
      resultado = (guardada: true, resposta: null);
    } else {
      resultado = await pendencias.executar(_acao(TipoAcao.removerComprovante, const {}));
    }
    fotoDoComprovante = null;
    comprovanteGuardado = false;
    if (resultado.guardada) _comprovanteLocal = false;
    return resultado;
  });

  Future<void> _comprovante(Future<({bool guardada, Object? resposta})> Function() chamada) async {
    if (enviandoComprovante) return;
    enviandoComprovante = true;
    _avisar();
    try {
      final resposta = (await chamada()).resposta;
      if (resposta is Map<String, dynamic>) {
        corrida = Corrida.fromJson(resposta);
        _comprovanteLocal = null;
      }
    } finally {
      enviandoComprovante = false;
      _avisar();
    }
  }

  /// RF-E09: nao deu para entregar. O pedido volta a fila — sem rede, assim
  /// que a devolucao chegar a API.
  Future<void> devolver(String motivo) =>
      _encerrar(() async => _acao(TipoAcao.devolver, {'motivo': motivo.trim()}));

  bool _fotoDestaCorrida(AcaoPendente acao) =>
      acao.entregaId == corrida.id && acao.tipo == TipoAcao.enviarComprovante;

  AcaoPendente _acao(
    TipoAcao tipo,
    Map<String, dynamic> corpo, {
    String? arquivo,
    String? nomeDoArquivo,
    Uint8List? bytes,
  }) => AcaoPendente(
    tipo: tipo,
    entregaId: corrida.id,
    numero: corrida.numero,
    // A hora em que aconteceu, e nao a hora em que a rede voltou.
    corpo: {
      ...corpo,
      if (tipo == TipoAcao.concluir || tipo == TipoAcao.devolver)
        'ocorridaEm': DateTime.now().toUtc().toIso8601String(),
    },
    arquivo: arquivo,
    nomeDoArquivo: nomeDoArquivo,
    bytes: bytes,
  );

  Future<void> _encerrar(Future<AcaoPendente> Function() criar) async {
    if (enviando) return;
    enviando = true;
    _avisar();
    try {
      final resultado = await pendencias.executar(await criar());
      if (resultado.resposta case final Map<String, dynamic> resposta) {
        corrida = Corrida.fromJson(resposta);
      }
      guardadaParaEnviar = resultado.guardada;
      await _pararTudo();
    } finally {
      enviando = false;
      _avisar();
    }
  }

  Future<void> _conferir() async {
    if (enviando || encerradaPelaLoja || _descartado || guardadaParaEnviar) return;
    // RNF-E05: a resposta de cada lote de posicoes ja diz se a corrida segue.
    // So pergunta quando nenhum lote chegou a API nesse tempo (parado, sem GPS).
    final contato = rastreador.ultimoContatoEm;
    if (contato != null && DateTime.now().difference(contato) < intervaloDeConferencia) return;
    try {
      final resposta = await api.get('/api/entregador/entregas/${corrida.id}');
      final atual = Corrida.fromJson(resposta as Map<String, dynamic>);
      if (!atual.emRota) {
        corrida = atual;
        await _encerradaPelaLoja();
      }
    } on ApiException {
      // Sem rede agora: confere de novo no proximo ciclo.
    }
  }

  Future<void> _encerradaPelaLoja() async {
    if (encerradaPelaLoja) return;
    encerradaPelaLoja = true;
    await _pararTudo();
    _avisar();
  }

  Future<void> _pararTudo() async {
    _conferencia?.cancel();
    _conferencia = null;
    await rastreador.parar();
  }

  void _avisar() {
    if (!_descartado) notifyListeners();
  }

  @override
  void dispose() {
    _descartado = true;
    rastreador.estado.removeListener(_avisar);
    _pararTudo();
    if (_pendenciasProprias) pendencias.dispose();
    super.dispose();
  }
}
