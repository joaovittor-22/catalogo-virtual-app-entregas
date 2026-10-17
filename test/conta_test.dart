import 'package:entregador_app/app.dart';
import 'package:entregador_app/auth/auth_controller.dart';
import 'package:entregador_app/auth/login_page.dart';
import 'package:entregador_app/conta/conta_page.dart';
import 'package:entregador_app/conta/termos_page.dart';
import 'package:entregador_app/conta/texto_legal.dart';
import 'package:entregador_app/core/api_client.dart';
import 'package:entregador_app/core/tema.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apoio.dart';

const _textoDosTermos = '''
Estes Termos explicam os seus dados.

## 1. Seu cadastro
- **Só a empresa parceira cadastra você.**
- Cada empresa tem um cadastro separado.

## 2. Responsabilidade
A empresa é a **controladora**. Fale com [PREENCHER: e-mail do encarregado].
''';

Map<String, dynamic> _termos({int versao = 1}) => {
  'titulo': 'Termos de Uso do Entregador',
  'versao': versao,
  'publicadoEm': '2026-10-17T12:00:00Z',
  'conteudo': _textoDosTermos,
};

Map<String, dynamic> _login() => {
  'token': 'jwt',
  'expiraEmMs': 3600000,
  'entregador': {'nome': 'Carlos Moto', 'codigo': '141219'},
  'loja': {'nome': 'Mercado Teste'},
};

