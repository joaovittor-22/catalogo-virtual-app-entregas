/// Quem esta logado e em qual loja.
class Sessao {
  const Sessao({
    required this.token,
    required this.entregadorNome,
    required this.entregadorCodigo,
    required this.lojaNome,
    required this.expiraEm,
    this.lojaCodigo = '',
  });

  final String token;
  final String entregadorNome;
  final String entregadorCodigo;
  final String lojaNome;
  final DateTime expiraEm;

  /// Codigo da empresa que o entregador digita no login.
  final String lojaCodigo;

  bool get expirada => DateTime.now().isAfter(expiraEm);

  /// A quem pertence o que fica guardado no aparelho (fila, corrida, acoes por
  /// enviar). Nao muda quando o token e renovado: depois de entrar de novo, o
  /// que ficou pendente segue para a API.
  String get dono => '$lojaCodigo/$entregadorCodigo';

  factory Sessao.daResposta(Map<String, dynamic> json) {
    final entregador = json['entregador'] as Map<String, dynamic>;
    final loja = json['loja'] as Map<String, dynamic>;
    return Sessao(
      token: json['token'] as String,
      entregadorNome: entregador['nome'] as String? ?? '',
      entregadorCodigo: entregador['codigo'] as String? ?? '',
      lojaNome: loja['nome'] as String? ?? '',
      lojaCodigo: loja['codigo'] as String? ?? loja['slug'] as String? ?? '',
      expiraEm: DateTime.now().add(Duration(milliseconds: (json['expiraEmMs'] as num).toInt())),
    );
  }

  Map<String, dynamic> toJson() => {
    'token': token,
    'entregadorNome': entregadorNome,
    'entregadorCodigo': entregadorCodigo,
    'lojaNome': lojaNome,
    'lojaCodigo': lojaCodigo,
    'expiraEm': expiraEm.toIso8601String(),
  };

  factory Sessao.fromJson(Map<String, dynamic> json) => Sessao(
    token: json['token'] as String,
    entregadorNome: json['entregadorNome'] as String? ?? '',
    entregadorCodigo: json['entregadorCodigo'] as String? ?? '',
    lojaNome: json['lojaNome'] as String? ?? '',
    lojaCodigo: json['lojaCodigo'] as String? ?? '',
    expiraEm: DateTime.parse(json['expiraEm'] as String),
  );
}
