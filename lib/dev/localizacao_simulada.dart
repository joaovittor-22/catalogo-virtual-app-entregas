import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/geo.dart';
import '../core/localizacao.dart';
import '../corrida/filtro_gps.dart';
import '../corrida/rota_service.dart';

/// Falhas de GPS que o painel da demonstracao pode provocar.
enum Anomalia {
  salto('Salto', 'Uma leitura a 400 m do lugar certo'),
  saltoPersistente('Salto persistente', '4 leituras seguidas a 600 m'),
  precisaoRuim('Precisão ruim', '8 leituras com raio de ~90 m'),
  parado('Parado', '15 s parado, com o ponto tremendo'),
  desvio('Desvio', 'Pega outra rua, fora da rota traçada'),
  semSinal('Sem sinal', '20 s sem nenhuma leitura');

  const Anomalia(this.titulo, this.descricao);

  final String titulo;
  final String descricao;
}

/// Leitura emitida, com a posicao verdadeira e a falha que a gerou.
class LeituraSimulada {
  const LeituraSimulada(this.leitura, this.verdadeira, this.anomalia);

  final Leitura leitura;
  final Ponto verdadeira;
  final Anomalia? anomalia;
}

/// GPS de mentira para o modo demonstracao: a moto percorre o caminho por rua
/// ate o destino, uma leitura por segundo, com o ruido normal de um aparelho
/// e as falhas que o painel mandar ([provocar]).
class LocalizacaoSimulada extends ChangeNotifier implements Localizacao {
  LocalizacaoSimulada({required Ponto inicio, required this.rotas}) : _posicao = inicio;

  static const intervalo = Duration(seconds: 1);

  final RotaService rotas;
  final _sorteio = math.Random();

  double _velocidadeMs = 8.3;
  bool _pausado = false;

  /// Velocidade da moto, em m/s.
  double get velocidadeMs => _velocidadeMs;
  set velocidadeMs(double valor) {
    _velocidadeMs = valor;
    notifyListeners();
  }

  bool get pausado => _pausado;
  set pausado(bool valor) {
    _pausado = valor;
    notifyListeners();
  }

  Ponto _posicao;
  double _rumo = 0;
  List<Ponto> _trajeto = const [];
  List<double> _acumuladoM = const [];
  double _percorridoM = 0;

  Anomalia? _anomalia;
  int _restantes = 0;
  double _direcaoDoSalto = 0;

  Timer? _relogio;
  late final _leituras = StreamController<Leitura>.broadcast(onCancel: _desligar);
  final _emitidas = StreamController<LeituraSimulada>.broadcast();

  /// Onde a moto esta de verdade, sem ruido.
  Ponto get posicao => _posicao;

  /// Caminho que a moto segue (nao e a rota que o app traca).
  List<Ponto> get trajeto => _trajeto;
  Anomalia? get anomalia => _anomalia;
  int get restantes => _restantes;
  bool get chegou => _trajeto.isNotEmpty && _percorridoM >= _acumuladoM.last;

  /// Cada leitura que saiu do "sensor", para o painel desenhar.
  Stream<LeituraSimulada> get emitidas => _emitidas.stream;

  /// Traca o caminho ate [destino]; a moto anda nele enquanto houver rastreio.
  Future<void> irPara(Ponto destino) async {
    _anomalia = null;
    _definirTrajeto(await _caminho(_posicao, destino));
  }

  void provocar(Anomalia anomalia) {
    if (anomalia == Anomalia.desvio) {
      unawaited(_desviar());
      return;
    }
    _anomalia = anomalia;
    _direcaoDoSalto = _sorteio.nextDouble() * 360;
    _restantes = switch (anomalia) {
      Anomalia.salto => 1,
      Anomalia.saltoPersistente => 4,
      Anomalia.precisaoRuim => 8,
      Anomalia.parado => 15,
      Anomalia.semSinal => 20,
      Anomalia.desvio => 0,
    };
    notifyListeners();
  }

  /// Sai do caminho por uma rua ao lado e so depois segue para o destino.
  Future<void> _desviar() async {
    if (_trajeto.isEmpty || chegou) return;
    final destino = _trajeto.last;
    final lado = _sorteio.nextBool() ? 90 : -90;
    final desvio = _avancar(_avancar(_posicao, 250, _rumo), 350, _rumo + lado);
    final ida = await _caminho(_posicao, desvio);
    final volta = await _caminho(desvio, destino);
    _definirTrajeto([...ida, ...volta.skip(1)]);
  }

