import 'dart:convert';

import 'package:entregador_app/auth/auth_controller.dart';
import 'package:entregador_app/auth/sessao.dart';
import 'package:entregador_app/core/armazem.dart';
import 'package:entregador_app/core/localizacao.dart';
import 'package:entregador_app/core/tema.dart';
import 'package:entregador_app/fila/fila_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apoio.dart';

/// RF-E12 / T4.7: fila e corrida guardadas, acoes reenviadas quando a rede volta.
void main() {
  late ApiFalsa api;
  late ArmazemEmMemoria armazem;
  late AuthController auth;
  late List<Map<String, dynamic>> pedidos;
  int? corridaAtivaId;

  Map<String, dynamic> pedido(int id, String cliente) => {
    'pedidoId': id,
    'numero': 'PED$id',
    'clienteNome': cliente,
    'enderecoResumo': 'Rua $id, 100 · Centro',
    'latitude': -16.70,
    'longitude': -49.28,
    'total': 57.5,
    'formaPagamento': 'pix',
    'quantidadeItens': 3,
  };

  setUp(() async {
    pedidos = [pedido(1, 'Ana'), pedido(2, 'Bia')];
    corridaAtivaId = null;
    api = ApiFalsa()
      ..responder = (c) {
        if (c.caminho.endsWith('/fila')) {
          return (200, {'corridaAtivaId': corridaAtivaId, 'loja': null, 'pedidos': pedidos});
        }
        if (c.caminho.endsWith('/corrida')) return (200, corridaJson());
        if (c.caminho.endsWith('/iniciar-rota')) {
          corridaAtivaId = 3;
          return (200, corridaJson());
        }
        if (c.caminho.endsWith('/concluir')) {
          corridaAtivaId = null;
          return (200, corridaJson(status: 'entregue'));
        }
        return (200, {'gravadas': 1, 'rastreioAtivo': true});
      };
    armazem = ArmazemEmMemoria();
    final cofre = CofreFalso()
      ..sessao = Sessao(
        token: 't',
        entregadorNome: 'Carlos',
        entregadorCodigo: 'E1',
        lojaNome: 'Mercado',
        lojaCodigo: '384801',
        expiraEm: DateTime.now().add(const Duration(hours: 8)),
      );
    auth = AuthController(api.cliente, cofre, armazem: armazem);
    await auth.restaurar();
  });

  Future<void> abrirFila(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: temaDoApp(),
        home: FilaPage(
          auth: auth,
          api: api.cliente,
          // Sem pedido de permissao no meio do teste.
          localizacao: LocalizacaoFalsa(permissao: Permissao.bloqueada),
          rotas: rotasFalsas(const [], fora: true),
        ),
      ),
    );
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> fechar(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('sem rede, abre com a ultima fila guardada e diz de quando ela e', (tester) async {
    await abrirFila(tester);
    expect(find.text('Ana'), findsOneWidget);
    await fechar(tester);
    // Guardada no cofre, junto da loja e do entregador.
    expect(armazem.dados.keys, contains('fila:384801/E1'));

    api.semRede = true;
    await abrirFila(tester);

    expect(find.text('Ana'), findsOneWidget);
    expect(find.text('Bia'), findsOneWidget);
    expect(
      find.textContaining('Sem conexão com a internet. Mostrando a lista das'),
      findsOneWidget,
    );
    await fechar(tester);
  });

  testWidgets('corrida em andamento abre sem rede, com endereco e itens guardados', (tester) async {
    corridaAtivaId = 3;
    await abrirFila(tester);
    expect(find.text('Entrega #K7M2P9'), findsOneWidget);
    await fechar(tester);

    api.semRede = true;
    await abrirFila(tester);

    expect(find.text('Entrega #K7M2P9'), findsOneWidget);
    expect(find.textContaining('Avenida T-63, 1000'), findsWidgets);
    await fechar(tester);
  });

  testWidgets('rota iniciada pela fila reabre sem rede, mesmo com a fila parada na corrida', (
    tester,
  ) async {
    await abrirFila(tester);
    await tester.tap(find.text('Iniciar rota').first);
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.text('Entrega #K7M2P9'), findsOneWidget);
    // A fila nao consultou a API depois de a rota comecar.
    expect(api.para('/fila').where((c) => c.metodo == 'GET'), hasLength(1));
    await fechar(tester);

    api.semRede = true;
    await abrirFila(tester);

    expect(find.text('Entrega #K7M2P9'), findsOneWidget);
    await tester.pageBack();
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    // O pedido pego nao aparece como livre na fila guardada.
    expect(find.text('Ana'), findsNothing);
    expect(find.text('Bia'), findsOneWidget);
    await fechar(tester);
  });

  testWidgets('concluir sem rede libera o entregador; outra rota so depois de enviar', (
    tester,
  ) async {
    corridaAtivaId = 3;
    await abrirFila(tester);
    api.semRede = true;

    await tester.tap(find.byKey(const Key('concluir-longe')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Já entreguei'));
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    // De volta a fila, com o aviso do que ficou por enviar.
    expect(find.text('Entrega #K7M2P9'), findsNothing);
    expect(
      find.text('Entrega concluída sem internet. Vamos avisar a loja assim que a conexão voltar.'),
      findsOneWidget,
    );
    expect(find.textContaining('Uma ação feita sem internet vai chegar à loja'), findsOneWidget);
    final concluir = jsonDecode(armazem.dados['pendencias:384801/E1']!)['dados'] as List;
    expect(concluir.single['tipo'], 'concluir');

    // Pegar outro pedido precisa da API saber que este acabou.
    await tester.tap(find.text('Iniciar rota').first);
    // O aviso anterior sai antes de o novo entrar.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.textContaining('A entrega #K7M2P9 ainda não chegou à loja'), findsOneWidget);
    expect(api.para('/iniciar-rota'), isEmpty);

    // A rede volta: a proxima atualizacao da fila leva a conclusao antes.
    api.semRede = false;
    await tester.pump(const Duration(seconds: 61));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    final enviada = api.para('/entregas/3/concluir').last.corpo as Map<String, dynamic>;
    expect(enviada['ocorridaEm'], isNotNull);
    expect(find.textContaining('Uma ação feita sem internet'), findsNothing);
    expect(find.text('Tudo o que você fez sem internet chegou à loja.'), findsOneWidget);
    expect(armazem.dados.keys, isNot(contains('pendencias:384801/E1')));
    await fechar(tester);
  });

  testWidgets('sair com acao por enviar pede confirmacao e apaga os dados do aparelho', (
    tester,
  ) async {
    armazem.dados['pendencias:384801/E1'] = jsonEncode({
      'em': DateTime.now().toIso8601String(),
      'dados': [
        {'tipo': 'concluir', 'entregaId': 3, 'numero': 'K7M2P9', 'corpo': <String, dynamic>{}},
      ],
    });
    api.semRede = true;
    await abrirFila(tester);

    await tester.tap(find.byTooltip('Sair'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Sair sem enviar?'), findsOneWidget);
    await tester.tap(find.text('Ficar'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(auth.sessao, isNotNull);

    await tester.tap(find.byTooltip('Sair'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Sair mesmo assim'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(auth.sessao, isNull);
    expect(armazem.dados.keys.where((k) => k.endsWith('384801/E1')), isEmpty);
    await fechar(tester);
  });
}