Future<void> _assentar(WidgetTester tester) async {
  for (var i = 0; i < 14; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  group('Texto dos termos', () {
    test('lê títulos, listas, negrito e o que falta preencher', () {
      final blocos = lerTextoLegal(_textoDosTermos);
      expect(blocos.map((b) => b.tipo), [
        TipoBloco.paragrafo,
        TipoBloco.titulo,
        TipoBloco.lista,
        TipoBloco.titulo,
        TipoBloco.paragrafo,
      ]);
      expect(blocos[2].linhas, hasLength(2));
      expect(blocos[2].linhas.first, [
        const TrechoLegal('Só a empresa parceira cadastra você.', negrito: true),
      ]);
      expect(lerTrechos('a **b** [PREENCHER: c]'), [
        const TrechoLegal('a '),
        const TrechoLegal('b', negrito: true),
        const TrechoLegal(' '),
        const TrechoLegal('[PREENCHER: c]', pendente: true),
      ]);
    });

    test('não interpreta HTML: fica como texto', () {
      final blocos = lerTextoLegal('<script>alert(1)</script>');
      expect(blocos.single.linhas.single.single.texto, '<script>alert(1)</script>');
    });
  });

  group('Aceite dos termos no login', () {
    Future<(AuthController, ApiFalsa, CofreFalso)> abrirLogin(
      WidgetTester tester, {
      String? empresaComAceite,
      (int, Object?) Function(Chamada)? login,
    }) async {
      final api = ApiFalsa();
      final cofre = CofreFalso()
        ..acesso = (empresa: '384801', identificador: 'carlos')
        ..empresaComAceite = empresaComAceite;
      final auth = AuthController(api.cliente, cofre);
      await auth.restaurar();
      api.responder = (c) {
        if (c.caminho == '/api/legal/entregador') return (200, _termos(versao: 3));
        if (c.caminho.endsWith('/auth/login')) {
          return login?.call(c) ?? (200, _login());
        }
        return (200, <String, dynamic>{});
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: temaDoApp(),
          home: LoginPage(auth: auth, api: api.cliente),
        ),
      );
      await _assentar(tester);
      return (auth, api, cofre);
    }

    Future<void> tocarEntrar(WidgetTester tester) async {
      await tester.ensureVisible(find.text('Entrar'));
      await tester.tap(find.text('Entrar'));
      await _assentar(tester);
    }

    testWidgets('primeiro acesso: sem marcar não entra; marcando, manda a versão e entra', (
      tester,
    ) async {
      final (auth, api, cofre) = await abrirLogin(tester);

      expect(find.byKey(const Key('aceite-termos')), findsOneWidget);
      expect(find.text('Li e aceito os '), findsOneWidget);
      await tester.enterText(find.byKey(const Key('senha')), 'segredo1');
      await tocarEntrar(tester);

      expect(find.text('Marque que leu e aceita os termos de uso para entrar.'), findsOneWidget);
      expect(api.chamadas, isEmpty);
      expect(auth.sessao, isNull);

      await tester.tap(find.byKey(const Key('marcar-aceite')));
      await tester.pump();
      expect(find.text('Marque que leu e aceita os termos de uso para entrar.'), findsNothing);
      await tocarEntrar(tester);

      final login = api.para('/auth/login').single;
      expect(login.corpo, {
        'empresa': '384801',
        'identificador': 'carlos',
        'senha': 'segredo1',
        'termosVersao': 3,
      });
      expect(auth.sessao, isNotNull);
      expect(cofre.empresaComAceite, '384801');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('depois do primeiro acesso o checkbox some; trocar a empresa traz de volta', (
      tester,
    ) async {
      final (auth, api, _) = await abrirLogin(tester, empresaComAceite: '384801');

      expect(find.byKey(const Key('aceite-termos')), findsNothing);
      expect(find.text('Termos de uso'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('empresa')), '999999');
      await tester.pump();
      expect(find.byKey(const Key('aceite-termos')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('empresa')), '384801');
      await tester.pump();
      expect(find.byKey(const Key('aceite-termos')), findsNothing);

      await tester.enterText(find.byKey(const Key('senha')), 'segredo1');
      await tocarEntrar(tester);
      // Sem checkbox, entra sem mandar versão: a API sabe que já aceitou.
      expect(api.para('/auth/login').single.corpo, isNot(contains('termosVersao')));
      expect(api.para('/api/legal'), isEmpty);
      expect(auth.sessao, isNotNull);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('termos novos: a API pede o aceite e o checkbox volta', (tester) async {
      var vezes = 0;
      final (auth, api, cofre) = await abrirLogin(
        tester,
        empresaComAceite: '384801',
        login: (c) => vezes++ == 0
            ? (
                422,
                {
                  'codigo': 'TERMOS_PENDENTES',
                  'message':
                      'Os termos de uso foram atualizados. Leia a nova versão e marque o aceite de novo.',
                },
              )
            : (200, _login()),
      );
      expect(find.byKey(const Key('aceite-termos')), findsNothing);

      await tester.enterText(find.byKey(const Key('senha')), 'segredo1');
      await tocarEntrar(tester);

      expect(find.textContaining('foram atualizados'), findsOneWidget);
      expect(find.byKey(const Key('aceite-termos')), findsOneWidget);
      expect(cofre.empresaComAceite, isNull);
      expect(auth.sessao, isNull);

      await tester.tap(find.byKey(const Key('marcar-aceite')));
      await tocarEntrar(tester);
      expect(api.para('/auth/login').last.corpo['termosVersao'], 3);
      expect(auth.sessao, isNotNull);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('o link abre os termos e volta para o login, sem perder o que foi marcado', (
      tester,
    ) async {
      await abrirLogin(tester);
      await tester.tap(find.byKey(const Key('marcar-aceite')));
      await tester.pump();

      await tester.ensureVisible(find.byKey(const Key('ler-termos')));
      await tester.tap(find.byKey(const Key('ler-termos')));
      await _assentar(tester);
      expect(find.byType(TermosPage), findsOneWidget);
      expect(find.textContaining('Só a empresa parceira cadastra você.'), findsOneWidget);
      // Só leitura: nada de aceitar ou recusar lá dentro.
      expect(find.text('Não aceito'), findsNothing);

      await tester.ensureVisible(find.byKey(const Key('voltar-dos-termos')));
      await tester.tap(find.byKey(const Key('voltar-dos-termos')));
      await _assentar(tester);
      expect(find.byType(LoginPage), findsOneWidget);
      final caixa = tester.widget<Checkbox>(find.byKey(const Key('marcar-aceite')));
      expect(caixa.value, isTrue);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('termos mudam com a sessão aberta: volta ao login com o aviso e o checkbox', (
      tester,
    ) async {
      final api = ApiFalsa();
      final cofre = CofreFalso()..empresaComAceite = '384801';
      final auth = AuthController(api.cliente, cofre);
      await auth.restaurar();
      api.responder = (c) => c.caminho.endsWith('/auth/login')
          ? (200, _login())
          : (200, {'corridaAtivaId': null, 'loja': null, 'pedidos': <Object>[]});
      await tester.runAsync(() => auth.entrar('384801', 'carlos', 'segredo1'));
      await tester.pumpWidget(
        EntregadorApp(
          auth: auth,
          api: api.cliente,
          localizacao: LocalizacaoFalsa(),
          rotas: rotasFalsas(const [], fora: true),
        ),
      );
      await _assentar(tester);
      expect(find.text('Entregas'), findsOneWidget);

      api.responder = (_) => (
        403,
        {
          'codigo': 'TERMOS_PENDENTES',
          'message': 'Os termos de uso foram atualizados. Entre de novo e marque o aceite.',
        },
      );
      await tester.runAsync(() async {
        try {
          await api.cliente.get('/api/entregador/fila');
        } on ApiException {
          // esperado
        }
      });
      await _assentar(tester);

      expect(auth.sessao, isNull);
      expect(cofre.empresaComAceite, isNull);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.textContaining('Os termos de uso foram atualizados'), findsOneWidget);
      expect(find.byKey(const Key('aceite-termos')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Excluir a conta', () {
    Future<(AuthController, ApiFalsa)> abrirConta(
      WidgetTester tester,
      (int, Object?) Function(Chamada) resto,
    ) async {
      final api = ApiFalsa();
      final auth = AuthController(api.cliente, CofreFalso());
      await auth.restaurar();
      api.responder = (c) => c.caminho.endsWith('/auth/login') ? (200, _login()) : resto(c);
      await tester.runAsync(() => auth.entrar('384801', 'carlos', 'senha1'));
      await tester.pumpWidget(
        MaterialApp(
          theme: temaDoApp(),
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => ContaPage(auth: auth, api: api.cliente),
            ),
          ),
        ),
      );
      await tester.pump();
      return (auth, api);
    }

    testWidgets('avisa que os dados saem só da loja logada e pede a senha', (tester) async {
      final (_, api) = await abrirConta(tester, (_) => (200, <String, dynamic>{}));

      expect(find.text('Carlos Moto'), findsOneWidget);
      expect(
        find.textContaining('Remove os seus dados da loja em que você está logado (Mercado Teste)'),
        findsOneWidget,
      );

      await tester.ensureVisible(find.byKey(const Key('excluir-conta')));
      await tester.tap(find.byKey(const Key('excluir-conta')));
      await _assentar(tester);

      expect(find.text('Excluir a sua conta?'), findsOneWidget);
      expect(
        find.textContaining('removidos da loja Mercado Teste, a loja em que você está logado'),
        findsOneWidget,
      );
      final dialogo = find.byType(AlertDialog);
      expect(
        find.descendant(
          of: dialogo,
          matching: find.textContaining(
            'Em outras lojas em que você trabalha, o seu cadastro continua',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialogo, matching: find.textContaining('registro inativo e anônimo')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialogo, matching: find.textContaining('Não dá para desfazer')),
        findsOneWidget,
      );

      // Sem senha, nada é enviado.
      await tester.tap(find.byKey(const Key('confirmar-exclusao')));
      await _assentar(tester);
      expect(find.text('Digite a sua senha para confirmar.'), findsOneWidget);
      expect(api.para('/conta/excluir'), isEmpty);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('senha errada ou entrega em andamento: mostra a mensagem e não sai', (
      tester,
    ) async {
      var mensagem = 'Senha incorreta. Os dados não foram removidos.';
      final (auth, api) = await abrirConta(tester, (c) => (422, {'message': mensagem}));

      await tester.ensureVisible(find.byKey(const Key('excluir-conta')));
      await tester.tap(find.byKey(const Key('excluir-conta')));
      await _assentar(tester);
      await tester.enterText(find.byKey(const Key('senha-exclusao')), 'errada');
      await tester.tap(find.byKey(const Key('confirmar-exclusao')));
      await _assentar(tester);

      expect(find.byKey(const Key('erro-exclusao')), findsOneWidget);
      expect(find.text('Senha incorreta. Os dados não foram removidos.'), findsOneWidget);
      expect(api.para('/conta/excluir').single.corpo, {'senha': 'errada'});
      expect(auth.sessao, isNotNull);

      mensagem = 'Você tem uma entrega em andamento. Conclua a entrega antes de excluir a conta.';
      await tester.tap(find.byKey(const Key('confirmar-exclusao')));
      await _assentar(tester);
      expect(find.textContaining('entrega em andamento'), findsOneWidget);
      expect(auth.sessao, isNotNull);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('com a senha certa remove, encerra a sessão e deixa o aviso para o login', (
      tester,
    ) async {
      final (auth, api) = await abrirConta(tester, (c) => (200, {'loja': 'Mercado Teste'}));

      await tester.ensureVisible(find.byKey(const Key('excluir-conta')));
      await tester.tap(find.byKey(const Key('excluir-conta')));
      await _assentar(tester);
      await tester.enterText(find.byKey(const Key('senha-exclusao')), 'senha1');
      await tester.tap(find.byKey(const Key('confirmar-exclusao')));
      await _assentar(tester);

      expect(api.para('/conta/excluir').single.corpo, {'senha': 'senha1'});
      expect(auth.sessao, isNull);
      expect(api.cliente.token, isNull);
      expect(auth.aviso, contains('removidos da loja Mercado Teste'));
      expect(auth.aviso, contains('Em outras lojas, o seu cadastro continua'));

      await tester.pumpWidget(const SizedBox());
    });
  });
}
