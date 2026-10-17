import 'package:flutter/material.dart';

import 'auth/auth_controller.dart';
import 'auth/login_page.dart';
import 'core/api_client.dart';
import 'core/localizacao.dart';
import 'core/tema.dart';
import 'corrida/rota_service.dart';
import 'dev/demo.dart';
import 'fila/fila_page.dart';

class EntregadorApp extends StatelessWidget {
  const EntregadorApp({
    super.key,
    required this.auth,
    required this.api,
    required this.localizacao,
    required this.rotas,
  });

  final AuthController auth;
  final ApiClient api;
  final Localizacao localizacao;
  final RotaService rotas;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Entregas',
      debugShowCheckedModeBanner: false,
      theme: temaDoApp(),
      builder: modoDemo && Demo.ligado
          ? (context, tela) =>
                Banner(message: 'DEMO', location: BannerLocation.bottomStart, child: tela!)
          : null,
      // Logado ou nao decide a tela inteira: ao perder a sessao (token
      // expirado, acesso retirado pela loja) tudo volta para o login.
      home: ListenableBuilder(
        listenable: auth,
        builder: (context, _) {
          if (auth.carregando) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          if (auth.sessao == null) return LoginPage(auth: auth, api: api);
          return FilaPage(
            // Sessao nova, fila nova.
            key: ValueKey(auth.sessao!.token),
            auth: auth,
            api: api,
            localizacao: localizacao,
            rotas: rotas,
          );
        },
      ),
    );
  }
}
