import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/espera.dart';
import '../core/geo.dart';
import '../core/localizacao.dart';
import 'filtro_gps.dart';
import 'rota_service.dart';

enum SituacaoRastreio {
  parado,

  /// Enviando a posicao.
  ativo,

  /// Sem permissao ou com o GPS desligado: a corrida segue, sem rastreio.
  semLocalizacao,
}

@immutable
class EstadoRastreio {
  const EstadoRastreio({
    this.situacao = SituacaoRastreio.parado,
    this.posicao,
    this.rota,
    this.pendentes = 0,
    this.semConexao = false,
  });

  final SituacaoRastreio situacao;

  /// Ultima posicao corrigida.
  final PosicaoCorrigida? posicao;
  final Rota? rota;

  /// Posicoes ainda nao enviadas (a rede caiu).
  final int pendentes;
  final bool semConexao;

  EstadoRastreio copiar({
    SituacaoRastreio? situacao,
    PosicaoCorrigida? posicao,
    Rota? rota,
    int? pendentes,
    bool? semConexao,
  }) => EstadoRastreio(
    situacao: situacao ?? this.situacao,
    posicao: posicao ?? this.posicao,
    rota: rota ?? this.rota,
    pendentes: pendentes ?? this.pendentes,
    semConexao: semConexao ?? this.semConexao,
  );
}

/// Envia a posicao do entregador durante a corrida — e so durante ela.
///
/// Cada leitura passa pelo [FiltroGps] e, havendo rota, e encaixada na rua
/// quando esta perto dela. As posicoes saem em lote, de tempos em tempos
/// conforme a distancia que falta (RNF-E05), e o que nao foi enviado por falta
/// de rede fica na fila para a proxima tentativa (RF-E12).
class Rastreador {
  Rastreador({
    required this.api,
    required this.localizacao,
    required this.rotas,
    required this.entregaId,
    required this.destino,
  });

  /// RNF-E05: de quanto em quanto tempo o lote sai, pela distancia ate o
  /// cliente. Perto dele, que esta olhando o mapa, sai mais vezes; longe, as
  /// leituras se juntam em lotes maiores e o radio do celular acorda menos.
  static const intervaloPerto = Duration(seconds: 3);
  static const intervaloNoCaminho = Duration(seconds: 6);
  static const intervaloLonge = Duration(seconds: 10);
  static const double pertoM = 1000;
  static const double longeM = 3000;

  /// Sem rede, a espera entre tentativas dobra ate este teto. Fica bem abaixo
  /// do minuto em que o mapa do cliente passa a avisar que o sinal caiu.
  static const esperaMaxima = Duration(seconds: 30);

  /// Ate quantos metros da rota a posicao e puxada para cima dela.
  static const double raioDeEncaixeM = 35;

  /// Leituras seguidas fora da rota ate pedir um caminho novo.
  static const int leiturasForaAteRecalcular = 3;
  static const Duration intervaloEntreRotas = Duration(seconds: 30);
  static const int _tamanhoDoLote = 100;
  static const int _limiteDaFila = 600;
  static const int _maximoDePontosDaRota = 3000;

  final ApiClient api;
  final Localizacao localizacao;
  final RotaService rotas;
  final int entregaId;

  /// Nulo quando o endereco nao foi localizado: rastreia sem rota.
  final Ponto? destino;

  final ValueNotifier<EstadoRastreio> estado = ValueNotifier(const EstadoRastreio());

  /// A API avisou que a corrida acabou (a loja concluiu, cancelou ou liberou).
  VoidCallback? aoEncerrarPelaLoja;

  final _filtro = FiltroGps();
  final List<PosicaoCorrigida> _fila = [];
  StreamSubscription<Leitura>? _leituras;
  Timer? _envio;
  final _espera = Espera(base: intervaloPerto, maximo: esperaMaxima);
  Duration? _esperaAposFalha;
  bool _enviando = false;
  bool _buscandoRota = false;
  bool _encerrado = false;
  int _foraDaRota = 0;
  DateTime? _ultimaRotaEm;

