import 'dart:async';

import 'package:flutter/foundation.dart';

import '../auth/cofre.dart';
import '../core/armazem.dart';
import '../auth/sessao.dart';
import '../core/api_client.dart';
import '../core/geo.dart';
import '../corrida/filtro_gps.dart';
import '../corrida/rastreador.dart';
import '../corrida/rota_service.dart';
import 'api_demo.dart';
import 'localizacao_simulada.dart';

/// Ferramentas de desenvolvimento, todas so em debug ([kDebugMode] e
/// constante: em release nada daqui entra na build).
///
/// - `MOCK` (padrao: ligado): API em memoria e login pulado.
/// - `GPS_SIMULADO` (padrao: ligado): a moto anda sozinha ate o destino, com
///   o painel de mapa para ver o rastreio e provocar falhas de GPS. Vale
///   tambem com a API de verdade.
/// - `DEV_LOGIN=empresa:identificador:senha`: com a API de verdade, entra
///   sozinho na abertura do app.
///
/// Contra o back local, vendo o rastreio chegar ao cliente:
///
/// ```
/// flutter run --dart-define=MOCK=false --dart-define=DEV_LOGIN=minha-loja:carlos:segredo123
/// ```
const bool apiFalsa = kDebugMode && bool.fromEnvironment('MOCK', defaultValue: true);
const bool gpsSimulado = kDebugMode && bool.fromEnvironment('GPS_SIMULADO', defaultValue: true);
const String loginDev = kDebugMode ? String.fromEnvironment('DEV_LOGIN') : '';

/// Alguma ferramenta de demonstracao ligada.
const bool modoDemo = apiFalsa || gpsSimulado;

/// As pecas da demonstracao, ligadas entre si.
class Demo {
  Demo._({required bool comApiFalsa}) {
    gps = LocalizacaoSimulada(inicio: ApiDemo.loja, rotas: rotas);
    api = comApiFalsa ? ApiDemo() : null;
    apiClient = api == null
        ? ApiClient()
        : ApiClient(cliente: api!.cliente, baseUrl: 'http://demo');
    cofre = comApiFalsa ? CofreDemo() : CofreSeguro();
    armazem = comApiFalsa ? ArmazemEmMemoria() : ArmazemSeguro();
    registro = RegistroDemo(gps);
  }

  static Demo? _atual;

  static Demo get atual => _atual!;

  static Demo iniciar() => _atual ??= Demo._(comApiFalsa: apiFalsa);

  /// Se o app subiu em modo demonstracao. Os testes nao passam pelo `main` e
  /// continuam com as telas de sempre, mesmo em debug.
  static bool get ligado => _atual != null;

  final RotaService rotas = RotaServiceDemo();
  late final Cofre cofre;
  late final Armazem armazem;
  late final LocalizacaoSimulada gps;

  /// Nula quando o app fala com a API de verdade.
  late final ApiDemo? api;
  late final ApiClient apiClient;
  late final RegistroDemo registro;
}

/// Ja comeca logado: o login fica de fora da demonstracao, mas sair e entrar
/// de novo (com qualquer dado) continua funcionando.
class CofreDemo implements Cofre {
  Sessao? _sessao = Sessao.daResposta(ApiDemo.sessaoJson());

  @override
  Future<Sessao?> lerSessao() async => _sessao;

  @override
  Future<void> gravarSessao(Sessao sessao) async => _sessao = sessao;

  @override
  Future<void> apagarSessao() async => _sessao = null;

  @override
  Future<({String empresa, String identificador})?> lerUltimoAcesso() async =>
      (empresa: 'demo', identificador: 'entregador');

  @override
  Future<void> gravarUltimoAcesso(String empresa, String identificador) async {}

  String? _empresaComAceite;

  @override
  Future<String?> lerEmpresaComAceite() async => _empresaComAceite;

  @override
  Future<void> gravarEmpresaComAceite(String? empresa) async => _empresaComAceite = empresa;
}

/// OSRM de verdade quando ha internet; sem ela, linha reta, para o mapa da
/// demonstracao ainda ter o que desenhar.
class RotaServiceDemo extends RotaService {
  @override
  Future<Rota?> rota(Ponto origem, Ponto destino) async {
    final porRua = await super.rota(origem, destino);
    if (porRua != null) return porRua;
    const partes = 40;
    final distancia = distanciaM(origem, destino);
    return Rota(
      pontos: [
        for (var i = 0; i <= partes; i++)
          Ponto(
            origem.latitude + (destino.latitude - origem.latitude) * i / partes,
            origem.longitude + (destino.longitude - origem.longitude) * i / partes,
          ),
      ],
      distanciaM: distancia,
      duracaoS: distancia / 9,
    );
  }
}

/// Leitura crua e o que o rastreador fez com ela.
class LeituraRegistrada {
  LeituraRegistrada(this.simulada);

  final LeituraSimulada simulada;

  /// Nulo enquanto o rastreador nao decidiu.
  bool? aceita;
}

/// Tudo o que aconteceu na corrida atual, para o painel desenhar: leituras
/// cruas (aceitas e descartadas pelo filtro), posicoes corrigidas e as rotas
/// tracadas. Fica fora da tela, entao fechar o painel nao perde nada.
class RegistroDemo extends ChangeNotifier {
  RegistroDemo(LocalizacaoSimulada gps) {
    gps.emitidas.listen(_aoEmitir);
  }

  static const _limite = 3000;

  final List<LeituraRegistrada> leituras = [];
  final List<Ponto> corrigidas = [];
  final List<Rota> rotas = [];

  Rastreador? _rastreador;
  PosicaoCorrigida? _ultima;

  int get descartadas => leituras.where((l) => l.aceita == false).length;

  /// Passa a registrar a corrida deste [rastreador], do zero. Devolve falso
  /// quando ja era ela (o entregador voltou a fila e reabriu a entrega).
  bool acompanhar(Rastreador rastreador) {
    if (identical(rastreador, _rastreador)) return false;
    soltar();
    leituras.clear();
    corrigidas.clear();
    rotas.clear();
    _ultima = null;
    _rastreador = rastreador..estado.addListener(_aoMudarEstado);
    notifyListeners();
    return true;
  }

  void soltar() {
    _rastreador?.estado.removeListener(_aoMudarEstado);
    _rastreador = null;
  }

  void _aoEmitir(LeituraSimulada simulada) {
    if (_rastreador == null) return;
    // O rastreador decide cada leitura assim que a recebe: se a anterior nao
    // virou posicao ate a proxima chegar, foi descartada.
    for (final l in leituras.reversed) {
      if (l.aceita != null) break;
      l.aceita = false;
    }
    leituras.add(LeituraRegistrada(simulada));
    if (leituras.length > _limite) leituras.removeRange(0, leituras.length - _limite);
    notifyListeners();
  }

  void _aoMudarEstado() {
    final estado = _rastreador?.estado.value;
    if (estado == null) return;
    final rota = estado.rota;
    if (rota != null && (rotas.isEmpty || !identical(rotas.last, rota))) rotas.add(rota);
    final posicao = estado.posicao;
    if (posicao != null && !identical(posicao, _ultima)) {
      _ultima = posicao;
      corrigidas.add(posicao.ponto);
      for (final l in leituras.reversed) {
        if (l.simulada.leitura.em == posicao.em) {
          l.aceita = true;
          break;
        }
      }
    }
    notifyListeners();
  }
}
