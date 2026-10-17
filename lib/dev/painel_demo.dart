import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:url_launcher/url_launcher.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';

import '../core/formato.dart';
import '../core/geo.dart';
import '../core/tema.dart';
import '../corrida/corrida_controller.dart';
import 'api_demo.dart';
import 'demo.dart';
import 'localizacao_simulada.dart';

/// Mapa da corrida no modo demonstracao: a rota tracada pelo app, o caminho
/// da moto, cada leitura do GPS (aceita ou descartada pelo filtro) e a trilha
/// corrigida que vai para o cliente. Embaixo, os controles da simulacao e as
/// falhas de GPS para provocar.
class PainelDemoPage extends StatefulWidget {
  const PainelDemoPage({super.key, required this.controller});

  final CorridaController controller;

  @override
  State<PainelDemoPage> createState() => _PainelDemoPageState();
}

/// Estilo vetorial "liberty" do OpenFreeMap: gratuito, sem chave, no visual
/// do Mapbox Streets. Lido uma vez por execucao.
Future<Style>? _estiloDoMapa;

Future<Style> _lerEstilo() => _estiloDoMapa ??=
    StyleReader(uri: 'https://tiles.openfreemap.org/styles/liberty').read().catchError((Object e) {
      _estiloDoMapa = null;
      throw e;
    });

class _PainelDemoPageState extends State<PainelDemoPage> {
  final _mapa = MapController();
  final _demo = Demo.atual;
  bool _seguir = true;
  bool _pronto = false;

  Style? _estilo;

  /// Ultimo rumo conhecido: parado, o GPS nao informa, e a seta fica onde estava.
  double _rumo = 0;

  LocalizacaoSimulada get _gps => _demo.gps;

  @override
  void initState() {
    super.initState();
    _demo.registro.addListener(_acompanharMoto);
    _lerEstilo().then(
      (estilo) {
        if (mounted) setState(() => _estilo = estilo);
      },
      onError: (Object _) {
        // Sem o estilo vetorial, fica a base raster do OpenStreetMap.
      },
    );
  }

  @override
  void dispose() {
    _demo.registro.removeListener(_acompanharMoto);
    _mapa.dispose();
    super.dispose();
  }

  void _acompanharMoto() {
    final moto = widget.controller.rastreio.posicao?.ponto ?? _gps.posicao;
    if (_seguir && _pronto) _mapa.move(_lat(moto), _mapa.camera.zoom);
  }

  static LatLng _lat(Ponto p) => LatLng(p.latitude, p.longitude);

