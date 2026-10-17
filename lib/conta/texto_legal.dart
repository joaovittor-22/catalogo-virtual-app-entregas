import 'package:flutter/material.dart';

import '../core/tema.dart';

/// Um pedaço de texto de um parágrafo: normal, negrito ou um dado ainda por preencher.
class TrechoLegal {
  const TrechoLegal(this.texto, {this.negrito = false, this.pendente = false});

  final String texto;
  final bool negrito;
  final bool pendente;

  @override
  bool operator ==(Object other) =>
      other is TrechoLegal &&
      other.texto == texto &&
      other.negrito == negrito &&
      other.pendente == pendente;

  @override
  int get hashCode => Object.hash(texto, negrito, pendente);

  @override
  String toString() =>
      'TrechoLegal($texto${negrito ? ', negrito' : ''}${pendente ? ', pendente' : ''})';
}

enum TipoBloco { titulo, paragrafo, lista }

class BlocoLegal {
  const BlocoLegal(this.tipo, this.linhas);

  final TipoBloco tipo;

  /// Uma linha para título e parágrafo; um item por linha na lista.
  final List<List<TrechoLegal>> linhas;
}

final _marcacao = RegExp(r'\*\*(.+?)\*\*|\[PREENCHER:[^\]]*\]');

/// Os termos são escritos num Markdown mínimo (`##`, `- ` e `**negrito**`), o mesmo do painel.
/// O app desenha com widgets, sem interpretar HTML nem nada além disso.
List<TrechoLegal> lerTrechos(String texto, {bool negrito = false}) {
  final trechos = <TrechoLegal>[];
  var ultimo = 0;
  for (final m in _marcacao.allMatches(texto)) {
    if (m.start > ultimo) {
      trechos.add(TrechoLegal(texto.substring(ultimo, m.start), negrito: negrito));
    }
    final dentro = m.group(1);
    if (dentro != null) {
      trechos.addAll(lerTrechos(dentro, negrito: true));
    } else {
      trechos.add(TrechoLegal(m.group(0)!, negrito: negrito, pendente: true));
    }
    ultimo = m.end;
  }
  if (ultimo < texto.length) trechos.add(TrechoLegal(texto.substring(ultimo), negrito: negrito));
  return trechos;
}

List<BlocoLegal> lerTextoLegal(String texto) {
  final blocos = <BlocoLegal>[];
  var paragrafo = <String>[];
  void fechar() {
    if (paragrafo.isNotEmpty) {
      blocos.add(BlocoLegal(TipoBloco.paragrafo, [lerTrechos(paragrafo.join(' '))]));
    }
    paragrafo = [];
  }

  for (final bruta in texto.replaceAll('\r\n', '\n').split('\n')) {
    final linha = bruta.trim();
    final titulo = RegExp(r'^#{2,3}\s+(.*)$').firstMatch(linha);
    final item = RegExp(r'^[-*]\s+(.*)$').firstMatch(linha);
    if (linha.isEmpty) {
      fechar();
    } else if (titulo != null) {
      fechar();
      blocos.add(BlocoLegal(TipoBloco.titulo, [lerTrechos(titulo.group(1)!)]));
    } else if (item != null) {
      fechar();
      final itemLido = lerTrechos(item.group(1)!);
      if (blocos.isNotEmpty && blocos.last.tipo == TipoBloco.lista) {
        blocos.last.linhas.add(itemLido);
      } else {
        blocos.add(BlocoLegal(TipoBloco.lista, [itemLido]));
      }
    } else {
      paragrafo.add(linha);
    }
  }
  fechar();
  return blocos;
}

/// O texto legal na tela, com letra grande e boa leitura.
class TextoLegal extends StatelessWidget {
  const TextoLegal({super.key, required this.texto});

  final String texto;

  TextSpan _span(List<TrechoLegal> trechos) => TextSpan(
    children: [
      for (final t in trechos)
        TextSpan(
          text: t.texto,
          style: TextStyle(
            fontWeight: t.negrito ? FontWeight.w800 : null,
            backgroundColor: t.pendente ? Cores.destaque.withValues(alpha: 0.35) : null,
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    const base = TextStyle(fontSize: 16, height: 1.45, color: Cores.texto);
    return Column(
      key: const Key('texto-legal'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final bloco in lerTextoLegal(texto))
          Padding(
            padding: EdgeInsets.only(top: bloco.tipo == TipoBloco.titulo ? 18 : 8),
            child: switch (bloco.tipo) {
              TipoBloco.titulo => Semantics(
                header: true,
                child: Text.rich(
                  _span(bloco.linhas.first),
                  style: base.copyWith(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              TipoBloco.paragrafo => Text.rich(_span(bloco.linhas.first), style: base),
              TipoBloco.lista => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in bloco.linhas)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(left: 4, right: 10),
                            child: Text('•', style: base),
                          ),
                          Expanded(child: Text.rich(_span(item), style: base)),
                        ],
                      ),
                    ),
                ],
              ),
            },
          ),
      ],
    );
  }
}
