/// Formatacao para a tela. Sem o pacote intl: sao poucos casos e fixos.
String moeda(num? valor) {
  final centavos = ((valor ?? 0) * 100).round();
  final negativo = centavos < 0;
  final inteiro = (centavos.abs() ~/ 100).toString();
  final fracao = (centavos.abs() % 100).toString().padLeft(2, '0');
  final milhar = StringBuffer();
  for (var i = 0; i < inteiro.length; i++) {
    if (i > 0 && (inteiro.length - i) % 3 == 0) milhar.write('.');
    milhar.write(inteiro[i]);
  }
  return '${negativo ? '-' : ''}R\$ $milhar,$fracao';
}

String distancia(double metros) {
  if (metros < 950) return '${(metros / 10).round() * 10} m';
  return '${(metros / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
}

String duracao(double segundos) {
  final minutos = (segundos / 60).round();
  if (minutos < 1) return 'menos de 1 min';
  if (minutos < 60) return '$minutos min';
  return '${minutos ~/ 60} h ${minutos % 60} min';
}

String pagamento(String? tipo) {
  switch (tipo?.toLowerCase()) {
    case 'pix':
      return 'Pix';
    case 'credito':
      return 'Cartão de crédito';
    case 'debito':
      return 'Cartão de débito';
    case 'dinheiro':
      return 'Dinheiro';
    default:
      return tipo ?? '—';
  }
}

String hora(DateTime? momento) {
  if (momento == null) return '—';
  final local = momento.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

/// So os digitos, com o DDI do Brasil, como o WhatsApp e o discador esperam.
String telefoneInternacional(String telefone) {
  final digitos = telefone.replaceAll(RegExp(r'\D'), '');
  return digitos.length <= 11 ? '55$digitos' : digitos;
}