  Future<List<Ponto>> _caminho(Ponto de, Ponto ate) async =>
      (await rotas.rota(de, ate))?.pontos ?? [de, ate];

  void _definirTrajeto(List<Ponto> pontos) {
    final acumulado = <double>[0];
    for (var i = 1; i < pontos.length; i++) {
      acumulado.add(acumulado.last + distanciaM(pontos[i - 1], pontos[i]));
    }
    _trajeto = pontos;
    _acumuladoM = acumulado;
    _percorridoM = 0;
    notifyListeners();
  }

  void _passo() {
    if (pausado) return;
    final anomalia = _anomalia;
    if (anomalia != null && --_restantes <= 0) _anomalia = null;

    final parado = anomalia == Anomalia.parado || _trajeto.length < 2 || chegou;
    if (!parado) _andar(velocidadeMs * intervalo.inMilliseconds / 1000);
    notifyListeners();
    if (anomalia == Anomalia.semSinal) return;

    var ponto = _comRuido(_posicao, parado ? 5 : 3);
    var precisaoM = 5 + _sorteio.nextDouble() * 5;
    switch (anomalia) {
      case Anomalia.salto:
        ponto = _avancar(_posicao, 400, _direcaoDoSalto);
      case Anomalia.saltoPersistente:
        ponto = _comRuido(_avancar(_posicao, 600, _direcaoDoSalto), 3);
      case Anomalia.precisaoRuim:
        ponto = _comRuido(_posicao, 50);
        precisaoM = 80 + _sorteio.nextDouble() * 30;
      default:
        break;
    }
    final leitura = Leitura(
      ponto: ponto,
      precisaoM: precisaoM,
      em: DateTime.now(),
      velocidadeMs: parado ? 0 : velocidadeMs + _sorteio.nextDouble() - 0.5,
      direcaoGraus: parado ? null : _rumo,
    );
    _emitidas.add(LeituraSimulada(leitura, _posicao, anomalia));
    _leituras.add(leitura);
  }

  void _andar(double metros) {
    _percorridoM = math.min(_percorridoM + metros, _acumuladoM.last);
    var i = 0;
    while (i < _acumuladoM.length - 2 && _acumuladoM[i + 1] < _percorridoM) {
      i++;
    }
    final inicio = _trajeto[i];
    final fim = _trajeto[i + 1];
    final trechoM = _acumuladoM[i + 1] - _acumuladoM[i];
    final t = trechoM == 0 ? 0.0 : (_percorridoM - _acumuladoM[i]) / trechoM;
    _posicao = Ponto(
      inicio.latitude + (fim.latitude - inicio.latitude) * t,
      inicio.longitude + (fim.longitude - inicio.longitude) * t,
    );
    if (trechoM > 0) _rumo = _rumoEntre(inicio, fim);
  }

  /// Desvio aleatorio (normal, [sigmaM] em metros) em torno de [p].
  Ponto _comRuido(Ponto p, double sigmaM) {
    double normal() =>
        math.sqrt(-2 * math.log(1 - _sorteio.nextDouble())) *
        math.cos(2 * math.pi * _sorteio.nextDouble());
    return _deslocar(p, normal() * sigmaM, normal() * sigmaM);
  }

  static Ponto _avancar(Ponto origem, double metros, double rumo) {
    final angulo = rumo * math.pi / 180;
    return _deslocar(origem, metros * math.cos(angulo), metros * math.sin(angulo));
  }

  static Ponto _deslocar(Ponto p, double norteM, double lesteM) {
    const metrosPorGrau = 111320.0;
    return Ponto(
      p.latitude + norteM / metrosPorGrau,
      p.longitude + lesteM / (metrosPorGrau * math.cos(p.latitude * math.pi / 180)),
    );
  }

  static double _rumoEntre(Ponto a, Ponto b) {
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  void _desligar() {
    _relogio?.cancel();
    _relogio = null;
  }

  @override
  Future<Permissao> situacao() async => Permissao.concedida;

  @override
  Future<Permissao> pedir() async => Permissao.concedida;

  @override
  Future<Ponto?> posicaoAtual() async => _posicao;

  @override
  Stream<Leitura> acompanhar() {
    _relogio ??= Timer.periodic(intervalo, (_) => _passo());
    return _leituras.stream;
  }

  @override
  Future<void> abrirAjustes() async {}
}
