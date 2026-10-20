import 'package:entregador_app/core/geo.dart';
import 'package:entregador_app/core/localizacao.dart';
import 'package:entregador_app/corrida/corrida.dart';
import 'package:entregador_app/corrida/corrida_controller.dart';
import 'package:entregador_app/corrida/filtro_gps.dart';
import 'package:entregador_app/corrida/rastreador.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apoio.dart';

// Rua para leste e depois para o norte, ate o destino.
const _rota = [Ponto(-16.69, -49.26), Ponto(-16.69, -49.25), Ponto(-16.68, -49.25)];
const _destino = Ponto(-16.68, -49.25);
final _inicio = DateTime.utc(2026, 10, 12, 12);

/// Leitura a [lesteM] metros do inicio da rua, [foraM] metros ao sul dela.
Leitura _naRua(double lesteM, int segundo, {double foraM = 0}) => Leitura(
  ponto: Ponto(-16.69 - foraM / 111320, -49.26 + lesteM / 106640),
  precisaoM: 8,
  em: _inicio.add(Duration(seconds: segundo)),
  velocidadeMs: 10,
  direcaoGraus: 90,
);

Future<void> _assentar() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late ApiFalsa api;
  late LocalizacaoFalsa localizacao;

  Rastreador criar({Ponto? destino = _destino, bool osrmFora = false}) => Rastreador(
    api: api.cliente,
    localizacao: localizacao,
    rotas: rotasFalsas(_rota, fora: osrmFora),
    entregaId: 3,
    destino: destino,
  );

  setUp(() {
    api = ApiFalsa()..responder = (_) => (200, {'gravadas': 1, 'rastreioAtivo': true});
    localizacao = LocalizacaoFalsa();
  });

  test('RF-E11: sem permissao nao rastreia e nao envia nada', () async {
    localizacao.permissao = Permissao.aPedir;
    final rastreador = criar();
    await rastreador.iniciar();

    expect(rastreador.ativo, isFalse);
    expect(rastreador.estado.value.situacao, SituacaoRastreio.semLocalizacao);
    // Rastrear nunca pede permissao por conta propria.
    expect(localizacao.pedidos, 0);
    await rastreador.enviar();
    expect(api.chamadas, isEmpty);
  });

  test('traca a rota na primeira leitura e a envia para o cliente ver', () async {
    final rastreador = criar();
    await rastreador.iniciar();
    rastreador.aoLer(_naRua(0, 0));
    await _assentar();

    expect(rastreador.estado.value.rota?.distanciaM, 2180);
    final rota = api.para('/rota').single;
    expect(rota.metodo, 'PUT');
    expect(rota.caminho, '/api/entregador/entregas/3/rota');
    // Pares [lng, lat].
    expect(rota.corpo['pontos'], hasLength(3));
    expect(rota.corpo['pontos'][0], [-49.26, -16.69]);
    expect(rota.corpo['distanciaM'], 2180);
    await rastreador.parar();
  });

  test('perto da rota, a posicao e puxada para cima da rua', () async {
    final rastreador = criar();
    await rastreador.iniciar();
    rastreador.aoLer(_naRua(0, 0));
    await _assentar();

    // 20 m para dentro do quarteirao: "em cima da casa".
    rastreador.aoLer(_naRua(30, 3, foraM: 20));
    final posicao = rastreador.estado.value.posicao!;
    expect(posicao.ponto.latitude, closeTo(-16.69, 0.000001));
    expect(encaixarNaRota(posicao.ponto, _rota)!.distanciaM, lessThan(0.5));
    await rastreador.parar();
  });

  test('fora da rota de verdade, a posicao real e mantida', () async {
    final rastreador = criar();
    await rastreador.iniciar();
    rastreador.aoLer(_naRua(0, 0));
    await _assentar();

    // Seguiu por uma rua paralela, ~110 m ao sul.
    for (var i = 1; i <= 4; i++) {
      rastreador.aoLer(_naRua(i * 30.0, i * 3, foraM: 110));
    }
    final posicao = rastreador.estado.value.posicao!;
    expect(encaixarNaRota(posicao.ponto, _rota)!.distanciaM, greaterThan(60));
    await rastreador.parar();
  });

  test('envia em lote, com o formato que a API espera', () async {
    final rastreador = criar();
    await rastreador.iniciar();
    for (var i = 0; i < 4; i++) {
      rastreador.aoLer(_naRua(i * 30.0, i * 3));
    }
    await _assentar();
    await rastreador.enviar();

    final lote = api.para('/posicoes').single;
    expect(lote.metodo, 'POST');
    expect(lote.corpo['posicoes'], hasLength(4));
    final primeira = lote.corpo['posicoes'][0] as Map<String, dynamic>;
    expect(primeira.keys, containsAll(['latitude', 'longitude', 'precisaoM', 'registradaEm']));
    expect(primeira['registradaEm'], '2026-10-12T12:00:00.000Z');
    expect(primeira['velocidadeMs'], 10);
    expect(rastreador.estado.value.pendentes, 0);

    // Fila vazia: nao ha o que enviar.
    await rastreador.enviar();
    expect(api.para('/posicoes'), hasLength(1));
    await rastreador.parar();
  });

  test('RF-E12: sem rede as posicoes ficam guardadas e saem depois', () async {
    api.responder = (c) => c.caminho.endsWith('/posicoes') ? (503, null) : (200, null);
    final rastreador = criar(osrmFora: true);
    await rastreador.iniciar();
    rastreador
      ..aoLer(_naRua(0, 0))
      ..aoLer(_naRua(30, 3));
    await rastreador.enviar();
    expect(rastreador.estado.value.pendentes, 2);

    api.responder = (_) => (200, {'gravadas': 3, 'rastreioAtivo': true});
    rastreador.aoLer(_naRua(60, 6));
    await rastreador.enviar();
    expect(api.para('/posicoes').last.corpo['posicoes'], hasLength(3));
    expect(rastreador.estado.value.pendentes, 0);
    await rastreador.parar();
  });

  test('quando a API avisa que a corrida acabou, para de rastrear', () async {
    api.responder = (_) => (200, {'gravadas': 0, 'rastreioAtivo': false});
    final rastreador = criar(osrmFora: true);
    var avisou = false;
    rastreador.aoEncerrarPelaLoja = () => avisou = true;
    await rastreador.iniciar();
    rastreador.aoLer(_naRua(0, 0));
    await rastreador.enviar();

    expect(avisou, isTrue);
    expect(rastreador.ativo, isFalse);
    // Depois de parar, leitura nova nao entra na fila nem sai do aparelho.
    rastreador.aoLer(_naRua(30, 3));
    await rastreador.enviar();
    expect(api.para('/posicoes'), hasLength(1));
    expect(rastreador.estado.value.pendentes, 0);
  });

  test('sem destino localizado, rastreia sem pedir rota', () async {
    final rastreador = criar(destino: null);
    await rastreador.iniciar();
    rastreador.aoLer(_naRua(0, 0));
    await _assentar();
    await rastreador.enviar();

    expect(api.para('/rota'), isEmpty);
    expect(api.para('/posicoes'), hasLength(1));
    await rastreador.parar();
  });

  group('RNF-E05: intervalo adaptativo', () {
    test('quanto mais perto do cliente, mais vezes o lote sai', () {
      expect(Rastreador.intervaloPara(400), Rastreador.intervaloPerto);
      expect(Rastreador.intervaloPara(1000), Rastreador.intervaloPerto);
      expect(Rastreador.intervaloPara(2500), Rastreador.intervaloNoCaminho);
      expect(Rastreador.intervaloPara(8000), Rastreador.intervaloLonge);
      // Sem posicao ou sem destino: o meio-termo.
      expect(Rastreador.intervaloPara(null), Rastreador.intervaloNoCaminho);
    });

    /// Leitura a ~5 km do destino, andando para leste a 10 m/s.
    Leitura longe(int segundo) => Leitura(
      ponto: Ponto(-16.72, -49.29 + segundo * 10 / 106640),
      precisaoM: 8,
      em: _inicio.add(Duration(seconds: segundo)),
      velocidadeMs: 10,
      direcaoGraus: 90,
    );

    /// Leitura a ~200 m do destino.
    Leitura perto(int segundo) => Leitura(
      ponto: Ponto(-16.6818, -49.25 + segundo * 10 / 106640),
      precisaoM: 8,
      em: _inicio.add(Duration(seconds: segundo)),
      velocidadeMs: 10,
      direcaoGraus: 90,
    );

    Future<int> lotesEm60s(
      WidgetTester tester,
      Rastreador rastreador,
      Leitura Function(int) ler,
    ) async {
      final antes = api.para('/posicoes').length;
      for (var s = 0; s < 60; s++) {
        rastreador.aoLer(ler(s));
        await tester.pump(const Duration(seconds: 1));
      }
      return api.para('/posicoes').length - antes;
    }

    testWidgets('longe junta as leituras em lotes de 10 s; perto envia a cada 3 s', (tester) async {
      final longeR = criar(osrmFora: true);
      await longeR.iniciar();
      final lotesLonge = await lotesEm60s(tester, longeR, longe);
      await longeR.parar();

      final pertoR = criar(osrmFora: true);
      await pertoR.iniciar();
      final lotesPerto = await lotesEm60s(tester, pertoR, perto);
      await pertoR.parar();

      // Antes era um lote a cada 3 s em qualquer lugar: 20 por minuto.
      expect(lotesLonge, inInclusiveRange(5, 6));
      expect(lotesPerto, inInclusiveRange(18, 20));
      // Nenhuma leitura se perdeu: so foram agrupadas.
      final enviadas = api
          .para('/posicoes')
          .take(lotesLonge)
          .fold<int>(0, (n, c) => n + (c.corpo['posicoes'] as List).length);
      expect(enviadas, inInclusiveRange(55, 60));
    });

    testWidgets('parado (sem leitura nova), nada sai do aparelho', (tester) async {
      final rastreador = criar(osrmFora: true);
      await rastreador.iniciar();
      rastreador.aoLer(perto(0));
      await tester.pump(const Duration(seconds: 6));
      final depoisDaPrimeira = api.para('/posicoes').length;
      await tester.pump(const Duration(minutes: 2));
      expect(api.para('/posicoes'), hasLength(depoisDaPrimeira));
      await rastreador.parar();
    });

    testWidgets('sem rede espaca as tentativas e, com a rede de volta, envia na hora', (
      tester,
    ) async {
      final rastreador = criar(osrmFora: true);
      await rastreador.iniciar();
      api.semRede = true;
      for (var s = 0; s < 60; s++) {
        rastreador.aoLer(perto(s));
        await tester.pump(const Duration(seconds: 1));
      }
      // Antes, 20 tentativas por minuto sem rede; agora a espera dobra ate 30 s.
      final tentativas = api.para('/posicoes').length;
      expect(tentativas, inInclusiveRange(4, 7));
      expect(rastreador.estado.value.semConexao, isTrue);
      expect(rastreador.estado.value.pendentes, 60);

      // Outra chamada do app teve resposta: a rede voltou.
      api.semRede = false;
      await api.cliente.get('/api/entregador/corrida');
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(api.para('/posicoes'), hasLength(tentativas + 1));
      expect(rastreador.estado.value.pendentes, 0);
      expect(rastreador.ultimoContatoEm, isNotNull);
      await rastreador.parar();
    });

    testWidgets('a conferencia da corrida so pergunta a API quando nenhum lote chegou', (
      tester,
    ) async {
      CorridaController criarCorrida() => CorridaController(
        api: api.cliente,
        localizacao: localizacao,
        rotas: rotasFalsas(const [], fora: true),
        corrida: Corrida.fromJson(corridaJson()),
      );
      api.responder = (c) =>
          c.metodo == 'GET' ? (200, corridaJson()) : (200, {'gravadas': 1, 'rastreioAtivo': true});
      int conferencias() => api.chamadas
          .where((c) => c.metodo == 'GET' && c.caminho == '/api/entregador/entregas/3')
          .length;

      // Andando, cada lote ja responde se a corrida segue: nada de pergunta extra.
      final andando = criarCorrida();
      await andando.comecar(explicar: () async => false);
      for (var s = 0; s < 60; s++) {
        andando.rastreador.aoLer(perto(s));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(conferencias(), 0);
      andando.dispose();

      // Sem localizacao nao sai lote: a conferencia de 25 s segue valendo.
      localizacao.permissao = Permissao.bloqueada;
      final semGps = criarCorrida();
      await semGps.comecar(explicar: () async => false);
      await tester.pump(const Duration(seconds: 60));
      expect(conferencias(), 2);
      semGps.dispose();
    });
  });
}
