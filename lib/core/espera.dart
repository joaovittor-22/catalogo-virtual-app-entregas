import 'dart:math';

/// Quanto esperar antes de tentar de novo depois de uma falha de rede.
///
/// A espera dobra a cada falha seguida, ate [maximo], e metade dela e
/// sorteada: assim os aparelhos de uma loja nao voltam todos no mesmo segundo
/// quando a rede (ou a API) volta. Um sucesso zera a conta.
class Espera {
  Espera({required this.base, required this.maximo, Random? sorteio})
    : _sorteio = sorteio ?? Random();

  final Duration base;
  final Duration maximo;
  final Random _sorteio;

  int _falhas = 0;

  int get falhas => _falhas;

  /// Registra mais uma falha e devolve quanto esperar ate a proxima tentativa.
  Duration depoisDeFalhar() {
    _falhas++;
    final teto = min(base.inMilliseconds * pow(2, _falhas - 1), maximo.inMilliseconds).round();
    return Duration(milliseconds: teto ~/ 2 + _sorteio.nextInt(teto ~/ 2 + 1));
  }

  void zerar() => _falhas = 0;
}
