import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../core/api_client.dart';
import '../core/formato.dart';
import '../core/localizacao.dart';
import '../core/tema.dart';
import '../corrida/corrida.dart';
import '../corrida/corrida_controller.dart';
import '../corrida/corrida_page.dart';
import '../conta/conta_page.dart';
import '../corrida/rota_service.dart';
import 'fila_controller.dart';
import 'pedido_fila.dart';

/// Pedidos prontos para entrega. Cada item ja traz o botao "Iniciar rota".
class FilaPage extends StatefulWidget {
  const FilaPage({
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
  State<FilaPage> createState() => _FilaPageState();
}

class _FilaPageState extends State<FilaPage> with WidgetsBindingObserver {
  late final FilaController _fila = FilaController(
    api: widget.api,
    localizacao: widget.localizacao,
    rotas: widget.rotas,
  );
  bool _naCorrida = false;

  /// Entrega em andamento. Fica viva fora da tela dela: o entregador pode
  /// voltar a fila e o rastreio continua ate concluir ou devolver.
  CorridaController? _corrida;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fila.addListener(_abrirCorridaAtiva);
    _fila.comecar();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fila.removeListener(_abrirCorridaAtiva);
    _fila.dispose();
    _encerrarCorrida();
    super.dispose();
  }

  /// Com o app em segundo plano a fila para de consultar a API.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_naCorrida) return;
    state == AppLifecycleState.resumed ? _fila.comecar() : _fila.pausar();
  }

  /// RF-E04: com corrida em andamento o app abre direto nela.
  Future<void> _abrirCorridaAtiva() async {
    if (_fila.corridaAtivaId == null || _naCorrida || _corrida != null) return;
    _naCorrida = true;
    try {
      final corrida = await _fila.corridaAtual();
      if (corrida != null && mounted) {
        await _abrirCorrida(corrida);
        return;
      }
    } on ApiException {
      // tenta de novo na proxima atualizacao da fila
    }
    _naCorrida = false;
  }

  Future<void> _iniciarRota(PedidoFila pedido) async {
    final ativa = _corrida;
    if (ativa != null) {
      _avisar(
        'Conclua a entrega #${ativa.corrida.numero} antes de iniciar outra.',
        acao: SnackBarAction(label: 'Abrir', onPressed: _reabrirCorrida),
      );
      return;
    }
    try {
      final corrida = await _fila.iniciarRota(pedido);
      if (mounted) await _abrirCorrida(corrida);
    } on ApiException catch (e) {
      // "Ja foi pego por outro entregador" e informacao, nao erro cru.
      if (mounted) _avisar(e.mensagem);
    }
  }

  Future<void> _abrirCorrida(Corrida corrida) async {
    _encerrarCorrida();
    final controller = CorridaController(
      api: widget.api,
      localizacao: widget.localizacao,
      rotas: widget.rotas,
      corrida: corrida,
    );
    _corrida = controller..addListener(_conferirCorrida);
    await _mostrarCorrida(controller);
  }

  void _reabrirCorrida() {
    final controller = _corrida;
    if (controller != null && !_naCorrida) _mostrarCorrida(controller);
  }