  static List<LatLng> _linha(List<Ponto> pontos) => [for (final p in pontos) _lat(p)];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Simulação do rastreio', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: _seguir ? 'Parar de seguir a moto' : 'Seguir a moto',
            icon: Icon(_seguir ? Icons.gps_fixed : Icons.gps_not_fixed),
            onPressed: () {
              setState(() => _seguir = !_seguir);
              _acompanharMoto();
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([_demo.registro, _gps, ?_demo.api, widget.controller]),
        builder: (context, _) => Column(
          children: [
            Expanded(child: Stack(children: [_mapaDaCorrida(), const _Legenda()])),
            _Controles(controller: widget.controller, gps: _gps, api: _demo.api),
          ],
        ),
      ),
    );
  }

  Widget _mapaDaCorrida() {
    final registro = _demo.registro;
    final rastreio = widget.controller.rastreio;
    final destino = widget.controller.corrida.destino;
    final moto = rastreio.posicao?.ponto;
    _rumo = rastreio.posicao?.direcaoGraus ?? _rumo;
    final ultima = registro.leituras.lastOrNull?.simulada.leitura;
    final rotaAtual = registro.rotas.lastOrNull;

    return FlutterMap(
      mapController: _mapa,
      options: MapOptions(
        initialCenter: _lat(moto ?? _gps.posicao),
        initialZoom: 16,
        maxZoom: 19,
        onMapReady: () => _pronto = true,
        // Mexer no mapa com o dedo para de seguir a moto.
        onPointerDown: (_, _) {
          if (_seguir) setState(() => _seguir = false);
        },
      ),
      children: [
        if (_estilo case final estilo?)
          VectorTileLayer(
            theme: estilo.theme,
            sprites: estilo.sprites,
            tileProviders: estilo.providers,
          )
        else
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'br.com.catvirtual.entregador_app',
          ),
        PolylineLayer(
          polylines: [
            for (final rota in registro.rotas)
              if (!identical(rota, rotaAtual))
                Polyline(
                  points: _linha(rota.pontos),
                  color: Colors.blueGrey.withValues(alpha: 0.6),
                  strokeWidth: 4,
                  pattern: StrokePattern.dashed(segments: const [10, 8]),
                ),
            if (rotaAtual != null)
              Polyline(
                points: _linha(rotaAtual.pontos),
                color: const Color(0xFF2F6FDB).withValues(alpha: 0.75),
                strokeWidth: 6,
              ),
            if (_gps.trajeto.length > 1)
              Polyline(
                points: _linha(_gps.trajeto),
                color: Colors.purple.withValues(alpha: 0.7),
                strokeWidth: 2.5,
                pattern: const StrokePattern.dotted(),
              ),
            if (registro.corrigidas.length > 1)
              Polyline(points: _linha(registro.corrigidas), color: Cores.sucesso, strokeWidth: 4),
          ],
        ),
        CircleLayer(
          circles: [
            if (ultima != null)
              CircleMarker(
                point: _lat(ultima.ponto),
                radius: ultima.precisaoM,
                useRadiusInMeter: true,
                color: Colors.transparent,
                borderColor: Cores.destaque,
                borderStrokeWidth: 1.5,
              ),
            if (moto != null)
              CircleMarker(
                point: _lat(moto),
                radius: math.max(rastreio.posicao!.precisaoM, 6),
                useRadiusInMeter: true,
                color: Cores.primaria.withValues(alpha: 0.14),
                borderColor: Cores.primaria.withValues(alpha: 0.4),
                borderStrokeWidth: 1,
              ),
            for (final l in registro.leituras)
              CircleMarker(
                point: _lat(l.simulada.leitura.ponto),
                radius: l.aceita == false ? 5 : 3,
                color: l.aceita == false ? Cores.perigo : Colors.black54,
                borderColor: Colors.white,
                borderStrokeWidth: l.aceita == false ? 1.5 : 0,
              ),
          ],
        ),
        MarkerLayer(
          markers: [
            Marker(point: _lat(ApiDemo.loja), width: 34, height: 34, child: const _MarcaDaLoja()),
            if (destino != null)
              Marker(
                point: _lat(destino),
                width: 140,
                height: 72,
                alignment: Alignment.topCenter,
                child: _PinoDoDestino(nome: widget.controller.corrida.clienteNome),
              ),
            Marker(
              point: _lat(_gps.posicao),
              width: 12,
              height: 12,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.purple.withValues(alpha: 0.85),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
            if (moto != null)
              Marker(
                point: _lat(moto),
                width: 56,
                height: 56,
                child: _Moto(rumoGraus: _rumo, parada: (rastreio.posicao?.velocidadeMs ?? 0) < 0.7),
              ),
          ],
        ),
        // Creditos recolhidos num botao pequeno no canto: a licenca do OSM pede
        // que aparecam, nao que fiquem cobrindo o mapa.
        RichAttributionWidget(
          showFlutterMapAttribution: false,
          popupBackgroundColor: Cores.superficie,
          openButton: (context, abrir) =>
              _BotaoDeCreditos(aoTocar: abrir, icone: Icons.info_outline),
          closeButton: (context, fechar) => _BotaoDeCreditos(aoTocar: fechar, icone: Icons.close),
          attributions: [
            if (_estilo != null)
              TextSourceAttribution(
                'OpenFreeMap',
                onTap: () => launchUrl(Uri.parse('https://openfreemap.org')),
              ),
            if (_estilo != null)
              TextSourceAttribution(
                'OpenMapTiles',
                onTap: () => launchUrl(Uri.parse('https://www.openmaptiles.org')),
              ),
            TextSourceAttribution(
              'Colaboradores do OpenStreetMap',
              onTap: () => launchUrl(Uri.parse('https://www.openstreetmap.org/copyright')),
            ),
          ],
        ),
      ],
    );
  }
}

