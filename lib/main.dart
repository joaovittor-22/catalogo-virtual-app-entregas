import 'package:flutter/material.dart';

import 'app.dart';
import 'auth/auth_controller.dart';
import 'auth/cofre.dart';
import 'core/api_client.dart';
import 'core/armazem.dart';
import 'core/config.dart';
import 'core/localizacao.dart';
import 'corrida/rota_service.dart';
import 'dev/demo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (modoDemo) {
    final demo = Demo.iniciar();
    final auth = AuthController(demo.apiClient, demo.cofre, armazem: demo.armazem);
    await auth.restaurar();
    if (auth.sessao == null && loginDev.isNotEmpty) {
      final partes = loginDev.split(':');
      try {
        await auth.entrar(partes[0], partes[1], partes.sublist(2).join(':'));
      } on ApiException catch (e) {
        debugPrint('DEV_LOGIN recusado: ${e.mensagem}');
      }
    }
    runApp(
      EntregadorApp(auth: auth, api: demo.apiClient, localizacao: demo.gps, rotas: demo.rotas),
    );
    return;
  }
  if (!Config.apiConfigurada) {
    runApp(const _SemApi());
    return;
  }
  final api = ApiClient();
  final auth = AuthController(api, CofreSeguro(), armazem: ArmazemSeguro());
  await auth.restaurar();
  runApp(
    EntregadorApp(auth: auth, api: api, localizacao: LocalizacaoDoAparelho(), rotas: RotaService()),
  );
}

/// Build de release feita sem `--dart-define=API_URL=...`: avisa em vez de tentar o emulador.
class _SemApi extends StatelessWidget {
  const _SemApi();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Este app foi gerado sem o endereço da API. '
              'Gere de novo com --dart-define=API_URL=https://...',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18),
            ),
          ),
        ),
      ),
    );
  }
}
