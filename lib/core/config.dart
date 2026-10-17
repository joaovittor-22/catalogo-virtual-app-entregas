import 'package:flutter/foundation.dart';

/// Enderecos dos servicos, definidos na compilacao:
///
/// ```
/// flutter run --dart-define=API_URL=https://api.exemplo.com.br
/// ```
class Config {
  const Config._();

  /// API do Cardapio Virtual. O padrao aponta para o computador que roda o
  /// emulador Android (10.0.2.2), para desenvolvimento local.
  static const String apiUrl = String.fromEnvironment(
    'API_URL',
    // Em release não há padrão: um app publicado apontando para o emulador não funciona.
    defaultValue: kReleaseMode ? '' : 'http://10.0.2.2:8080',
  );

  /// Falso numa build de release feita sem `--dart-define=API_URL=...`.
  static bool get apiConfigurada => apiUrl.isNotEmpty;

  /// Servidor de rotas OSRM (dados do OpenStreetMap), usado para medir
  /// distancia por rua e tracar o caminho. O endereco publico e gratuito mas
  /// serve so para demonstracao; em producao aponte para uma instancia propria.
  static const String osrmUrl = String.fromEnvironment(
    'OSRM_URL',
    // Em release, sem OSRM_URL, as distâncias ficam em linha reta: o servidor público é só para
    // demonstração e não pode ser usado em produção.
    defaultValue: kReleaseMode ? '' : 'https://router.project-osrm.org',
  );
}