  bool get ativo => _leituras != null;

  /// Ultima vez que a API recebeu um lote. Enquanto for recente, a resposta do
  /// lote ja diz se a corrida segue, e ninguem precisa perguntar de novo.
  DateTime? ultimoContatoEm;

  /// Intervalo de envio para quem esta a [distanciaM] do destino (nula quando
  /// a posicao ou o destino nao sao conhecidos).
  static Duration intervaloPara(double? distanciaM) {
    if (distanciaM == null) return intervaloNoCaminho;
    if (distanciaM <= pertoM) return intervaloPerto;
    if (distanciaM <= longeM) return intervaloNoCaminho;
    return intervaloLonge;
  }

  Duration get intervaloAtual {
    final posicao = estado.value.posicao?.ponto;
    final destino = this.destino;
    return intervaloPara(posicao == null || destino == null ? null : distanciaM(posicao, destino));
  }

  /// Comeca a rastrear se a localizacao estiver liberada. Nao pede permissao:
  /// isso e decisao da tela, que explica antes para que serve (RF-E11).
  Future<void> iniciar() async {
    if (_encerrado || ativo) return;
    if (await localizacao.situacao() != Permissao.concedida) {
      estado.value = estado.value.copiar(situacao: SituacaoRastreio.semLocalizacao);
      return;
    }
    _leituras = localizacao.acompanhar().listen(
      aoLer,
      onError: (Object _) =>
          estado.value = estado.value.copiar(situacao: SituacaoRastreio.semLocalizacao),
    );
    api.conectado.addListener(_aoMudarConexao);
    _agendar(intervaloAtual);
    estado.value = estado.value.copiar(situacao: SituacaoRastreio.ativo);
  }

  void _agendar(Duration espera) {
    _envio?.cancel();
    if (_encerrado) return;
    _envio = Timer(espera, () async {
      await enviar();
      _agendar(_esperaAposFalha ?? intervaloAtual);
    });
  }

  /// A rede voltou (outra chamada do app teve resposta): manda o que ficou
  /// guardado agora, sem esperar o fim da espera.
  void _aoMudarConexao() {
    if (api.conectado.value && _esperaAposFalha != null && !_enviando) _agendar(Duration.zero);
  }

  @visibleForTesting
  void aoLer(Leitura leitura) {
    if (_encerrado) return;
    final corrigida = _filtro.processar(leitura);
    if (corrigida == null) return;

    var ponto = corrigida.ponto;
    final rota = estado.value.rota;
    if (rota == null) {
      _buscarRota(ponto);
    } else {
      // Perto da rota, a posicao vai para cima da rua. Longe dela varias
      // vezes seguidas, o entregador mudou de caminho: pede uma rota nova.
      final encaixe = encaixarNaRota(ponto, rota.pontos);
      if (encaixe != null && encaixe.distanciaM <= raioDeEncaixeM) {
        ponto = encaixe.ponto;
        _foraDaRota = 0;
      } else if (++_foraDaRota >= leiturasForaAteRecalcular) {
        _buscarRota(ponto);
      }
    }

    final posicao = PosicaoCorrigida(
      ponto: ponto,
      precisaoM: corrigida.precisaoM,
      em: corrigida.em,
      velocidadeMs: corrigida.velocidadeMs,
      direcaoGraus: corrigida.direcaoGraus,
    );
    _fila.add(posicao);
    // Rede fora por muito tempo: descarta as mais antigas, que ja nao
    // interessam a quem acompanha.
    if (_fila.length > _limiteDaFila) _fila.removeRange(0, _fila.length - _limiteDaFila);
    estado.value = estado.value.copiar(posicao: posicao, pendentes: _fila.length);
  }