/// Moto do entregador: o icone fica sempre de pe, e uma seta em volta aponta
/// para onde ela vai. Parada, a seta some.
class _Moto extends StatelessWidget {
  const _Moto({required this.rumoGraus, required this.parada});

  final double rumoGraus;
  final bool parada;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        if (!parada)
          Transform.rotate(
            angle: rumoGraus * math.pi / 180,
            child: const CustomPaint(size: Size(56, 56), painter: _SetaDoRumo()),
          ),
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Cores.primaria,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: const [
              BoxShadow(color: Color(0x55000000), blurRadius: 6, offset: Offset(0, 2)),
            ],
          ),
          child: const Icon(Icons.two_wheeler, color: Colors.white, size: 20),
        ),
      ],
    );
  }
}

/// Triangulo no topo do quadro; girado, aponta o rumo.
class _SetaDoRumo extends CustomPainter {
  const _SetaDoRumo();

  @override
  void paint(Canvas canvas, Size size) {
    final centro = size.width / 2;
    final seta = Path()
      ..moveTo(centro, 0)
      ..lineTo(centro + 8, 11)
      ..lineTo(centro - 8, 11)
      ..close();
    canvas
      ..drawPath(seta, Paint()..color = Colors.white)
      ..drawPath(
        seta,
        Paint()
          ..color = Cores.primaria
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round,
      );
  }

  @override
  bool shouldRepaint(_SetaDoRumo oldDelegate) => false;
}

/// Pino do endereco de entrega, com o nome do cliente embaixo.
class _PinoDoDestino extends StatelessWidget {
  const _PinoDoDestino({required this.nome});

  final String nome;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: Cores.texto, borderRadius: BorderRadius.circular(10)),
          child: Text(
            nome,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 2),
        Stack(
          alignment: const Alignment(0, -0.35),
          children: [
            const Icon(
              Icons.location_on,
              size: 42,
              color: Cores.perigo,
              shadows: [Shadow(color: Color(0x66000000), blurRadius: 4, offset: Offset(0, 2))],
            ),
            Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              child: const Icon(Icons.home_rounded, size: 12, color: Cores.perigo),
            ),
          ],
        ),
      ],
    );
  }
}

class _MarcaDaLoja extends StatelessWidget {
  const _MarcaDaLoja();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Cores.destaque,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [BoxShadow(color: Color(0x44000000), blurRadius: 4, offset: Offset(0, 2))],
      ),
      child: const Icon(Icons.storefront, color: Cores.texto, size: 18),
    );
  }
}

class _BotaoDeCreditos extends StatelessWidget {
  const _BotaoDeCreditos({required this.aoTocar, required this.icone});

  final VoidCallback aoTocar;
  final IconData icone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Material(
        color: Cores.superficie.withValues(alpha: 0.8),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: aoTocar,
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Icon(icone, size: 16, color: Cores.apagado),
          ),
        ),
      ),
    );
  }
}

class _Legenda extends StatelessWidget {
  const _Legenda();

