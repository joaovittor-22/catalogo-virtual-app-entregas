import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api_client.dart';
import '../core/formato.dart';
import '../core/tema.dart';
import '../dev/demo.dart';
import '../dev/painel_demo.dart';
import 'corrida_controller.dart';
import 'rastreador.dart';

/// Entrega em andamento: detalhes do pedido, endereco completo, contato do
/// cliente e, chegando perto, o botao de concluir.
///
/// Ao sair, devolve a mensagem que a fila mostra ("Entrega concluída", etc.).
class CorridaPage extends StatefulWidget {
  const CorridaPage({super.key, required this.controller});

  final CorridaController controller;

  @override
  State<CorridaPage> createState() => _CorridaPageState();
}

class _CorridaPageState extends State<CorridaPage> {
  CorridaController get _c => widget.controller;
  bool _saindo = false;

  @override
  void initState() {
    super.initState();
    _c.addListener(_aoMudar);
    final corridaNova = modoDemo && Demo.ligado && Demo.atual.registro.acompanhar(_c.rastreador);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _c.comecar(explicar: _explicarLocalizacao);
      if (corridaNova) {
        // A moto simulada sai de onde esta rumo ao endereco desta entrega.
        final destino = _c.corrida.destino;
        if (destino != null) Demo.atual.gps.irPara(destino);
        _abrirPainelDemo();
      }
    });
  }

  @override
  void dispose() {
    _c.removeListener(_aoMudar);
    super.dispose();
  }

  void _abrirPainelDemo() => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => PainelDemoPage(controller: _c)));

  void _aoMudar() {
    if (_c.encerradaPelaLoja) _sair('A loja encerrou esta entrega.');
  }

  void _sair(String mensagem) {
    if (_saindo || !mounted) return;
    _saindo = true;
    Navigator.of(context).pop(mensagem);
  }

  /// RF-E11: explica para que serve antes do pedido de permissao do sistema.
  Future<bool> _explicarLocalizacao() async {
    final aceitou = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.my_location, color: Cores.primaria, size: 36),
        title: const Text('Compartilhar sua localização?'),
        content: const Text(
          'Durante a entrega, o app envia sua posição para o cliente acompanhar no mapa e '
          'para avisar quando você chegar.\n\n'
          'Isso só acontece com uma entrega em andamento e para assim que você concluir. '
          'Se preferir não compartilhar, dá para entregar normalmente.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Agora não'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continuar'),
          ),
        ],
      ),
    );
    return aceitou ?? false;
  }

  Future<void> _abrir(Uri uri) async {
    final abriu = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!abriu && mounted) _avisar('Não foi possível abrir.');
  }

  /// RF-E07: endereco no app de mapas do celular, em um toque.
  void _abrirMapa() {
    final destino = _c.corrida.destino;
    _abrir(
      destino != null
          ? Uri.https('www.google.com', '/maps/dir/', {
              'api': '1',
              'destination': '${destino.latitude},${destino.longitude}',
              'travelmode': 'driving',
            })
          : Uri.https('www.google.com', '/maps/search/', {
              'api': '1',
              'query': _c.corrida.enderecoCompleto ?? '',
            }),
    );
  }

  Future<void> _concluir({required bool longe}) async {
    if (longe && !await _confirmarLonge()) return;
    await _executar(_c.concluir, 'Entrega concluída. Escolha a próxima.');
  }

  Future<bool> _confirmarLonge() async {
    final distanciaM = _c.distanciaAoDestinoM;
    final confirmou = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Concluir mesmo assim?'),
        content: Text(
          distanciaM == null
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
            child: const Text('Já entreguei'),
          ),
        ],
      ),
    );
    return confirmou ?? false;
  }

  /// Foto opcional do comprovante de pagamento: camera ou galeria.
  Future<void> _escolherComprovante() async {
    final origem = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Tirar foto'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Escolher da galeria'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (origem == null) return;
    final XFile? foto;
    try {
      // Reduzida no aparelho: um comprovante legivel cabe em poucas centenas de KB.
      foto = await ImagePicker().pickImage(
        source: origem,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 80,
      );
    } on Exception {
      if (mounted) _avisar('Não foi possível abrir a câmera ou a galeria.');
      return;
    }
    if (foto == null) return;
    try {
      await _c.enviarComprovante(await foto.readAsBytes(), foto.name);
      if (mounted) _avisar('Comprovante enviado.');
    } on ApiException catch (e) {
      if (mounted) _avisar(e.mensagem);
    }
  }

  Future<void> _removerComprovante() async {
    try {
      await _c.removerComprovante();
    } on ApiException catch (e) {
      if (mounted) _avisar(e.mensagem);
    }
  }

  /// RF-E09: motivo obrigatorio.
  Future<void> _devolver() async {
    final motivo = await showDialog<String>(
      context: context,
      builder: (_) => const _DialogoDeMotivo(),
    );
    if (motivo == null) return;
    await _executar(() => _c.devolver(motivo), 'Pedido devolvido à loja.');
  }

  Future<void> _executar(Future<void> Function() acao, String aoTerminar) async {
    try {
      await acao();
      _sair(aoTerminar);
    } on ApiException catch (e) {
      // Rede caiu: nada se perde, e so tocar de novo.
      if (mounted) _avisar(e.mensagem);
    }
  }

  void _avisar(String texto) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(texto)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final corrida = _c.corrida;
        final telefone = corrida.clienteTelefone;
        // Voltar nao encerra nada: a entrega segue em andamento e a fila mostra
        // o atalho para reabri-la.
        return Scaffold(
          appBar: AppBar(
            title: Text(
              'Entrega #${corrida.numero}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            actions: [
              if (modoDemo && Demo.ligado)
                IconButton(
                  tooltip: 'Mapa da simulação',
                  icon: const Icon(Icons.map_outlined),
                  onPressed: _abrirPainelDemo,
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _FaixaDoRastreio(estado: _c.rastreio, aoAtivar: _c.ativarLocalizacao),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _Rotulo('Entregar para'),
                      Text(
                        corrida.clienteNome,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 12),
                      const _Rotulo('Endereço'),
                      SelectableText(
                        corrida.enderecoCompleto ?? 'Endereço não informado',
                        style: const TextStyle(fontSize: 18, height: 1.35),
                      ),
                      if (corrida.referencia?.isNotEmpty ?? false) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Referência: ${corrida.referencia}',
                          style: const TextStyle(fontSize: 16, color: Cores.apagado),
                        ),
                      ],
                      const SizedBox(height: 14),
                      FilledButton.tonalIcon(
                        onPressed: _abrirMapa,
                        icon: const Icon(Icons.map_outlined),
                        label: const Text('Abrir no mapa'),
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      ),
                      if (telefone != null && telefone.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => _abrir(
                                  Uri(scheme: 'tel', path: '+${telefoneInternacional(telefone)}'),
                                ),
                                icon: const Icon(Icons.call),
                                label: const Text('Ligar'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => _abrir(
                                  Uri.https('wa.me', '/${telefoneInternacional(telefone)}'),
                                ),
                                icon: const Icon(Icons.chat_outlined),
                                label: const Text('WhatsApp'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _Rotulo('Receber na entrega'),
                      Text(
                        '${moeda(corrida.total)} · ${pagamento(corrida.formaPagamento)}',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                      ),
                      if (corrida.trocoPara != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Levar troco para ${moeda(corrida.trocoPara)} '
                            '(${moeda(corrida.trocoPara! - corrida.total)} de troco)',
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                      const Divider(height: 28),
                      const _Rotulo('Itens'),
                      for (final item in corrida.itens)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${item.qtd}× ${item.nome}',
                                style: const TextStyle(fontSize: 16),
                              ),
                              for (final adicional in item.adicionais)
                                Text(
                                  '   + $adicional',
                                  style: const TextStyle(color: Cores.apagado),
                                ),
                            ],
                          ),
                        ),
                      if (corrida.observacao?.isNotEmpty ?? false) ...[
                        const Divider(height: 28),
                        const _Rotulo('Observações'),
                        Text(corrida.observacao!, style: const TextStyle(fontSize: 16)),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _CartaoDoComprovante(
                controller: _c,
                aoEnviar: _escolherComprovante,
                aoRemover: _removerComprovante,
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _c.enviando ? null : _devolver,
                child: const Text('Não consegui entregar'),
              ),
            ],
          ),
          bottomNavigationBar: _Rodape(
            controller: _c,
            aoConcluir: () => _concluir(longe: false),
            aoConcluirLonge: () => _concluir(longe: true),
          ),
        );
      },
    );
  }
}

