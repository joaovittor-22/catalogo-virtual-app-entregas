import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config.dart';
import '../core/geo.dart';

/// Caminho por rua entre dois pontos.
class Rota {
  const Rota({required this.pontos, required this.distanciaM, required this.duracaoS});

  final List<Ponto> pontos;
  final double distanciaM;
  final double duracaoS;
}

/// Distancia e tempo por rua ate um destino.
class Trajeto {
  const Trajeto({required this.distanciaM, required this.duracaoS});

  final double distanciaM;
  final double duracaoS;
}

/// Rotas e distancias pelo OSRM, que roda sobre dados do OpenStreetMap e pode
/// ser hospedado pela propria loja. Toda falha vira nulo: quem chama cai na
/// distancia em linha reta, e a entrega nunca depende deste servico.
class RotaService {
  RotaService({http.Client? cliente, String? baseUrl})
    : _http = cliente ?? http.Client(),
      _base = baseUrl ?? Config.osrmUrl;

  static const _tempoLimite = Duration(seconds: 8);

  final http.Client _http;
  final String _base;

  static String _coordenada(Ponto p) => '${p.longitude},${p.latitude}';

  Future<Rota?> rota(Ponto origem, Ponto destino) async {
    final dados = await _buscar(
      '/route/v1/driving/${_coordenada(origem)};${_coordenada(destino)}'
      '?overview=full&geometries=geojson',
    );
    final rotas = dados?['routes'];
    if (rotas is! List || rotas.isEmpty) return null;
    final coordenadas = rotas.first['geometry']?['coordinates'];
    if (coordenadas is! List || coordenadas.length < 2) return null;
    return Rota(
      pontos: [
        for (final par in coordenadas)
          Ponto((par[1] as num).toDouble(), (par[0] as num).toDouble()),
      ],
      distanciaM: (rotas.first['distance'] as num).toDouble(),
      duracaoS: (rotas.first['duration'] as num).toDouble(),
    );
  }

  /// Distancia por rua da [origem] ate cada destino, numa chamada so.
  /// A lista volta na mesma ordem; nulo onde nao houve caminho.
  Future<List<Trajeto?>?> trajetos(Ponto origem, List<Ponto> destinos) async {
    if (destinos.isEmpty) return const [];
    final coordenadas = [origem, ...destinos].map(_coordenada).join(';');
    final dados = await _buscar(
      '/table/v1/driving/$coordenadas?sources=0&annotations=distance,duration',
    );
    final distancias = dados?['distances'];
    final duracoes = dados?['durations'];
    if (distancias is! List || distancias.isEmpty || duracoes is! List || duracoes.isEmpty) {
      return null;
    }
    final linhaDistancia = distancias.first as List;
    final linhaDuracao = duracoes.first as List;
    return [
      for (var i = 1; i <= destinos.length; i++)
        linhaDistancia[i] == null || linhaDuracao[i] == null
            ? null
            : Trajeto(
                distanciaM: (linhaDistancia[i] as num).toDouble(),
                duracaoS: (linhaDuracao[i] as num).toDouble(),
              ),
    ];
  }

  Future<Map<String, dynamic>?> _buscar(String caminho) async {
    // Sem servidor de rotas configurado: fica a linha reta.
    if (_base.isEmpty) return null;
    try {
      final resposta = await _http
          .get(Uri.parse('$_base$caminho'), headers: {'User-Agent': 'entregador-app/1.0'})
          .timeout(_tempoLimite);
      if (resposta.statusCode != 200) return null;
      final dados = jsonDecode(utf8.decode(resposta.bodyBytes));
      return dados is Map<String, dynamic> && dados['code'] == 'Ok' ? dados : null;
    } catch (_) {
      return null;
    }
  }
}