  Future<void> _buscarRota(Ponto origem) async {
    final destino = this.destino;
    final ultima = _ultimaRotaEm;
    if (destino == null || _buscandoRota || _encerrado) return;
    if (ultima != null && DateTime.now().difference(ultima) < intervaloEntreRotas) return;
    _buscandoRota = true;
    _ultimaRotaEm = DateTime.now();
    try {
      final rota = await rotas.rota(origem, destino);
      if (rota == null || _encerrado) return;
      _foraDaRota = 0;
      estado.value = estado.value.copiar(rota: rota);
      // O cliente ve este caminho no mapa do pedido.
      await api.put('/api/entregador/entregas/$entregaId/rota', {
        'pontos': [
          for (final p in _reduzir(rota.pontos))
            [_arredondar(p.longitude, 6), _arredondar(p.latitude, 6)],
        ],
        'distanciaM': rota.distanciaM.round(),
        'duracaoS': rota.duracaoS.round(),
      });
    } on ApiException {
      // A rota e um extra: sem ela o rastreio continua.
    } finally {
      _buscandoRota = false;
    }
  }

  /// Envia o que esta na fila. Chamado pelo temporizador e ao concluir.
  Future<void> enviar() async {
    if (_enviando || _fila.isEmpty || _encerrado) return;
    _enviando = true;
    final lote = _fila.take(_tamanhoDoLote).toList();
    try {
      final resposta = await api.post('/api/entregador/entregas/$entregaId/posicoes', {
        'posicoes': [
          for (final p in lote)
            {
              'latitude': _arredondar(p.ponto.latitude, 7),
              'longitude': _arredondar(p.ponto.longitude, 7),
              'precisaoM': _arredondar(p.precisaoM, 1),
              if (p.velocidadeMs != null) 'velocidadeMs': _arredondar(p.velocidadeMs!, 2),
              if (p.direcaoGraus != null) 'direcaoGraus': _arredondar(p.direcaoGraus!, 1),
              'registradaEm': p.em.toUtc().toIso8601String(),
            },
        ],
      });
      _removerEnviadas(lote.length);
      _espera.zerar();
      _esperaAposFalha = null;
      ultimoContatoEm = DateTime.now();
      estado.value = estado.value.copiar(pendentes: _fila.length, semConexao: false);
      if (resposta is Map && resposta['rastreioAtivo'] == false) {
        await parar();
        aoEncerrarPelaLoja?.call();
      }
    } on ApiException catch (e) {
      if (e.passageiro) {
        // Fica na fila para a proxima tentativa (RF-E12), cada vez mais
        // espacada. Com a API pedindo calma (429), espera o teto direto.
        final espera = _espera.depoisDeFalhar();
        _esperaAposFalha = e.status == 429 ? esperaMaxima : espera;
        estado.value = estado.value.copiar(semConexao: e.semConexao);
      } else if (e.status == 404) {
        await parar();
        aoEncerrarPelaLoja?.call();
      } else {
        // Lote recusado como invalido: insistir nele travaria a fila.
        _removerEnviadas(lote.length);
        _espera.zerar();
        _esperaAposFalha = null;
      }
    } finally {
      _enviando = false;
    }
  }

  void _removerEnviadas(int quantidade) => _fila.removeRange(0, quantidade.clamp(0, _fila.length));

  /// Para de ler o GPS e de enviar. Depois disso nada mais sai do aparelho.
  Future<void> parar() async {
    _encerrado = true;
    _envio?.cancel();
    _envio = null;
    api.conectado.removeListener(_aoMudarConexao);
    // Cancelar ja corta as leituras na hora; nao ha por que esperar o aparelho
    // terminar de desligar o GPS para seguir.
    unawaited(_leituras?.cancel());
    _leituras = null;
    _fila.clear();
    estado.value = estado.value.copiar(situacao: SituacaoRastreio.parado, pendentes: 0);
  }

  static double _arredondar(double valor, int casas) => double.parse(valor.toStringAsFixed(casas));

  /// Rotas longas vem com milhares de pontos; a API aceita um limite.
  static List<Ponto> _reduzir(List<Ponto> pontos) {
    if (pontos.length <= _maximoDePontosDaRota) return pontos;
    final passo = (pontos.length / _maximoDePontosDaRota).ceil();
    return [
      for (var i = 0; i < pontos.length; i += passo) pontos[i],
      if ((pontos.length - 1) % passo != 0) pontos.last,
    ];
  }
}
