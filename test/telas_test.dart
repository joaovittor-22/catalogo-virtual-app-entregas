import 'package:entregador_app/auth/auth_controller.dart';
import 'package:entregador_app/auth/login_page.dart';
import 'package:entregador_app/core/geo.dart';
import 'package:entregador_app/core/localizacao.dart';
import 'package:entregador_app/core/tema.dart';
import 'package:entregador_app/corrida/corrida.dart';
import 'package:entregador_app/corrida/corrida_controller.dart';
import 'package:entregador_app/corrida/corrida_page.dart';
import 'package:entregador_app/corrida/filtro_gps.dart';
import 'package:entregador_app/fila/fila_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apoio.dart';

const _destino = Ponto(-16.68, -49.25);
final _inicio = DateTime.utc(2026, 10, 12, 12);

Leitura _leituraEm(Ponto ponto, int minuto) => Leitura(
  ponto: ponto,
  precisaoM: 8,
  em: _inicio.add(Duration(minutes: minuto)),
  velocidadeMs: 5,
);

/// Deixa as respostas da API falsa chegarem e a tela se redesenhar.
Future<void> _assentar(WidgetTester tester) async {
  for (var i = 0; i < 14; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  group('Login', () {
    testWidgets('mostra o aviso da API e, com a credencial certa, entra', (tester) async {
      final api = ApiFalsa();
      final cofre = CofreFalso()
        // Já aceitou os termos nesta empresa: o checkbox não aparece (ver conta_test).
        ..empresaComAceite = '384801';
      final auth = AuthController(api.cliente, cofre);
      await auth.restaurar();
      api.responder = (_) => (401, {'message': 'Empresa, identificador ou senha invalidos.'});

      await tester.pumpWidget(
        MaterialApp(
          theme: temaDoApp(),
          home: LoginPage(auth: auth),
        ),
      );
      await tester.pump();

      // Sem preencher, nada e enviado.
      await tester.tap(find.text('Entrar'));
      await tester.pump();
      expect(find.text('Preencha este campo'), findsNWidgets(3));
      expect(api.chamadas, isEmpty);

      await tester.enterText(find.byKey(const Key('empresa')), ' 384801 ');
      await tester.enterText(find.byKey(const Key('identificador')), '(62) 98888-7777');
      await tester.enterText(find.byKey(const Key('senha')), 'errada');
      await tester.tap(find.text('Entrar'));
      await _assentar(tester);
      expect(find.text('Empresa, identificador ou senha invalidos.'), findsOneWidget);
      expect(auth.sessao, isNull);

      api.responder = (_) => (
        200,
        {
          'token': 'jwt-do-entregador',
          'tipo': 'Bearer',
          'expiraEmMs': 43200000,
          'entregador': {'id': 5, 'codigo': '141219', 'nome': 'Carlos Moto'},
          'loja': {'nome': 'Mercado Teste', 'slug': 'mercado-teste', 'codigo': '384801'},
        },
      );
      await tester.enterText(find.byKey(const Key('senha')), 'segredo123');
      await tester.tap(find.text('Entrar'));
      await _assentar(tester);

      final login = api.chamadas.last;
      expect(login.caminho, '/api/entregador/auth/login');
      expect(login.corpo, {
        'empresa': '384801',
        'identificador': '(62) 98888-7777',
        'senha': 'segredo123',
      });
      expect(auth.sessao?.entregadorNome, 'Carlos Moto');
      expect(api.cliente.token, 'jwt-do-entregador');
      // Guarda a sessao e o acesso, nunca a senha.
      expect(cofre.sessao?.token, 'jwt-do-entregador');
      expect(cofre.acesso, (empresa: '384801', identificador: '(62) 98888-7777'));
    });

    testWidgets('token recusado pela API derruba a sessao', (tester) async {
      final api = ApiFalsa();
      final cofre = CofreFalso();
      final auth = AuthController(api.cliente, cofre);
      api.responder = (_) => (
        200,
        {
          'token': 't',
          'expiraEmMs': 1000000,
          'entregador': {'nome': 'Carlos', 'codigo': '1'},
          'loja': {'nome': 'Loja'},
        },
      );
      await tester.runAsync(() => auth.entrar('1', 'a', 'b'));
      expect(auth.sessao, isNotNull);

      api.responder = (_) => (401, null);
      await tester.runAsync(() async {
        try {
          await api.cliente.get('/api/entregador/fila');
        } on Exception {
          // esperado
        }
      });
      expect(auth.sessao, isNull);
      expect(cofre.sessao, isNull);
    });
  });

  group('Fila', () {
    Map<String, dynamic> pedido(int id, String cliente, double lat, double lng) => {
      'pedidoId': id,
      'numero': 'PED$id',
      'clienteNome': cliente,
      'enderecoResumo': 'Rua $id, 100 · Centro',
      'latitude': lat,
      'longitude': lng,
      'total': 57.5,
      'formaPagamento': 'pix',
      'quantidadeItens': 3,
    };

    testWidgets('marca o mais proximo e avisa quando outro pegou o pedido', (tester) async {
      final api = ApiFalsa();
      final auth = AuthController(api.cliente, CofreFalso());
      await auth.restaurar();
      var pedidos = [
        pedido(1, 'Ana Longe', -16.70, -49.28),
        pedido(2, 'Bia Perto', -16.681, -49.251),
      ];
      api.responder = (c) {
        if (c.caminho.endsWith('/iniciar-rota')) {
          pedidos = [pedidos[0]];
          return (
            409,
            {
              'message': 'Este pedido ja foi pego por outro entregador.',
              'codigo': 'PEDIDO_JA_PEGO',
            },
          );
        }
        return (200, {'corridaAtivaId': null, 'loja': null, 'pedidos': pedidos});
      };

      await tester.pumpWidget(
        MaterialApp(
          theme: temaDoApp(),
          home: FilaPage(
            auth: auth,
            api: api.cliente,
            localizacao: LocalizacaoFalsa(posicao: _destino),
            // OSRM fora do ar: vale a linha reta.
            rotas: rotasFalsas(const [], fora: true),
          ),
        ),
      );
      await _assentar(tester);

      expect(find.text('Ana Longe'), findsOneWidget);
      expect(find.text('Rua 2, 100 · Centro'), findsOneWidget);
      expect(find.text('Iniciar rota'), findsNWidgets(2));
      // Um selo so, no cartao da Bia.
      expect(find.text('Mais próximo'), findsOneWidget);
      final cartaoDaBia = find.ancestor(of: find.text('Bia Perto'), matching: find.byType(Card));
      expect(find.descendant(of: cartaoDaBia, matching: find.text('Mais próximo')), findsOneWidget);
      // "~" indica linha reta.
      expect(find.descendant(of: cartaoDaBia, matching: find.text('~150 m')), findsOneWidget);

      await tester.tap(find.descendant(of: cartaoDaBia, matching: find.text('Iniciar rota')));
      await _assentar(tester);
      // RF-E03: estado da fila, em linguagem de gente, e o pedido sai da lista.
      expect(
        find.text('Outro entregador já pegou o pedido #PED2. Escolha outro da fila.'),
        findsOneWidget,
      );
      expect(find.text('Bia Perto'), findsNothing);
      expect(find.text('Ana Longe'), findsOneWidget);
      // Sobrou um pedido: nao ha o que comparar.
      expect(find.text('Mais próximo'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('RF-E03: pedido que saiu da fila ou corrida ja ativa nao viram erro tecnico', (
      tester,
    ) async {
      final api = ApiFalsa();
      final auth = AuthController(api.cliente, CofreFalso());
      await auth.restaurar();
      int? corridaAtivaId;
      var anaCancelada = false;
      api.responder = (c) {
        if (c.caminho.endsWith('/1/iniciar-rota')) {
          anaCancelada = true;
          return (404, {'message': 'Pedido nao encontrado.'});
        }
        if (c.caminho.endsWith('/2/iniciar-rota')) {
          corridaAtivaId = 3;
          return (
            409,
            {'message': 'Voce ja tem uma entrega em andamento.', 'codigo': 'CORRIDA_ATIVA'},
          );
        }
        if (c.caminho.endsWith('/corrida')) return (200, corridaJson());
        return (
          200,
          {
            'corridaAtivaId': corridaAtivaId,
            'loja': null,
            'pedidos': [
              if (!anaCancelada) pedido(1, 'Ana Cancelada', -16.70, -49.28),
              pedido(2, 'Bia', -16.681, -49.251),
            ],
          },
        );
      };

      await tester.pumpWidget(
        MaterialApp(
          theme: temaDoApp(),
          home: FilaPage(
            auth: auth,
            api: api.cliente,
            localizacao: LocalizacaoFalsa(permissao: Permissao.bloqueada),
            rotas: rotasFalsas(const [], fora: true),
          ),
        ),
      );
      await _assentar(tester);

      // A loja cancelou o pedido da Ana: sai da lista, com o aviso.
      final cartaoDaAna = find.ancestor(
        of: find.text('Ana Cancelada'),
        matching: find.byType(Card),
      );
      await tester.tap(find.descendant(of: cartaoDaAna, matching: find.text('Iniciar rota')));
      await _assentar(tester);
      expect(
        find.text('O pedido #PED1 não está mais disponível. Escolha outro da fila.'),
        findsOneWidget,
      );
      expect(find.text('Ana Cancelada'), findsNothing);

      // Ja ha corrida em andamento (outro aparelho): avisa e abre a corrida, sem
      // tirar a Bia da fila por engano.
      await tester.tap(find.text('Iniciar rota'));
      await _assentar(tester);
      await _assentar(tester);
      expect(find.text('Entrega #K7M2P9'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('sem localizacao mede a partir da loja e oferece ativar', (tester) async {
      final api = ApiFalsa();
      final auth = AuthController(api.cliente, CofreFalso());
      await auth.restaurar();
      api.responder = (_) => (
        200,
        {
          'corridaAtivaId': null,
          'loja': {'latitude': -16.68, 'longitude': -49.25},
          'pedidos': [pedido(1, 'Ana', -16.70, -49.28), pedido(2, 'Bia', -16.681, -49.251)],
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: temaDoApp(),
          home: FilaPage(
            auth: auth,
            api: api.cliente,
            localizacao: LocalizacaoFalsa(permissao: Permissao.aPedir),
            rotas: rotasFalsas(const [], fora: true),
          ),
        ),
      );
      await _assentar(tester);

      expect(find.textContaining('medidas a partir da loja'), findsOneWidget);
      expect(find.text('Ativar'), findsOneWidget);
      expect(find.text('Mais próximo'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Corrida', () {
    late ApiFalsa api;
    late LocalizacaoFalsa localizacao;
    late CorridaController controller;
    String? mensagemAoSair;

    Future<void> abrir(WidgetTester tester) async {
      controller = CorridaController(
        api: api.cliente,
        localizacao: localizacao,
        rotas: rotasFalsas(const [], fora: true),
        corrida: Corrida.fromJson(corridaJson()),
      );
      mensagemAoSair = null;
      await tester.pumpWidget(
        MaterialApp(
          theme: temaDoApp(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  mensagemAoSair = await Navigator.of(context).push<String>(
                    MaterialPageRoute(builder: (_) => CorridaPage(controller: controller)),
                  );
                },
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await _assentar(tester);
    }

    setUp(() {
      api = ApiFalsa()
        ..responder = (c) {
          if (c.caminho.endsWith('/concluir')) return (200, corridaJson(status: 'entregue'));
          if (c.caminho.endsWith('/devolver')) return (200, corridaJson(status: 'devolvida'));
          if (c.caminho.endsWith('/posicoes')) return (200, {'gravadas': 1, 'rastreioAtivo': true});
          return (200, corridaJson());
        };
      localizacao = LocalizacaoFalsa();
    });

    testWidgets('mostra o pedido e so libera "Concluir entrega" perto do destino', (tester) async {
      await abrir(tester);

      expect(find.text('Entrega #K7M2P9'), findsOneWidget);
      expect(find.text('Joao Cliente'), findsOneWidget);
      expect(find.textContaining('Avenida T-63, 1000, Setor Bueno'), findsOneWidget);
      expect(find.text('Referência: portao azul'), findsOneWidget);
      expect(find.text(r'R$ 57,50 · Dinheiro'), findsOneWidget);
      expect(find.textContaining(r'R$ 42,50 de troco'), findsOneWidget);
      expect(find.text('2× Arroz 5kg'), findsOneWidget);
      expect(find.text('Ligar'), findsOneWidget);
      expect(find.text('Aguardando sua localização…'), findsOneWidget);
      expect(find.byKey(const Key('concluir')), findsNothing);

      // A ~2,2 km do destino.
      localizacao.leituras.add(_leituraEm(const Ponto(-16.70, -49.25), 0));
      await _assentar(tester);
      expect(find.text('Faltam 2,2 km até o endereço'), findsOneWidget);
      expect(find.byKey(const Key('concluir')), findsNothing);
      expect(find.byKey(const Key('concluir-longe')), findsOneWidget);

      // Chegou: ~55 m do destino.
      localizacao.leituras.add(_leituraEm(const Ponto(-16.6805, -49.25), 10));
      await _assentar(tester);
      expect(find.text('Você chegou ao endereço'), findsOneWidget);
      expect(find.byKey(const Key('concluir-longe')), findsNothing);

      await tester.tap(find.byKey(const Key('concluir')));
      await _assentar(tester);

      // RF-E08: confirma, com observacao opcional para a loja (toque rapido ou texto).
      expect(find.text('Concluir a entrega #K7M2P9?'), findsOneWidget);
      await tester.tap(find.text('Entregue na portaria'));
      await tester.pump();
      expect(find.widgetWithText(TextField, 'Entregue na portaria'), findsOneWidget);
      await tester.tap(find.text('Concluir'));
      await _assentar(tester);

      // Enviou o que faltava, concluiu e voltou para a fila.
      expect(api.para('/posicoes'), isNotEmpty);
      final conclusao = api.para('/concluir').single;
      expect(conclusao.corpo['latitude'], closeTo(-16.6805, 0.001));
      expect(conclusao.corpo['observacao'], 'Entregue na portaria');
      expect(mensagemAoSair, 'Entrega concluída. Escolha a próxima.');
      expect(find.text('abrir'), findsOneWidget);
      // O rastreio parou: leitura nova nao gera envio.
      final enviosAntes = api.para('/posicoes').length;
      localizacao.leituras.add(_leituraEm(const Ponto(-16.6801, -49.25), 20));
      await controller.rastreador.enviar();
      expect(api.para('/posicoes'), hasLength(enviosAntes));
      controller.dispose();
    });

    testWidgets('RF-E11: negar a localizacao nao impede entregar', (tester) async {
      localizacao
        ..permissao = Permissao.aPedir
        ..respostaAoPedir = Permissao.aPedir;
      await abrir(tester);

      // Explica antes de o sistema perguntar.
      expect(find.text('Compartilhar sua localização?'), findsOneWidget);
      await tester.tap(find.text('Agora não'));
      await _assentar(tester);
      expect(localizacao.pedidos, 0);
      expect(find.textContaining('Localização desligada'), findsOneWidget);

      // Longe (ou sem GPS) pede confirmacao, mas deixa concluir.
      await tester.tap(find.byKey(const Key('concluir-longe')));
      await _assentar(tester);
      expect(find.text('Concluir mesmo assim?'), findsOneWidget);
      expect(api.para('/concluir'), isEmpty);
      await tester.tap(find.text('Já entreguei'));
      await _assentar(tester);

      expect(api.para('/concluir'), hasLength(1));
      expect(api.para('/posicoes'), isEmpty);
      expect(mensagemAoSair, 'Entrega concluída. Escolha a próxima.');
      controller.dispose();
    });

    testWidgets('RF-E09: devolver exige o motivo', (tester) async {
      await abrir(tester);
      // O botao fica no fim da lista, fora da tela ate rolar.
      await tester.scrollUntilVisible(
        find.text('Não consegui entregar'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _assentar(tester);
      await tester.tap(find.text('Não consegui entregar'));
      await _assentar(tester);

      // Sem motivo o botao fica apagado e avisa que e obrigatorio.
      FilledButton devolver() =>
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Devolver pedido'));
      expect(devolver().onPressed, isNull);
      expect(find.textContaining('Obrigatório. A loja vê este motivo'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('motivo')), '   ');
      await tester.pump();
      expect(devolver().onPressed, isNull);
      expect(api.para('/devolver'), isEmpty);

      // Um toque preenche; o texto continua editavel.
      await tester.tap(find.text('Cliente ausente'));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('motivo')), 'Cliente ausente, interfone mudo');
      await tester.pump();
      await tester.tap(find.text('Devolver pedido'));
      await _assentar(tester);
      final corpo = api.para('/devolver').single.corpo as Map<String, dynamic>;
      expect(corpo['motivo'], 'Cliente ausente, interfone mudo');
      // RF-E12: a hora em que aconteceu vai junto, para valer mesmo se chegar depois.
      expect(DateTime.parse(corpo['ocorridaEm'] as String).isUtc, isTrue);
      expect(mensagemAoSair, 'Pedido devolvido à loja.');
      controller.dispose();
    });

    testWidgets('RF-E12: sem rede ao concluir, guarda a conclusao e libera o entregador', (
      tester,
    ) async {
      api.responder = (c) => c.caminho.endsWith('/concluir') ? (503, null) : (200, corridaJson());
      localizacao.permissao = Permissao.bloqueada;
      await abrir(tester);

      await tester.tap(find.byKey(const Key('concluir-longe')));
      await _assentar(tester);
      await tester.tap(find.text('Já entreguei'));
      await _assentar(tester);

      expect(
        mensagemAoSair,
        'Entrega concluída sem internet. Vamos avisar a loja assim que a conexão voltar.',
      );
      expect(controller.guardadaParaEnviar, isTrue);
      expect(controller.rastreador.ativo, isFalse);
      expect(controller.pendencias.acoes.single.tipo.name, 'concluir');
      controller.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('recusa da API ao concluir mantem a corrida aberta, com o motivo', (tester) async {
      api.responder = (c) => c.caminho.endsWith('/concluir')
          ? (409, {'message': 'Esta entrega nao esta mais em andamento.'})
          : (200, corridaJson());
      localizacao.permissao = Permissao.bloqueada;
      await abrir(tester);

      await tester.tap(find.byKey(const Key('concluir-longe')));
      await _assentar(tester);
      await tester.tap(find.text('Já entreguei'));
      await _assentar(tester);

      expect(find.text('Esta entrega nao esta mais em andamento.'), findsOneWidget);
      expect(mensagemAoSair, isNull);
      expect(controller.pendencias.vazia, isTrue);
      controller.dispose();
      await tester.pumpWidget(const SizedBox());
    });
  });
}