  @override
  Widget build(BuildContext context) {
    Widget item(Widget marca, String texto) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 22, child: Center(child: marca)),
          Text(texto),
        ],
      ),
    );
    Widget linha(Color cor, {double altura = 4}) =>
        Container(width: 18, height: altura, color: cor);
    Widget ponto(Color cor, double tamanho) => Container(
      width: tamanho,
      height: tamanho,
      decoration: BoxDecoration(color: cor, shape: BoxShape.circle),
    );

    return Positioned(
      left: 8,
      top: 8,
      child: Card(
        color: Cores.superficie.withValues(alpha: 0.92),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
          child: DefaultTextStyle(
            style: const TextStyle(fontSize: 11, color: Cores.texto),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                item(linha(const Color(0xFF2F6FDB)), 'Rota traçada pelo app'),
                item(linha(Colors.blueGrey, altura: 3), 'Rota anterior (recalculada)'),
                item(linha(Colors.purple, altura: 2), 'Caminho real da moto'),
                item(linha(Cores.sucesso), 'Trilha corrigida (enviada)'),
                item(ponto(Colors.black54, 6), 'Leitura aceita'),
                item(ponto(Cores.perigo, 9), 'Leitura descartada'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Controles extends StatelessWidget {
  const _Controles({required this.controller, required this.gps, required this.api});

  final CorridaController controller;
  final LocalizacaoSimulada gps;

  /// Nula com a API de verdade: sem contador do servidor nem queda de rede.
  final ApiDemo? api;

  static const _velocidades = {30: 8.3, 50: 13.9, 70: 19.4};

  @override
  Widget build(BuildContext context) {
    final registro = Demo.atual.registro;
    final rastreio = controller.rastreio;
    final distanciaM = controller.distanciaAoDestinoM;
    final anomalia = gps.anomalia;
    final api = this.api;
    final semRede = api?.semRede ?? false;
    final kmh = _velocidades.entries
        .firstWhere((e) => e.value == gps.velocidadeMs, orElse: () => _velocidades.entries.first)
        .key;

    return Material(
      color: Cores.superficie,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 2,
                children: [
                  Text('Leituras ${registro.leituras.length}'),
                  Text(
                    'Descartadas ${registro.descartadas}',
                    style: const TextStyle(color: Cores.perigo),
                  ),
                  if (api != null) Text('No servidor ${api.recebidas.length}'),
                  Text('Pendentes ${rastreio.pendentes}'),
                  Text('Rotas ${registro.rotas.length}'),
                  if (distanciaM != null) Text('Destino a ${distancia(distanciaM)}'),
                ],
              ),
              const SizedBox(height: 6),
              _Situacao(
                texto: controller.pertoDoDestino
                    ? 'Chegou: volte para a entrega e toque em Concluir.'
                    : anomalia != null
                    ? '${anomalia.titulo}: ${anomalia.descricao} (faltam ${gps.restantes})'
                    : semRede
                    ? 'Sem internet: as posições ficam guardadas no aparelho.'
                    : gps.pausado
                    ? 'Simulação pausada.'
                    : null,
                alerta: anomalia != null || semRede,
              ),
              Row(
                children: [
                  IconButton.filled(
                    tooltip: gps.pausado ? 'Continuar' : 'Pausar',
                    onPressed: () => gps.pausado = !gps.pausado,
                    icon: Icon(gps.pausado ? Icons.play_arrow : Icons.pause),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SegmentedButton<int>(
                      showSelectedIcon: false,
                      segments: [
                        for (final v in _velocidades.keys)
                          ButtonSegment(value: v, label: Text('$v km/h')),
                      ],
                      selected: {kmh},
                      onSelectionChanged: (escolha) =>
                          gps.velocidadeMs = _velocidades[escolha.first]!,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: -4,
                children: [
                  for (final a in Anomalia.values)
                    ActionChip(
                      label: Text(a.titulo),
                      tooltip: a.descricao,
                      onPressed: gps.trajeto.isEmpty ? null : () => gps.provocar(a),
                    ),
                  if (api != null)
                    ActionChip(
                      label: const Text('Sem internet'),
                      tooltip: '30 s sem rede',
                      onPressed: () => api.derrubarRede(const Duration(seconds: 30)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Situacao extends StatelessWidget {
  const _Situacao({required this.texto, required this.alerta});

  final String? texto;
  final bool alerta;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22,
      child: texto == null
          ? null
          : Text(
              texto!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: alerta ? Cores.perigo : Cores.sucesso,
              ),
            ),
    );
  }
}
