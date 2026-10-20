import 'dart:io';
import 'dart:math';

import 'package:entregador_app/core/armazem.dart';
import 'package:entregador_app/core/espera.dart';
import 'package:entregador_app/corrida/pendencias.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apoio.dart';

AcaoPendente _concluir({int entregaId = 3}) => AcaoPendente(
  tipo: TipoAcao.concluir,
  entregaId: entregaId,
  numero: 'K7M2P9',
  corpo: {'ocorridaEm': '2026-10-20T12:00:00.000Z'},
);

void main() {
  group('Espera', () {
    test('dobra a cada falha, ate o teto, com metade sorteada', () {
      final espera = Espera(
        base: const Duration(seconds: 3),
        maximo: const Duration(seconds: 30),
        sorteio: Random(1),
      );
      final tetos = [3, 6, 12, 24, 30, 30];
      for (final teto in tetos) {
        final ms = espera.depoisDeFalhar().inMilliseconds;
        expect(ms, inInclusiveRange(teto * 500, teto * 1000));
      }
      espera.zerar();
      expect(espera.depoisDeFalhar().inMilliseconds, inInclusiveRange(1500, 3000));
    });
  });

  group('Pendencias', () {
    late ApiFalsa api;
    late ArmazemEmMemoria armazem;
    late Pendencias pendencias;

    Pendencias criar() => Pendencias(api: api.cliente, dados: DadosLocais(armazem, 'loja/ent'));

    setUp(() {
      api = ApiFalsa()..responder = (_) => (200, corridaJson(status: 'entregue'));
      armazem = ArmazemEmMemoria();
      pendencias = criar();
    });

    tearDown(() => pendencias.dispose());

    test('com rede, envia na hora e nao guarda nada', () async {
      final resultado = await pendencias.executar(_concluir());

      expect(resultado.guardada, isFalse);
      expect((resultado.resposta as Map)['status'], 'entregue');
      expect(api.para('/entregas/3/concluir').single.corpo['ocorridaEm'], isNotNull);
      expect(pendencias.vazia, isTrue);
      expect(armazem.dados, isEmpty);
    });

    test('RF-E12: sem rede guarda no aparelho, sobrevive ao app fechado e sai na ordem', () async {
      api.semRede = true;
      final foto = File('${Directory.systemTemp.createTempSync().path}/comprovante.jpg')
        ..writeAsBytesSync([1, 2, 3]);

      expect((await pendencias.executar(_concluir())).guardada, isTrue);
      // Ja sem rede: guarda direto, sem esperar o tempo limite de outra chamada.
      final antes = api.chamadas.length;
      await pendencias.executar(
        AcaoPendente(
          tipo: TipoAcao.enviarComprovante,
          entregaId: 3,
          numero: 'K7M2P9',
          arquivo: foto.path,
          nomeDoArquivo: 'comprovante.jpg',
        ),
      );
      expect(api.chamadas.length, antes);
      expect(pendencias.encerradaAqui(3), isTrue);

      // O app foi fechado: outra instancia le o que ficou guardado.
      pendencias.dispose();
      api.semRede = false;
      api.chamadas.clear();
      pendencias = criar();
      await pendencias.carregar();
      await pumpEventQueue();

      expect(api.chamadas.map((c) => c.caminho), [
        '/api/entregador/entregas/3/concluir',
        '/api/entregador/entregas/3/comprovante',
      ]);
      expect(pendencias.vazia, isTrue);
      expect(armazem.dados, isEmpty);
    });

    test('a rede voltando (outra chamada com resposta) dispara o reenvio', () async {
      api.semRede = true;
      await pendencias.executar(_concluir());
      expect(api.para('/concluir'), hasLength(1));

      api.semRede = false;
      await api.cliente.get('/api/entregador/fila');
      await pumpEventQueue();

      expect(api.para('/concluir'), hasLength(2));
      expect(pendencias.vazia, isTrue);
    });

    test('recusa definitiva sai da lista e vira aviso para o entregador', () async {
      api.semRede = true;
      await pendencias.executar(_concluir());
      api
        ..semRede = false
        ..responder = (_) => (409, {'message': 'Esta entrega nao esta mais em andamento.'});

      expect(await pendencias.enviar(), isTrue);
      expect(pendencias.tirarAvisos(), [
        'A conclusão da entrega #K7M2P9 não foi aceita pela loja: '
            'Esta entrega nao esta mais em andamento.',
      ]);
      expect(pendencias.tirarAvisos(), isEmpty);
    });

    test('devolucao repetida (so a resposta se perdeu) conta como enviada', () async {
      api.semRede = true;
      await pendencias.executar(
        AcaoPendente(
          tipo: TipoAcao.devolver,
          entregaId: 3,
          numero: 'K7M2P9',
          corpo: {'motivo': 'cliente ausente'},
        ),
      );
      api
        ..semRede = false
        ..responder = (c) => c.metodo == 'GET'
            ? (200, corridaJson(status: 'devolvida'))
            : (409, {'message': 'Esta entrega nao esta mais em andamento.'});

      expect(await pendencias.enviar(), isTrue);
      expect(pendencias.tirarAvisos(), isEmpty);
    });

    test('sessao expirada mantem guardado para depois do novo login', () async {
      api.semRede = true;
      await pendencias.executar(_concluir());
      api
        ..semRede = false
        ..responder = (_) => (401, null);

      expect(await pendencias.enviar(), isFalse);
      expect(pendencias.acoes, hasLength(1));
      expect(armazem.dados.keys, ['pendencias:loja/ent']);
    });

    testWidgets('API fora do ar: tenta de novo sozinho, cada vez mais espacado', (tester) async {
      // testWidgets roda num relogio falso: os temporizadores andam sem esperar de verdade.
      api.responder = (_) => (503, null);
      await pendencias.executar(_concluir());
      expect(api.para('/concluir'), hasLength(1));

      // Primeira espera: entre 1,5 e 3 s.
      await tester.pump(const Duration(seconds: 3));
      expect(api.para('/concluir'), hasLength(2));
      // Segunda: entre 3 e 6 s depois da anterior.
      await tester.pump(const Duration(milliseconds: 1400));
      expect(api.para('/concluir'), hasLength(2));
      await tester.pump(const Duration(milliseconds: 4600));
      expect(api.para('/concluir'), hasLength(3));

      api.responder = (_) => (200, corridaJson(status: 'entregue'));
      await tester.pump(const Duration(seconds: 12));
      expect(pendencias.vazia, isTrue);
      final tentativas = api.para('/concluir').length;
      await tester.pump(const Duration(minutes: 5));
      expect(api.para('/concluir'), hasLength(tentativas));
    });
  });
}