/// Foto do comprovante de pagamento (maquininha, Pix, recibo). Opcional:
/// a entrega conclui com ou sem ela.
class _CartaoDoComprovante extends StatelessWidget {
  const _CartaoDoComprovante({
    required this.controller,
    required this.aoEnviar,
    required this.aoRemover,
  });

  final CorridaController controller;
  final VoidCallback aoEnviar;
  final VoidCallback aoRemover;

  @override
  Widget build(BuildContext context) {
    final corrida = controller.corrida;
    final foto = controller.fotoDoComprovante;
    final ocupado = controller.enviandoComprovante;
    final enviadoEm = corrida.comprovanteEm;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Rotulo('Comprovante de pagamento (opcional)'),
            if (!corrida.temComprovante)
              const Text(
                'Se o cliente pagou na maquininha ou por Pix, fotografe o comprovante.',
                style: TextStyle(color: Cores.apagado),
              )
            else
              Row(
                children: [
                  if (foto != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(foto, width: 56, height: 56, fit: BoxFit.cover),
                    )
                  else
                    const Icon(Icons.receipt_long, size: 40, color: Cores.sucesso),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      enviadoEm == null
                          ? 'Comprovante enviado.'
                          : 'Comprovante enviado às ${hora(enviadoEm)}.',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: ocupado ? null : aoEnviar,
                    icon: ocupado
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          )
                        : const Icon(Icons.photo_camera_outlined),
                    label: Text(corrida.temComprovante ? 'Trocar foto' : 'Enviar foto'),
                  ),
                ),
                if (corrida.temComprovante) ...[
                  const SizedBox(width: 8),
                  TextButton(onPressed: ocupado ? null : aoRemover, child: const Text('Remover')),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Pergunta por que a entrega nao foi feita. So fecha com um motivo escrito.
class _DialogoDeMotivo extends StatefulWidget {
  const _DialogoDeMotivo();

  @override
  State<_DialogoDeMotivo> createState() => _DialogoDeMotivoState();
}

class _DialogoDeMotivoState extends State<_DialogoDeMotivo> {
  final _campo = TextEditingController();

  @override
  void dispose() {
    _campo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Não consegui entregar'),
      content: TextField(
        controller: _campo,
        autofocus: true,
        maxLength: 500,
        maxLines: 3,
        decoration: const InputDecoration(hintText: 'O que aconteceu? Ex.: cliente ausente'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Voltar')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
          onPressed: () {
            if (_campo.text.trim().isNotEmpty) Navigator.pop(context, _campo.text);
          },
          child: const Text('Devolver pedido'),
        ),
      ],
    );
  }
}

/// Barra fixa embaixo: quanto falta e o botao de concluir.
class _Rodape extends StatelessWidget {
  const _Rodape({
    required this.controller,
    required this.aoConcluir,
    required this.aoConcluirLonge,
  });