  Future<void> _mostrarCorrida(CorridaController controller) async {
    _naCorrida = true;
    _fila.pausar();
    final mensagem = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => CorridaPage(controller: controller)));
    _naCorrida = false;
    if (!mounted) return;
    // Sem mensagem, o entregador so voltou: a entrega segue em andamento.
    if (mensagem != null) {
      _encerrarCorrida();
      _avisar(mensagem);
      // Entrega encerrada: o entregador esta livre para escolher a proxima.
      _fila.corridaAtivaId = null;
    }
    setState(() {});
    _fila.comecar();
  }

  /// Conclui direto da fila, sem abrir a entrega. Sempre confirma: o botao
  /// fica ao lado da lista, e um toque sem querer encerraria o rastreio.
  Future<void> _concluirPelaFila() async {
    final ativa = _corrida;
    if (ativa == null || ativa.enviando) return;
    final distanciaM = ativa.distanciaAoDestinoM;
    final longe = !ativa.pertoDoDestino;
    final confirmou = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Concluir a entrega #${ativa.corrida.numero}?'),
        content: Text(
          !longe
              ? 'Entrega para ${ativa.corrida.clienteNome}.'
              : distanciaM == null
              ? 'Não foi possível confirmar pelo GPS que você chegou ao endereço. '
                    'Conclua só se o pedido já foi entregue.'
              : 'Você ainda está a ${distancia(distanciaM)} do endereço. '
                    'Conclua só se o pedido já foi entregue.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Voltar')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: () => Navigator.pop(context, true),
            child: Text(longe ? 'Já entreguei' : 'Concluir'),
          ),
        ],
      ),
    );
    if (confirmou != true || !mounted) return;
    try {
      await ativa.concluir();
    } on ApiException catch (e) {
      // Rede caiu: a entrega segue aberta, e so tocar de novo.
      if (mounted) _avisar(e.mensagem);
      return;
    }
    _encerrarCorrida();
    _fila.corridaAtivaId = null;
    if (!mounted) return;
    setState(() {});
    _avisar('Entrega concluída. Escolha a próxima.');
    _fila.carregar();
  }

  /// A loja encerrou a entrega enquanto o entregador estava na fila.
  void _conferirCorrida() {
    if (_naCorrida || !(_corrida?.encerradaPelaLoja ?? false)) return;
    _encerrarCorrida();
    _fila.corridaAtivaId = null;
    if (!mounted) return;
    setState(() {});
    _avisar('A loja encerrou esta entrega.');
    _fila.carregar();
  }

  void _encerrarCorrida() {
    _corrida
      ?..removeListener(_conferirCorrida)
      ..dispose();
    _corrida = null;
  }

  void _avisar(String texto, {SnackBarAction? acao}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(texto), action: acao));
  }

  Future<void> _mostrarHistorico() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _Historico(carregar: _fila.historico),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sessao = widget.auth.sessao;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Entregas', style: TextStyle(fontWeight: FontWeight.w800)),
            if (sessao != null)
              Text(
                '${sessao.entregadorNome} · ${sessao.lojaNome}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Entregas de hoje',
            icon: const Icon(Icons.history),
            onPressed: _mostrarHistorico,
          ),
          IconButton(
            tooltip: 'Conta e termos',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ContaPage(auth: widget.auth, api: widget.api),
              ),
            ),
          ),
          IconButton(tooltip: 'Sair', icon: const Icon(Icons.logout), onPressed: widget.auth.sair),
        ],
      ),
      body: ListenableBuilder(
        listenable: _fila,
        builder: (context, _) {
          if (_fila.carregando) return const Center(child: CircularProgressIndicator());
          final maisProximo = _fila.maisProximo;
          return RefreshIndicator(
            onRefresh: _fila.carregar,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (_corrida case final ativa?)
                  _EntregaEmAndamento(
                    controller: ativa,
                    aoAbrir: _reabrirCorrida,
                    aoConcluir: _concluirPelaFila,
                  ),
                if (_fila.erro != null)
                  _Aviso(icone: Icons.wifi_off, texto: '${_fila.erro} Mostrando a última lista.'),
                if (_fila.permissao != Permissao.concedida && _fila.itens.isNotEmpty)
                  _Aviso(
                    icone: Icons.my_location,
                    texto: _fila.medindoDaLoja
                        ? 'Distâncias medidas a partir da loja. Ative a localização para '
                              'medir de onde você está.'
                        : 'Ative a localização para ver qual pedido está mais perto de você.',
                    acao: 'Ativar',
                    aoTocar: _fila.ativarLocalizacao,
                  ),
                if (_fila.itens.isEmpty)
                  const _FilaVazia()
                else
                  for (var i = 0; i < _fila.itens.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _CartaoPedido(
                        item: _fila.itens[i],
                        maisProximo: i == maisProximo,
                        iniciando: _fila.iniciando == _fila.itens[i].pedido.pedidoId,
                        bloqueado: _fila.iniciando != null,
                        aoIniciar: () => _iniciarRota(_fila.itens[i].pedido),
                      ),
                    ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CartaoPedido extends StatelessWidget {
  const _CartaoPedido({
    required this.item,
    required this.maisProximo,
    required this.iniciando,
    required this.bloqueado,
    required this.aoIniciar,
  });

  final ItemFila item;
  final bool maisProximo;
  final bool iniciando;
  final bool bloqueado;
  final VoidCallback aoIniciar;

  @override
  Widget build(BuildContext context) {
    final pedido = item.pedido;
    final distanciaM = item.distanciaM;
    final duracaoS = item.duracaoS;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: maisProximo ? Cores.primaria : Cores.borda,
          width: maisProximo ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (maisProximo)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Cores.primaria,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.near_me, size: 15, color: Colors.white),
                    SizedBox(width: 5),
                    Text(
                      'Mais próximo',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    pedido.clienteNome,
                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text('#${pedido.numero}', style: const TextStyle(color: Cores.apagado)),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(Icons.place_outlined, size: 19, color: Cores.apagado),
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(pedido.enderecoResumo, style: const TextStyle(fontSize: 16))),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                _Dado(
                  icone: Icons.route_outlined,
                  // "~" avisa que e linha reta, enquanto a distancia por rua nao chega.
                  texto: distanciaM == null
                      ? 'Distância indisponível'
                      : '${item.porRua ? '' : '~'}${distancia(distanciaM)}'
                            '${duracaoS == null ? '' : ' · ${duracao(duracaoS)}'}',
                ),
                _Dado(
                  icone: Icons.payments_outlined,
                  texto: '${moeda(pedido.total)} · ${pagamento(pedido.formaPagamento)}',
                ),
                _Dado(
                  icone: Icons.shopping_bag_outlined,
                  texto: pedido.quantidadeItens == 1 ? '1 item' : '${pedido.quantidadeItens} itens',
                ),
              ],
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: bloqueado ? null : aoIniciar,
              icon: iniciando
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : const Icon(Icons.navigation),
              label: const Text('Iniciar rota'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dado extends StatelessWidget {
  const _Dado({required this.icone, required this.texto});

  final IconData icone;
  final String texto;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icone, size: 17, color: Cores.apagado),
        const SizedBox(width: 5),
        Text(texto, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// Entrega em andamento, no topo da fila: reabrir ou concluir sem abrir.
class _EntregaEmAndamento extends StatelessWidget {
  const _EntregaEmAndamento({
    required this.controller,
    required this.aoAbrir,
    required this.aoConcluir,
  });

  final CorridaController controller;
  final VoidCallback aoAbrir;
  final VoidCallback aoConcluir;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final corrida = controller.corrida;
        final distanciaM = controller.distanciaAoDestinoM;
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Cores.destaque, width: 2),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.two_wheeler, color: Cores.primaria),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Em andamento · #${corrida.numero}',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    if (distanciaM != null)
                      Text(distancia(distanciaM), style: const TextStyle(color: Cores.apagado)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  corrida.clienteNome,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                if (corrida.enderecoCompleto != null)
                  Text(corrida.enderecoCompleto!, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(onPressed: aoAbrir, child: const Text('Abrir')),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: controller.enviando ? null : aoConcluir,
                        icon: controller.enviando
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(strokeWidth: 2.5),
                              )
                            : const Icon(Icons.check),
                        label: const Text('Concluir'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Aviso extends StatelessWidget {
  const _Aviso({required this.icone, required this.texto, this.acao, this.aoTocar});

  final IconData icone;
  final String texto;
  final String? acao;
  final VoidCallback? aoTocar;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFBEFD3),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icone, color: Cores.texto),
          const SizedBox(width: 10),
          Expanded(child: Text(texto)),
          if (acao != null) TextButton(onPressed: aoTocar, child: Text(acao!)),
        ],
      ),
    );
  }
}

class _FilaVazia extends StatelessWidget {
  const _FilaVazia();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 80, horizontal: 24),
      child: Column(
        children: [
          Icon(Icons.inbox_outlined, size: 64, color: Cores.apagado),
          SizedBox(height: 12),
          Text(
            'Nenhum pedido para entregar agora',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
          SizedBox(height: 6),
          Text(
            'Quando a loja liberar um pedido, ele aparece aqui sozinho.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Cores.apagado),
          ),
        ],
      ),
    );
  }
}

