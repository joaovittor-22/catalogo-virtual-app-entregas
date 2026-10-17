import '../core/geo.dart';

double? _numero(dynamic valor) => valor is num ? valor.toDouble() : null;

class ItemCorrida {
  const ItemCorrida({
    required this.qtd,
    required this.nome,
    required this.adicionais,
    this.observacao,
  });

  final int qtd;
  final String nome;
  final List<String> adicionais;
  final String? observacao;

  factory ItemCorrida.fromJson(Map<String, dynamic> json) => ItemCorrida(
    qtd: (json['qtd'] as num?)?.toInt() ?? 1,
    nome: json['nome'] as String? ?? '',
    adicionais: [for (final a in json['adicionais'] as List? ?? const []) a.toString()],
    observacao: json['observacao'] as String?,
  );
}

/// Entrega em andamento (ou ja encerrada), com tudo que o entregador precisa.
class Corrida {
  const Corrida({
    required this.id,
    required this.status,
    required this.numero,
    required this.clienteNome,
    required this.itens,
    required this.total,
    required this.raioChegadaM,
    this.clienteTelefone,
    this.enderecoCompleto,
    this.referencia,
    this.destino,
    this.formaPagamento,
    this.trocoPara,
    this.observacao,
    this.temComprovante = false,
    this.comprovanteEm,
  });

  final int id;

  /// em_rota, entregue ou devolvida.
  final String status;
  final String numero;
  final String clienteNome;

  /// So vem com a corrida em andamento.
  final String? clienteTelefone;
  final String? enderecoCompleto;
  final String? referencia;

  /// Nulo quando o endereco nao pode ser localizado no mapa.
  final Ponto? destino;
  final String? formaPagamento;
  final double? trocoPara;
  final double total;
  final String? observacao;
  final List<ItemCorrida> itens;

  /// A que distancia do destino o app libera "Concluir entrega".
  final double raioChegadaM;

  /// Foto do comprovante de pagamento (opcional) ja enviada.
  final bool temComprovante;
  final DateTime? comprovanteEm;

  bool get emRota => status == 'em_rota';

  factory Corrida.fromJson(Map<String, dynamic> json) {
    final latitude = _numero(json['latitude']);
    final longitude = _numero(json['longitude']);
    return Corrida(
      id: (json['id'] as num).toInt(),
      status: json['status'] as String? ?? '',
      numero: json['numero'] as String? ?? '',
      clienteNome: json['clienteNome'] as String? ?? 'Cliente',
      clienteTelefone: json['clienteTelefone'] as String?,
      enderecoCompleto: json['enderecoCompleto'] as String?,
      referencia: json['referencia'] as String?,
      destino: latitude == null || longitude == null ? null : Ponto(latitude, longitude),
      formaPagamento: json['formaPagamento'] as String?,
      trocoPara: _numero(json['trocoPara']),
      total: _numero(json['total']) ?? 0,
      observacao: json['observacao'] as String?,
      itens: [
        for (final item in json['itens'] as List? ?? const [])
          ItemCorrida.fromJson(item as Map<String, dynamic>),
      ],
      raioChegadaM: _numero(json['raioChegadaM']) ?? 150,
      temComprovante: json['temComprovante'] as bool? ?? false,
      comprovanteEm: DateTime.tryParse(json['comprovanteEm'] as String? ?? ''),
    );
  }
}
