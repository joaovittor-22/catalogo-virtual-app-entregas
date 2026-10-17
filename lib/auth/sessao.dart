/// Quem esta logado e em qual loja.
class Sessao {
  const Sessao({
    required this.token,
    required this.entregadorNome,
    required this.entregadorCodigo,
    required this.lojaNome,
    required this.expiraEm,
  });

  final String token;
  final String entregadorNome;
  final String entregadorCodigo;
  final String lojaNome;
  final DateTime expiraEm;

  bool get expirada => DateTime.now().isAfter(expiraEm);

  factory Sessao.daResposta(Map<String, dynamic> json) {
    final entregador = json['entregador'] as Map<String, dynamic>;
    final loja = json['loja'] as Map<String, dynamic>;
    return Sessao(
      token: json['token'] as String,
      entregadorNome: entregador['nome'] as String? ?? '',
      entregadorCodigo: entregador['codigo'] as String? ?? '',
      lojaNome: loja['nome'] as String? ?? '',
      expiraEm: DateTime.now().add(Duration(milliseconds: (json['expiraEmMs'] as num).toInt())),
    );
  }

  Map<String, dynamic> toJson() => {
    'token': token,
    'entregadorNome': entregadorNome,
    'entregadorCodigo': entregadorCodigo,
    'lojaNome': lojaNome,
    'expiraEm': expiraEm.toIso8601String(),
  };

  factory Sessao.fromJson(Map<String, dynamic> json) => Sessao(
    token: json['token'] as String,
    entregadorNome: json['entregadorNome'] as String? ?? '',
    entregadorCodigo: json['entregadorCodigo'] as String? ?? '',
    lojaNome: json['lojaNome'] as String? ?? '',
    expiraEm: DateTime.parse(json['expiraEm'] as String),
  );
}
