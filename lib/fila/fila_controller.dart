import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/armazem.dart';
import '../core/espera.dart';
import '../core/geo.dart';
import '../core/localizacao.dart';
import '../corrida/corrida.dart';
import '../corrida/pendencias.dart';
import '../corrida/rota_service.dart';
import 'pedido_fila.dart';

/// Fila de pedidos prontos para entrega, com a distancia ate cada um.
class FilaController extends ChangeNotifier {
  FilaController({
    required this.api,
    required this.localizacao,
    required this.rotas,
    required this.dados,
    required this.pendencias,
  });

  /// RNF-E06: a fila se atualiza sozinha, sem pesar na rede.
  static const intervalo = Duration(seconds: 15);

  /// Sem rede, as consultas se espacam ate este teto; a volta da conexao
  /// (qualquer outra chamada com resposta) adianta a proxima.
  static const esperaMaxima = Duration(seconds: 60);

  /// RF-E12: ate quando a lista e a corrida guardadas no aparelho valem. Um
  /// turno; depois disso o que estava pronto ja saiu ou mudou.
  static const validadeDoGuardado = Duration(hours: 12);

  final ApiClient api;
  final Localizacao localizacao;
  final RotaService rotas;
  final DadosLocais dados;
  final Pendencias pendencias;

  List<ItemFila> itens = const [];
  bool carregando = true;
  String? erro;

  /// Hora da lista na tela. Sem rede, a lista guardada aparece com ela.
  DateTime? atualizadaEm;

  /// Ultima resposta da fila, como veio da API (ou do aparelho).
  Map<String, dynamic>? _ultimaResposta;

  /// Preenchido quando ja ha corrida em andamento: a tela abre direto nela.
  int? corridaAtivaId;

  /// De onde a distancia e medida: a posicao do entregador ou, sem
  /// localizacao, a loja.
  bool medindoDaLoja = false;
  Permissao permissao = Permissao.aPedir;

  /// Pedido cujo "Iniciar rota" esta em andamento.
  int? iniciando;

  /// Codigos do 409 de iniciar rota (RF-E03).
  static const codigoJaPego = 'PEDIDO_JA_PEGO';
  static const codigoCorridaAtiva = 'CORRIDA_ATIVA';

  /// API antiga, sem o codigo, diz o mesmo so na mensagem.
  static bool _corridaAtiva(ApiException e) =>
      e.codigo == codigoCorridaAtiva ||
      (e.conflito && e.codigo == null && e.mensagem.startsWith('Voce ja tem uma entrega'));

  Timer? _temporizador;
  final _espera = Espera(base: intervalo, maximo: esperaMaxima);
  bool _ativa = false;
  bool _restaurada = false;
  bool _buscando = false;
  bool _descartado = false;

  int? get maisProximo => indiceDoMaisProximo(itens);

  void comecar() {
    if (_ativa) return;
    _ativa = true;
    api.conectado.addListener(_aoMudarConexao);
    unawaited(_restaurar().then((_) => _ciclo()));
  }

  /// App em segundo plano ou corrida aberta: nada de consultar a fila.
  void pausar() {
    if (!_ativa) return;
    _ativa = false;
    api.conectado.removeListener(_aoMudarConexao);
    _temporizador?.cancel();
    _temporizador = null;
  }

  Future<void> _ciclo() async {
    _temporizador?.cancel();
    await carregar();
    if (!_ativa || _descartado) return;
    final proxima = erro == null ? intervalo : _espera.depoisDeFalhar();
    _temporizador?.cancel();
    _temporizador = Timer(proxima, _ciclo);
  }

  void _aoMudarConexao() {
    if (api.conectado.value && erro != null && !_buscando) unawaited(_ciclo());
  }

  /// Abre com a ultima lista guardada, para o entregador nao ficar diante de
  /// uma tela vazia enquanto a rede nao responde (RF-E12).
  Future<void> _restaurar() async {
    if (_restaurada) return;
    _restaurada = true;
    final guardada = await dados.ler('fila', validade: validadeDoGuardado);
    final resposta = guardada?.dados;
    if (resposta is! Map<String, dynamic> || _descartado || atualizadaEm != null) return;
    await _mostrar(resposta, guardada!.em);
  }

  Future<void> carregar() async {
    if (_buscando || _descartado) return;
    _buscando = true;
    try {
      // A corrida concluida sem rede vai antes: a API so libera o entregador
      // para outra depois de receber.
      if (!pendencias.vazia) await pendencias.enviar();
      final resposta = await api.get('/api/entregador/fila') as Map<String, dynamic>;
      erro = null;
      _espera.zerar();
      unawaited(dados.gravar('fila', resposta));
      await _mostrar(resposta, DateTime.now());
    } on ApiException catch (e) {
      // Sem rede, a ultima lista continua na tela (RF-E12).
      erro = e.mensagem;
      carregando = false;
      _avisar();
    } finally {
      _buscando = false;
    }
  }

