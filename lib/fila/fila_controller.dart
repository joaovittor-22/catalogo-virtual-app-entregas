import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/geo.dart';
import '../core/localizacao.dart';
import '../corrida/corrida.dart';
import '../corrida/rota_service.dart';
import 'pedido_fila.dart';

/// Fila de pedidos prontos para entrega, com a distancia ate cada um.
class FilaController extends ChangeNotifier {
  FilaController({required this.api, required this.localizacao, required this.rotas});

  /// RNF-E06: a fila se atualiza sozinha, sem pesar na rede.
  static const intervalo = Duration(seconds: 15);

  final ApiClient api;
  final Localizacao localizacao;
  final RotaService rotas;

  List<ItemFila> itens = const [];
  bool carregando = true;
  String? erro;

  /// Preenchido quando ja ha corrida em andamento: a tela abre direto nela.
  int? corridaAtivaId;

  /// De onde a distancia e medida: a posicao do entregador ou, sem
  /// localizacao, a loja.
  bool medindoDaLoja = false;
  Permissao permissao = Permissao.aPedir;

  /// Pedido cujo "Iniciar rota" esta em andamento.
  int? iniciando;

  Timer? _temporizador;
  bool _buscando = false;
  bool _descartado = false;

  int? get maisProximo => indiceDoMaisProximo(itens);

  void comecar() {
    carregar();
    _temporizador ??= Timer.periodic(intervalo, (_) => carregar());
  }

  void pausar() {
    _temporizador?.cancel();
    _temporizador = null;
  }

  Future<void> carregar() async {
    if (_buscando || _descartado) return;
    _buscando = true;
    try {
      final resposta = await api.get('/api/entregador/fila') as Map<String, dynamic>;
      final novos = [
        for (final pedido in resposta['pedidos'] as List? ?? const [])
          ItemFila(PedidoFila.fromJson(pedido as Map<String, dynamic>)),
      ];
      corridaAtivaId = (resposta['corridaAtivaId'] as num?)?.toInt();
      erro = null;

      permissao = await localizacao.situacao();
      final minhaPosicao = await localizacao.posicaoAtual();
      final loja = resposta['loja'] as Map<String, dynamic>?;
      final origem =
          minhaPosicao ??
          (loja == null
              ? null
              : Ponto((loja['latitude'] as num).toDouble(), (loja['longitude'] as num).toDouble()));
      medindoDaLoja = minhaPosicao == null && origem != null;

      // Linha reta na hora, para a lista aparecer sem esperar a rede.
      if (origem != null) {
        for (final item in novos) {
          final destino = item.pedido.destino;
          if (destino != null) item.distanciaM = distanciaM(origem, destino);
        }
      }
      itens = novos;
      carregando = false;
      _avisar();

      if (origem != null) await _refinarPorRua(origem, novos);
    } on ApiException catch (e) {
      // Sem rede, a ultima lista continua na tela (RF-E12).
      erro = e.mensagem;
      carregando = false;
      _avisar();
    } finally {
      _buscando = false;
    }
  }

  /// Troca a linha reta pela distancia por rua, quando o OSRM responde.
  Future<void> _refinarPorRua(Ponto origem, List<ItemFila> lista) async {
    final comDestino = [
      for (final item in lista)
        if (item.pedido.destino != null) item,
    ];
    if (comDestino.isEmpty) return;
    final trajetos = await rotas.trajetos(origem, [
      for (final item in comDestino) item.pedido.destino!,
    ]);
    if (trajetos == null || _descartado || !identical(itens, lista)) return;
    for (var i = 0; i < comDestino.length; i++) {
      final trajeto = trajetos[i];
      if (trajeto == null) continue;
      comDestino[i]
        ..distanciaM = trajeto.distanciaM
        ..duracaoS = trajeto.duracaoS
        ..porRua = true;
    }
    _avisar();
  }

  /// Pede a permissao de localizacao para medir a partir do entregador.
  Future<void> ativarLocalizacao() async {
    permissao = await localizacao.pedir();
    if (permissao == Permissao.bloqueada || permissao == Permissao.gpsDesligado) {
      await localizacao.abrirAjustes();
    }
    await carregar();
  }

  /// RF-E03 + RF-E06: pega o pedido e sai com ele. Se outro entregador foi
  /// mais rapido, lanca [ApiException] com o aviso e tira o item da lista.
  Future<Corrida> iniciarRota(PedidoFila pedido) async {
    iniciando = pedido.pedidoId;
    _avisar();
    try {
      final resposta = await api.post('/api/entregador/fila/${pedido.pedidoId}/iniciar-rota');
      return Corrida.fromJson(resposta as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (e.conflito) {
        itens = [
          for (final item in itens)
            if (item.pedido.pedidoId != pedido.pedidoId) item,
        ];
        unawaited(carregar());
      }
      rethrow;
    } finally {
      iniciando = null;
      _avisar();
    }
  }

  /// Corrida em andamento, ou nulo quando o entregador esta livre.
  Future<Corrida?> corridaAtual() async {
    final resposta = await api.get('/api/entregador/corrida');
    return resposta == null ? null : Corrida.fromJson(resposta as Map<String, dynamic>);
  }

  /// RF-E10: entregas de hoje.
  Future<List<Map<String, dynamic>>> historico() async {
    final resposta = await api.get('/api/entregador/historico') as List;
    return resposta.cast<Map<String, dynamic>>();
  }

  void _avisar() {
    if (!_descartado) notifyListeners();
  }

  @override
  void dispose() {
    _descartado = true;
    pausar();
    super.dispose();
  }
}
