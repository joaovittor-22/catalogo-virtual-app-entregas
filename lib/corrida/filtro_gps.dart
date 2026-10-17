import 'dart:math' as math;

import '../core/geo.dart';

/// Leitura crua do sensor.
class Leitura {
  const Leitura({
    required this.ponto,
    required this.precisaoM,
    required this.em,
    this.velocidadeMs,
    this.direcaoGraus,
  });

  final Ponto ponto;

  /// Raio de incerteza informado pelo aparelho, em metros.
  final double precisaoM;
  final DateTime em;
  final double? velocidadeMs;
  final double? direcaoGraus;
}

/// Posicao ja corrigida, pronta para enviar.
class PosicaoCorrigida {
  const PosicaoCorrigida({
    required this.ponto,
    required this.precisaoM,
    required this.em,
    this.velocidadeMs,
    this.direcaoGraus,
  });

  final Ponto ponto;
  final double precisaoM;
  final DateTime em;
  final double? velocidadeMs;
  final double? direcaoGraus;
}

/// Corrige as imprecisoes do GPS antes de a posicao sair do aparelho.
///
/// O sensor erra de tres jeitos, e cada um tem o seu remedio:
///
///  1. **Leitura ruim** (pouco ceu visivel, primeira leitura): vem com raio de
///     incerteza grande. E descartada.
///  2. **Salto**: um ponto isolado a centenas de metros, que exigiria uma
///     velocidade impossivel. E descartado; se varios seguidos concordam
///     entre si, o errado era o anterior e o filtro recomeca dali.
///  3. **Tremor**: mesmo parado, o ponto passeia alguns metros — e o que poe
///     a moto "em cima da casa". Um filtro de Kalman pondera cada leitura
///     pela precisao dela, e com o entregador parado a posicao nao se mexe.
///     Andando em linha reta, o filtro preve onde a moto deve estar pela
///     velocidade e pelo rumo, e a leitura so corrige essa previsao: o
///     zigue-zague lateral some sem a posicao ficar para tras.
///
/// O encaixe na rua (map matching) vem depois, no rastreador, quando ha rota.
class FiltroGps {
  /// Acima disso a leitura nao e confiavel o bastante para desenhar.
  static const double precisaoMaximaM = 50;

  /// Sem nenhuma leitura boa por este tempo, aceita uma pior: mostrar a moto
  /// com alguma folga e melhor do que deixa-la parada no mapa.
  static const Duration esperaPorLeituraBoa = Duration(seconds: 25);
  static const double precisaoToleradaM = 120;

  /// ~150 km/h: mais do que isso entre duas leituras nao e uma moto.
  static const double velocidadeMaximaMs = 42;

  /// Leituras "impossiveis" seguidas ate o filtro aceitar que estava errado.
  static const int saltosAteRecomecar = 3;

  /// Abaixo disso o entregador e considerado parado.
  static const double velocidadeParadoMs = 0.7;

  /// Quanto a posicao real pode mudar por segundo, no minimo (m/s).
  static const double ruidoMinimoMs = 3;

  /// A partir desta velocidade o rumo informado pelo GPS e confiavel.
  static const double velocidadeComRumoMs = 2;

  /// Mudanca de rumo que conta como curva: ai a previsao em linha reta erra,
  /// e a leitura volta a mandar.
  static const double curvaGraus = 30;

  /// Intervalo maximo entre leituras para ainda valer a previsao.
  static const double previsaoMaximaS = 6;

  Ponto? _estimativa;
  double _variancia = 0;
  DateTime? _ultimaEm;
  double? _ultimoRumo;
  int _saltos = 0;

  Ponto? get estimativa => _estimativa;

  void reiniciar() {
    _estimativa = null;
    _variancia = 0;
    _ultimaEm = null;
    _ultimoRumo = null;
    _saltos = 0;
  }

