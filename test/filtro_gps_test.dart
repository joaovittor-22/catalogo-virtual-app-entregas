import 'package:entregador_app/core/geo.dart';
import 'package:entregador_app/corrida/filtro_gps.dart';
import 'package:flutter_test/flutter_test.dart';

/// ~1 m em graus de latitude.
const _metro = 1 / 111320;
final _inicio = DateTime.utc(2026, 10, 12, 12);

Leitura _leitura(
  double norteM,
  double lesteM,
  int segundo, {
  double precisao = 8,
  double? velocidade = 10,
  double? rumo,
}) => Leitura(
  ponto: Ponto(-16.68 + norteM * _metro, -49.25 + lesteM * _metro / 0.958),
  precisaoM: precisao,
  em: _inicio.add(Duration(seconds: segundo)),
  velocidadeMs: velocidade,
  direcaoGraus: rumo,
);

double _lesteM(Ponto p, Ponto origem) => (p.longitude - origem.longitude) / (_metro / 0.958);
double _norteM(Ponto p, Ponto origem) => (p.latitude - origem.latitude) / _metro;

void main() {
  final origem = _leitura(0, 0, 0).ponto;

  test('a primeira leitura boa vira a referencia', () {
    final filtro = FiltroGps();
    final posicao = filtro.processar(_leitura(0, 0, 0));
    expect(posicao, isNotNull);
    expect(posicao!.ponto, origem);
  });

  test('descarta leitura com raio de incerteza grande', () {
    final filtro = FiltroGps()..processar(_leitura(0, 0, 0));
    expect(filtro.processar(_leitura(30, 0, 3, precisao: 80)), isNull);
    expect(filtro.estimativa, origem);
  });

  test('sem leitura boa ha muito tempo, aceita uma pior — mas nao qualquer uma', () {
    final filtro = FiltroGps()..processar(_leitura(0, 0, 0));
    expect(filtro.processar(_leitura(300, 0, 30, precisao: 80)), isNotNull);

    final outro = FiltroGps()..processar(_leitura(0, 0, 0));
    expect(outro.processar(_leitura(300, 0, 30, precisao: 400)), isNull);
  });

  test('descarta um salto isolado e segue do ponto anterior', () {
    final filtro = FiltroGps()..processar(_leitura(0, 0, 0));
    // 900 m em 3 s seriam 300 m/s.
    expect(filtro.processar(_leitura(900, 0, 3)), isNull);
    final seguinte = filtro.processar(_leitura(60, 0, 6));
    expect(seguinte, isNotNull);
    expect(distanciaM(origem, seguinte!.ponto), lessThan(70));
  });

  test('saltos seguidos que concordam entre si recomecam o filtro', () {
    final filtro = FiltroGps()..processar(_leitura(0, 0, 0));
    expect(filtro.processar(_leitura(900, 0, 3)), isNull);
    expect(filtro.processar(_leitura(930, 0, 6)), isNull);
    // Terceira leitura na mesma regiao: quem estava errada era a referencia.
    final recomeco = filtro.processar(_leitura(960, 0, 9));
    expect(recomeco, isNotNull);
    expect(distanciaM(origem, recomeco!.ponto), greaterThan(900));
  });

  test('parado, o tremor do sensor nao move a posicao', () {
    final filtro = FiltroGps()..processar(_leitura(0, 0, 0));
    for (var i = 1; i <= 10; i++) {
      final tremor = i.isEven ? 7.0 : -6.0;
      expect(filtro.processar(_leitura(tremor, -tremor, i * 3, velocidade: 0.1)), isNull);
    }
    expect(filtro.estimativa, origem);
  });

  /// Segue para o norte a 10 m/s; o sensor erra 12 m para um lado e para o
  /// outro. Devolve o desvio lateral medio depois de assentar e o avanco final.
  ({double desvio, double avanco}) percorrer({double? rumo}) {
    final filtro = FiltroGps();
    PosicaoCorrigida? ultima;
    var soma = 0.0;
    var amostras = 0;
    for (var i = 0; i <= 30; i++) {
      final ruido = i.isEven ? 12.0 : -12.0;
      ultima = filtro.processar(_leitura(i * 30.0, ruido, i * 3, precisao: 12, rumo: rumo));
      if (i >= 10 && ultima != null) {
        soma += _lesteM(ultima.ponto, origem).abs();
        amostras++;
      }
    }
    expect(amostras, 21);
    return (desvio: soma / amostras, avanco: _norteM(ultima!.ponto, origem));
  }

  test('em linha reta, o zigue-zague de 12 m cai para menos de 3 m, sem atraso', () {
    final resultado = percorrer(rumo: 0);
    expect(resultado.desvio, lessThan(3));
    // A posicao acompanha o avanco real (900 m).
    expect(resultado.avanco, closeTo(900, 3));
  });

  test('sem rumo do GPS ainda suaviza, so que menos', () {
    final resultado = percorrer();
    expect(resultado.desvio, lessThan(8));
    expect(resultado.avanco, closeTo(900, 12));
  });

  test('na curva, segue a leitura em vez de passar reto', () {
    final filtro = FiltroGps();
    // Norte por 150 m...
    for (var i = 0; i <= 5; i++) {
      filtro.processar(_leitura(i * 30.0, 0, i * 3, rumo: 0));
    }
    // ...e vira para leste.
    PosicaoCorrigida? ultima;
    for (var i = 1; i <= 4; i++) {
      ultima = filtro.processar(_leitura(150, i * 30.0, 15 + i * 3, rumo: 90));
      // Nunca passa mais que alguns metros do ponto da curva para o norte.
      expect(_norteM(ultima!.ponto, origem), lessThan(158));
    }
    expect(_lesteM(ultima!.ponto, origem), closeTo(120, 6));
    expect(_norteM(ultima.ponto, origem), closeTo(150, 4));
  });

  test('ignora leitura repetida ou com relogio para tras', () {
    final filtro = FiltroGps()..processar(_leitura(0, 0, 10));
    expect(filtro.processar(_leitura(20, 0, 10)), isNull);
    expect(filtro.processar(_leitura(20, 0, 5)), isNull);
  });
}