  Future<void> _mostrar(Map<String, dynamic> resposta, DateTime em) async {
    _ultimaResposta = resposta;
    final novos = [
      for (final pedido in resposta['pedidos'] as List? ?? const [])
        ItemFila(PedidoFila.fromJson(pedido as Map<String, dynamic>)),
    ];
    final ativa = (resposta['corridaAtivaId'] as num?)?.toInt();
    // Concluida ou devolvida no aparelho: a API ainda nao sabe, mas o
    // entregador ja terminou com ela.
    corridaAtivaId = ativa != null && pendencias.encerradaAqui(ativa) ? null : ativa;
    atualizadaEm = em;

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
  ///
  /// Pegar um pedido precisa da API na hora: dois entregadores podem tocar no
  /// mesmo. Por isso nao fica guardado para depois, como concluir.
  Future<Corrida> iniciarRota(PedidoFila pedido) async {
    iniciando = pedido.pedidoId;
    _avisar();
    try {
      if (!pendencias.vazia && !await pendencias.enviar()) {
        final encerrada = pendencias.acoes.where((a) => a.encerra).firstOrNull;
        throw ApiException(
          encerrada == null
              ? 'Sem internet. Assim que a conexão voltar, você pode iniciar a rota.'
              : 'A entrega #${encerrada.numero} ainda não chegou à loja. Assim que a '
                    'conexão voltar, você pode iniciar outra.',
          codigo: 'PENDENCIAS',
        );
      }
      final resposta = await api.post('/api/entregador/fila/${pedido.pedidoId}/iniciar-rota');
      final corrida = Corrida.fromJson(resposta as Map<String, dynamic>);
      unawaited(dados.gravar('corrida', resposta));
      // A fila fica parada durante a corrida: a guardada precisa saber dela ja,
      // para o app reabrir a entrega se for aberto de novo sem rede. Na memoria
      // nao: quem iniciou a rota e que abre a corrida, uma vez so.
      itens = [
        for (final item in itens)
          if (item.pedido.pedidoId != pedido.pedidoId) item,
      ];
      _guardarFila(corridaAtivaId: corrida.id, semPedido: pedido.pedidoId);
      return corrida;
    } on ApiException catch (e) {
      if (e.semConexao && e.codigo == null) {
        throw const ApiException(
          'Sem internet. Para iniciar a rota é preciso estar conectado: outro entregador '
          'pode pegar o mesmo pedido.',
        );
      }
      // RF-E03: o pedido nao estar mais livre e um estado normal da fila, nao
      // erro: diz o que aconteceu e o que fazer.
      if (_corridaAtiva(e)) {
        // A fila traz a corrida em andamento, e a tela abre direto nela.
        unawaited(carregar());
        throw const ApiException(
          'Você já tem uma entrega em andamento. Conclua antes de pegar outra.',
          status: 409,
          codigo: codigoCorridaAtiva,
        );
      }
      if (e.conflito || e.status == 404) {
        itens = [
          for (final item in itens)
            if (item.pedido.pedidoId != pedido.pedidoId) item,
        ];
        unawaited(carregar());
        throw ApiException(
          e.conflito
              ? 'Outro entregador já pegou o pedido #${pedido.numero}. Escolha outro da fila.'
              : 'O pedido #${pedido.numero} não está mais disponível. Escolha outro da fila.',
          status: e.status,
          codigo: codigoJaPego,
        );
      }
      rethrow;
    } finally {
      iniciando = null;
      _avisar();
    }
  }

  /// Corrida em andamento, ou nulo quando o entregador esta livre. Sem rede,
  /// a guardada no aparelho, para o entregador seguir com o endereco e os
  /// itens na mao (RF-E12).
  Future<Corrida?> corridaAtual() async {
    try {
      final resposta = await api.get('/api/entregador/corrida');
      if (resposta == null) {
        unawaited(dados.apagar('corrida'));
        return null;
      }
      unawaited(dados.gravar('corrida', resposta));
      return Corrida.fromJson(resposta as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (!e.passageiro) rethrow;
      final guardada = await dados.ler('corrida', validade: validadeDoGuardado);
      final json = guardada?.dados;
      if (json is! Map<String, dynamic>) rethrow;
      final corrida = Corrida.fromJson(json);
      if (corrida.id != corridaAtivaId || pendencias.encerradaAqui(corrida.id)) rethrow;
      return corrida;
    }
  }

  /// A corrida acabou (concluida, devolvida ou encerrada pela loja).
  void esquecerCorrida() {
    corridaAtivaId = null;
    unawaited(dados.apagar('corrida'));
    _guardarFila(corridaAtivaId: null);
  }

  /// Atualiza a fila guardada com o que o app ja sabe e a API ainda nao
  /// mandou de novo: a corrida que comecou ou acabou, o pedido que saiu dela.
  void _guardarFila({required int? corridaAtivaId, int? semPedido}) {
    final ultima = _ultimaResposta;
    if (ultima == null) return;
    final atualizada = {
      ...ultima,
      'corridaAtivaId': corridaAtivaId,
      'pedidos': [
        for (final p in ultima['pedidos'] as List? ?? const [])
          if (semPedido == null || (p as Map)['pedidoId'] != semPedido) p,
      ],
    };
    _ultimaResposta = atualizada;
    unawaited(dados.gravar('fila', atualizada));
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
    _temporizador?.cancel();
    super.dispose();
  }
}