  final CorridaController controller;
  final VoidCallback aoConcluir;
  final VoidCallback aoConcluirLonge;

  @override
  Widget build(BuildContext context) {
    final distanciaM = controller.distanciaAoDestinoM;
    final perto = controller.pertoDoDestino;
    final carregando = controller.enviando
        ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
        : null;

    return Material(
      color: Cores.superficie,
      elevation: 12,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(
                  perto
                      ? 'Você chegou ao endereço'
                      : distanciaM == null
                      ? 'Aguardando sua localização…'
                      : 'Faltam ${distancia(distanciaM)} até o endereço',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: perto ? Cores.sucesso : Cores.texto,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // O botao principal so aparece perto do destino. Antes disso
              // fica uma saida discreta, com confirmacao — o GPS pode falhar
              // ou o endereco nao ter sido localizado, e isso nao pode
              // impedir a entrega.
              if (perto)
                FilledButton.icon(
                  key: const Key('concluir'),
                  onPressed: controller.enviando ? null : aoConcluir,
                  icon: carregando ?? const Icon(Icons.check_circle),
                  label: const Text('Concluir entrega'),
                )
              else
                OutlinedButton(
                  key: const Key('concluir-longe'),
                  onPressed: controller.enviando ? null : aoConcluirLonge,
                  child: carregando ?? const Text('Já entreguei o pedido'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FaixaDoRastreio extends StatelessWidget {
  const _FaixaDoRastreio({required this.estado, required this.aoAtivar});

  final EstadoRastreio estado;
  final VoidCallback aoAtivar;

  @override
  Widget build(BuildContext context) {
    final semLocalizacao = estado.situacao == SituacaoRastreio.semLocalizacao;
    final ativo = estado.situacao == SituacaoRastreio.ativo;
    final String texto;
    if (semLocalizacao) {
      texto = 'Localização desligada. A entrega segue normalmente, sem o cliente ver você no mapa.';
    } else if (ativo && estado.semConexao) {
      texto = 'Sem internet. ${estado.pendentes} posições guardadas para enviar quando voltar.';
    } else if (ativo) {
      texto = 'O cliente está acompanhando sua posição até você concluir.';
    } else {
      texto = 'Preparando o rastreio…';
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: semLocalizacao || estado.semConexao
            ? const Color(0xFFFBEFD3)
            : const Color(0xFFE2EEE4),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            semLocalizacao
                ? Icons.location_off
                : estado.semConexao
                ? Icons.wifi_off
                : Icons.my_location,
            color: Cores.texto,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(texto)),
          if (semLocalizacao) TextButton(onPressed: aoAtivar, child: const Text('Ativar')),
        ],
      ),
    );
  }
}

class _Rotulo extends StatelessWidget {
  const _Rotulo(this.texto);

  final String texto;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        texto.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w800,
          color: Cores.apagado,
        ),
      ),
    );
  }
}