class _Historico extends StatelessWidget {
  const _Historico({required this.carregar});

  final Future<List<Map<String, dynamic>>> Function() carregar;

  static String _situacao(String? status) {
    switch (status) {
      case 'entregue':
        return 'Entregue';
      case 'devolvida':
        return 'Não entregue';
      default:
        return 'Em andamento';
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<List<Map<String, dynamic>>>(
        future: carregar(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()));
          }
          final entregas = snapshot.data;
          if (entregas == null) {
            return const SizedBox(
              height: 160,
              child: Center(child: Text('Não foi possível carregar o histórico.')),
            );
          }
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              const Text(
                'Entregas de hoje',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              if (entregas.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('Nenhuma entrega hoje ainda.'),
                ),
              for (final entrega in entregas)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    entrega['status'] == 'entregue' ? Icons.check_circle : Icons.undo,
                    color: entrega['status'] == 'entregue' ? Cores.sucesso : Cores.apagado,
                  ),
                  title: Text(entrega['enderecoResumo'] as String? ?? 'Pedido'),
                  subtitle: Text(
                    '#${entrega['numero'] ?? ''} · ${_situacao(entrega['status'] as String?)}',
                  ),
                  trailing: Text(
                    hora(
                      DateTime.tryParse(
                        (entrega['finalizadaEm'] ?? entrega['iniciadaEm'] ?? '') as String,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