  /// Devolve a posicao corrigida, ou nulo quando a leitura foi descartada ou
  /// nao mudou nada (parado).
  PosicaoCorrigida? processar(Leitura leitura) {
    final anterior = _estimativa;
    final ultimaEm = _ultimaEm;

    // 1. Leitura ruim.
    if (leitura.precisaoM <= 0) return null;
    if (leitura.precisaoM > precisaoMaximaM) {
      final semLeituraHaMuito =
          ultimaEm == null || leitura.em.difference(ultimaEm) >= esperaPorLeituraBoa;
      if (!semLeituraHaMuito || leitura.precisaoM > precisaoToleradaM) return null;
    }

    if (anterior == null || ultimaEm == null) return _recomecar(leitura);

    final segundos = leitura.em.difference(ultimaEm).inMilliseconds / 1000;
    // Relogio voltou ou leitura repetida.
    if (segundos <= 0) return null;

    // 2. Salto impossivel.
    final deslocamento = distanciaM(anterior, leitura.ponto);
    if (deslocamento / math.max(segundos, 1) > velocidadeMaximaMs) {
      if (++_saltos < saltosAteRecomecar) return null;
      return _recomecar(leitura);
    }
    _saltos = 0;

    // 3. Parado: o que sobra de movimento e tremor do sensor.
    final velocidade = leitura.velocidadeMs;
    final parado = velocidade != null && velocidade < velocidadeParadoMs;
    if (parado && deslocamento < math.max(leitura.precisaoM, 12)) {
      _ultimaEm = leitura.em;
      _ultimoRumo = null;
      return null;
    }

    // Previsao: em linha reta, a moto deve estar onde a velocidade e o rumo
    // dizem. Numa curva (ou sem rumo confiavel) nao ha o que prever, e a
    // incerteza cresce com a propria velocidade.
    final rumo = leitura.direcaoGraus;
    final rumoAnterior = _ultimoRumo;
    final comRumo = velocidade != null && velocidade >= velocidadeComRumoMs && rumo != null;
    final emLinhaReta =
        comRumo &&
        rumoAnterior != null &&
        segundos <= previsaoMaximaS &&
        _diferencaDeRumo(rumoAnterior, rumo) <= curvaGraus;
    final previsto = emLinhaReta ? _avancar(anterior, velocidade * segundos, rumo) : anterior;
    final ruido = emLinhaReta ? ruidoMinimoMs : math.max(ruidoMinimoMs, velocidade ?? 0);
    _ultimoRumo = comRumo ? rumo : null;

    // Kalman: cada leitura puxa a previsao na proporcao da confianca que merece.
    _variancia += segundos * ruido * ruido;
    final ganho = _variancia / (_variancia + leitura.precisaoM * leitura.precisaoM);
    final corrigido = Ponto(
      previsto.latitude + ganho * (leitura.ponto.latitude - previsto.latitude),
      previsto.longitude + ganho * (leitura.ponto.longitude - previsto.longitude),
    );
    _variancia = (1 - ganho) * _variancia;
    _estimativa = corrigido;
    _ultimaEm = leitura.em;

    return PosicaoCorrigida(
      ponto: corrigido,
      precisaoM: math.sqrt(_variancia),
      em: leitura.em,
      velocidadeMs: leitura.velocidadeMs,
      direcaoGraus: leitura.direcaoGraus,
    );
  }

  /// Menor angulo entre dois rumos, em graus (0 a 180).
  static double _diferencaDeRumo(double a, double b) {
    final diferenca = (a - b).abs() % 360;
    return diferenca > 180 ? 360 - diferenca : diferenca;
  }

  /// Ponto a [metros] de [origem] no [rumo] (graus a partir do norte).
  static Ponto _avancar(Ponto origem, double metros, double rumo) {
    const metrosPorGrau = 111320.0;
    final angulo = rumo * math.pi / 180;
    final cosLatitude = math.cos(origem.latitude * math.pi / 180);
    return Ponto(
      origem.latitude + metros * math.cos(angulo) / metrosPorGrau,
      origem.longitude + metros * math.sin(angulo) / (metrosPorGrau * cosLatitude),
    );
  }

  PosicaoCorrigida _recomecar(Leitura leitura) {
    _estimativa = leitura.ponto;
    _variancia = leitura.precisaoM * leitura.precisaoM;
    _ultimaEm = leitura.em;
    _ultimoRumo = null;
    _saltos = 0;
    return PosicaoCorrigida(
      ponto: leitura.ponto,
      precisaoM: leitura.precisaoM,
      em: leitura.em,
      velocidadeMs: leitura.velocidadeMs,
      direcaoGraus: leitura.direcaoGraus,
    );
  }
}
