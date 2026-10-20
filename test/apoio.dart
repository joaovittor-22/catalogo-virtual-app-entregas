import 'dart:async';
import 'dart:convert';

import 'package:entregador_app/auth/cofre.dart';
import 'package:entregador_app/auth/sessao.dart';
import 'package:entregador_app/core/api_client.dart';
import 'package:entregador_app/core/geo.dart';
import 'package:entregador_app/core/localizacao.dart';
import 'package:entregador_app/corrida/filtro_gps.dart';
import 'package:entregador_app/corrida/rota_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Requisicao recebida pela API falsa.
class Chamada {
  Chamada(this.metodo, this.caminho, this.corpo, this.cabecalhos);

  final String metodo;
  final String caminho;
  final dynamic corpo;
  final Map<String, String> cabecalhos;
}

/// API de mentira: registra as chamadas e responde o que o teste mandar.
class ApiFalsa {
  final List<Chamada> chamadas = [];

  /// Devolve (status, corpo) para cada chamada.
  (int, Object?) Function(Chamada chamada) responder = (_) => (200, <String, dynamic>{});

  /// Sem rede: a chamada nem chega ao servidor (fica registrada, para contar tentativas).
  bool semRede = false;

  late final ApiClient cliente = ApiClient(
    baseUrl: 'http://api.teste',
    cliente: MockClient((requisicao) async {
      final chamada = Chamada(
        requisicao.method,
        requisicao.url.path,
        // Multipart (foto do comprovante) nao e JSON: fica so o registro da chamada.
        requisicao.body.isEmpty ||
                !(requisicao.headers['content-type'] ?? '').startsWith('application/json')
            ? null
            : jsonDecode(requisicao.body),
        requisicao.headers,
      );
      chamadas.add(chamada);
      if (semRede) throw http.ClientException('sem rede', requisicao.url);
      final (status, corpo) = responder(chamada);
      return http.Response(
        corpo == null ? '' : jsonEncode(corpo),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );

  List<Chamada> para(String trecho) => [
    for (final c in chamadas)
      if (c.caminho.contains(trecho)) c,
  ];
}

/// OSRM de mentira: devolve sempre a mesma rota.
RotaService rotasFalsas(List<Ponto> rota, {bool fora = false}) => RotaService(
  baseUrl: 'http://osrm.teste',
  cliente: MockClient((requisicao) async {
    if (fora) return http.Response('', 503);
    if (requisicao.url.path.startsWith('/table')) {
      final destinos = requisicao.url.path.split(';').length - 1;
      return http.Response(
        jsonEncode({
          'code': 'Ok',
          'distances': [
            [0, for (var i = 1; i <= destinos; i++) 1000.0 * i],
          ],
          'durations': [
            [0, for (var i = 1; i <= destinos; i++) 120.0 * i],
          ],
        }),
        200,
      );
    }
    return http.Response(
      jsonEncode({
        'code': 'Ok',
        'routes': [
          {
            'distance': 2180.0,
            'duration': 300.0,
            'geometry': {
              'coordinates': [
                for (final p in rota) [p.longitude, p.latitude],
              ],
            },
          },
        ],
      }),
      200,
    );
  }),
);

class LocalizacaoFalsa implements Localizacao {
  LocalizacaoFalsa({this.permissao = Permissao.concedida, this.posicao});

  Permissao permissao;

  /// O que o usuario responde ao pedido de permissao.
  Permissao respostaAoPedir = Permissao.concedida;
  Ponto? posicao;
  int pedidos = 0;
  final leituras = StreamController<Leitura>.broadcast();

  @override
  Future<Permissao> situacao() async => permissao;

  @override
  Future<Permissao> pedir() async {
    pedidos++;
    return permissao = respostaAoPedir;
  }

  @override
  Future<Ponto?> posicaoAtual() async => permissao == Permissao.concedida ? posicao : null;

  @override
  Stream<Leitura> acompanhar() => leituras.stream;

  @override
  Future<void> abrirAjustes() async {}
}

class CofreFalso implements Cofre {
  Sessao? sessao;
  ({String empresa, String identificador})? acesso;

  @override
  Future<Sessao?> lerSessao() async => sessao;

  @override
  Future<void> gravarSessao(Sessao nova) async => sessao = nova;

  @override
  Future<void> apagarSessao() async => sessao = null;

  @override
  Future<({String empresa, String identificador})?> lerUltimoAcesso() async => acesso;

  @override
  Future<void> gravarUltimoAcesso(String empresa, String identificador) async =>
      acesso = (empresa: empresa, identificador: identificador);

  String? empresaComAceite;

  @override
  Future<String?> lerEmpresaComAceite() async => empresaComAceite;

  @override
  Future<void> gravarEmpresaComAceite(String? empresa) async => empresaComAceite = empresa;
}

Map<String, dynamic> corridaJson({
  String status = 'em_rota',
  double? latitude = -16.68,
  double? longitude = -49.25,
}) => {
  'id': 3,
  'status': status,
  'pedidoId': 9,
  'numero': 'K7M2P9',
  'clienteNome': 'Joao Cliente',
  'clienteTelefone': status == 'em_rota' ? '62977776666' : null,
  'enderecoCompleto': 'Avenida T-63, 1000, Setor Bueno, Goiania/GO (ref.: portao azul)',
  'referencia': 'portao azul',
  'latitude': latitude,
  'longitude': longitude,
  'formaPagamento': 'dinheiro',
  'trocoPara': 100.0,
  'total': 57.5,
  'itens': [
    {'qtd': 2, 'nome': 'Arroz 5kg', 'adicionais': <String>[]},
  ],
  'raioChegadaM': 150,
};
