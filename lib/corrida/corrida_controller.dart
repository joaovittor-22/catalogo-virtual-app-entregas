import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/geo.dart';
import '../core/localizacao.dart';
import 'corrida.dart';
import 'rastreador.dart';
import 'rota_service.dart';

/// Uma corrida em andamento: rastreio, chegada, conclusao.
class CorridaController extends ChangeNotifier {
  CorridaController({
    required this.api,
    required this.localizacao,
    required RotaService rotas,
    required this.corrida,
  }) : rastreador = Rastreador(
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
  Corrida corrida;

  bool enviando = false;

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

  /// RF-E08: conclui a entrega. So para de rastrear depois que a API
  /// confirma — se a rede cair, o entregador tenta de novo sem perder nada.
  Future<void> concluir({String? observacao}) => _encerrar(() async {
    await rastreador.enviar();
    final posicao = rastreio.posicao?.ponto;
    return api.post('/api/entregador/entregas/${corrida.id}/concluir', {
      if (observacao != null && observacao.trim().isNotEmpty) 'observacao': observacao.trim(),
      if (posicao != null) 'latitude': posicao.latitude,
      if (posicao != null) 'longitude': posicao.longitude,
    });
  });

  /// Foto opcional do comprovante de pagamento. Lanca [ApiException] com a
  /// mensagem pronta se a API recusar (formato, tamanho, rede).
  Future<void> enviarComprovante(Uint8List foto, String nomeDoArquivo) => _comprovante(() async {
    final resposta = await api.enviarArquivo(
      '/api/entregador/entregas/${corrida.id}/comprovante',
      foto,
      nomeDoArquivo,
    );
    fotoDoComprovante = foto;
    return resposta;
  });

  Future<void> removerComprovante() => _comprovante(() async {
    final resposta = await api.delete('/api/entregador/entregas/${corrida.id}/comprovante');
    fotoDoComprovante = null;
    return resposta;
  });

  Future<void> _comprovante(Future<dynamic> Function() chamada) async {
    if (enviandoComprovante) return;
    enviandoComprovante = true;
    _avisar();
    try {
      corrida = Corrida.fromJson(await chamada() as Map<String, dynamic>);
    } finally {
      enviandoComprovante = false;
      _avisar();
    }
  }

  /// RF-E09: nao deu para entregar. O pedido volta a fila.
  Future<void> devolver(String motivo) => _encerrar(
    () => api.post('/api/entregador/entregas/${corrida.id}/devolver', {'motivo': motivo.trim()}),
  );

  Future<void> _encerrar(Future<dynamic> Function() chamada) async {
    if (enviando) return;
    enviando = true;
    _avisar();
    try {
      final resposta = await chamada();
      corrida = Corrida.fromJson(resposta as Map<String, dynamic>);
      await _pararTudo();
    } finally {
      enviando = false;
      _avisar();
    }
  }

  Future<void> _conferir() async {
    if (enviando || encerradaPelaLoja || _descartado) return;
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
    super.dispose();
  }
}
