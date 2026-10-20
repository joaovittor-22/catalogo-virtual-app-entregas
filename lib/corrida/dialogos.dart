import 'package:flutter/material.dart';

import '../core/formato.dart';
import '../core/tema.dart';

/// Toques rapidos que preenchem o campo: o entregador esta na rua, de
/// capacete, e digitar e o que menos quer (RNF-E07). O texto continua editavel.
class _Sugestoes extends StatelessWidget {
  const _Sugestoes({required this.opcoes, required this.campo});

  final List<String> opcoes;
  final TextEditingController campo;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final opcao in opcoes)
          ActionChip(
            label: Text(opcao),
            onPressed: () => campo.value = TextEditingValue(
              text: opcao,
              selection: TextSelection.collapsed(offset: opcao.length),
            ),
          ),
      ],
    );
  }
}

/// RF-E09: por que a entrega nao foi feita. So devolve com um motivo, que a
/// loja ve no pedido.
class DialogoDeMotivo extends StatefulWidget {
  const DialogoDeMotivo({super.key});

  static const sugestoes = [
    'Cliente ausente',
    'Endereço não encontrado',
    'Cliente recusou o pedido',
    'Problema com o veículo',
  ];

  @override
  State<DialogoDeMotivo> createState() => _DialogoDeMotivoState();
}

class _DialogoDeMotivoState extends State<DialogoDeMotivo> {
  final _campo = TextEditingController();

  @override
  void initState() {
    super.initState();
    _campo.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _campo.dispose();
    super.dispose();
  }

  bool get _temMotivo => _campo.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Não consegui entregar'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('O pedido volta para a fila da loja. Conte o que aconteceu:'),
            const SizedBox(height: 12),
            _Sugestoes(opcoes: DialogoDeMotivo.sugestoes, campo: _campo),
            const SizedBox(height: 8),
            TextField(
              key: const Key('motivo'),
              controller: _campo,
              maxLength: 500,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(
                labelText: 'Motivo',
                hintText: 'O que aconteceu? Ex.: cliente ausente',
                helperText: 'Obrigatório. A loja vê este motivo no pedido.',
                // O contador divide a linha: o aviso quebra em vez de ser cortado.
                helperMaxLines: 2,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Voltar')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
          // Sem motivo o botao fica apagado: nada de toque que nao faz nada.
          onPressed: _temMotivo ? () => Navigator.pop(context, _campo.text.trim()) : null,
          child: const Text('Devolver pedido'),
        ),
      ],
    );
  }
}

/// RF-E08: confirma a conclusao, com uma observacao opcional para a loja.
/// Devolve nulo quando o entregador desiste; senao, a observacao (vazia se
/// nao escreveu nada).
class DialogoDeConclusao extends StatefulWidget {
  const DialogoDeConclusao({
    super.key,
    required this.numero,
    required this.clienteNome,
    required this.longe,
    this.distanciaM,
  });

  final String numero;
  final String clienteNome;

  /// Fora do raio de chegada (ou sem GPS): pede para conferir antes.
  final bool longe;
  final double? distanciaM;

  static const sugestoes = [
    'Entregue na portaria',
    'Entregue a outra pessoa da casa',
    'Deixado no local combinado',
  ];

  @override
  State<DialogoDeConclusao> createState() => _DialogoDeConclusaoState();
}

class _DialogoDeConclusaoState extends State<DialogoDeConclusao> {
  final _campo = TextEditingController();

  @override
  void dispose() {
    _campo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final distanciaM = widget.distanciaM;
    return AlertDialog(
      title: Text(widget.longe ? 'Concluir mesmo assim?' : 'Concluir a entrega #${widget.numero}?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              !widget.longe
                  ? 'Entrega para ${widget.clienteNome}.'
                  : distanciaM == null
                  ? 'Não foi possível confirmar pelo GPS que você chegou ao endereço. '
                        'Conclua só se o pedido já foi entregue.'
                  : 'Você ainda está a ${distancia(distanciaM)} do endereço. '
                        'Conclua só se o pedido já foi entregue.',
            ),
            const SizedBox(height: 12),
            _Sugestoes(opcoes: DialogoDeConclusao.sugestoes, campo: _campo),
            const SizedBox(height: 8),
            TextField(
              key: const Key('observacao'),
              controller: _campo,
              maxLength: 500,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(
                labelText: 'Observação para a loja (opcional)',
                hintText: 'Ex.: deixado com o porteiro',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Voltar')),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size(120, 48),
            backgroundColor: widget.longe ? null : Cores.sucesso,
          ),
          onPressed: () => Navigator.pop(context, _campo.text.trim()),
          child: Text(widget.longe ? 'Já entreguei' : 'Concluir'),
        ),
      ],
    );
  }
}
