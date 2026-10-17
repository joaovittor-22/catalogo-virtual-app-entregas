import 'dart:math' as math;

/// Coordenada em graus.
class Ponto {
  const Ponto(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  @override
  bool operator ==(Object other) =>
      other is Ponto && other.latitude == latitude && other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  String toString() => 'Ponto($latitude, $longitude)';
}

const double _raioTerraM = 6371000;
double _rad(double graus) => graus * math.pi / 180;

/// Distancia em linha reta (haversine), em metros.
double distanciaM(Ponto a, Ponto b) {
  final lat1 = _rad(a.latitude);
  final lat2 = _rad(b.latitude);
  final dLat = lat2 - lat1;
  final dLng = _rad(b.longitude - a.longitude);
  final h =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dLng / 2), 2);
  return _raioTerraM * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
}

/// Resultado de encaixar um ponto na rota.
class Encaixe {
  const Encaixe(this.ponto, this.distanciaM, this.trecho);

  /// Ponto da rota mais proximo.
  final Ponto ponto;

  /// Quanto o ponto original estava longe da rota.
  final double distanciaM;

  /// Indice do trecho da rota onde caiu.
  final int trecho;
}

/// Ponto da [rota] mais proximo de [p]. Projeta num plano local, o que e
/// exato o bastante nas distancias de uma entrega.
Encaixe? encaixarNaRota(Ponto p, List<Ponto> rota) {
  if (rota.length < 2) return null;
  final mPorLng = math.pi / 180 * _raioTerraM * math.cos(_rad(p.latitude));
  const mPorLat = math.pi / 180 * _raioTerraM;
  Encaixe? melhor;
  for (var i = 0; i < rota.length - 1; i++) {
    final ax = (rota[i].longitude - p.longitude) * mPorLng;
    final ay = (rota[i].latitude - p.latitude) * mPorLat;
    final bx = (rota[i + 1].longitude - p.longitude) * mPorLng;
    final by = (rota[i + 1].latitude - p.latitude) * mPorLat;
    final dx = bx - ax;
    final dy = by - ay;
    final comprimento2 = dx * dx + dy * dy;
    // O ponto esta na origem do plano: projeta a origem no trecho.
    final t = comprimento2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / comprimento2).clamp(0.0, 1.0);
    final distancia = math.sqrt(math.pow(ax + dx * t, 2) + math.pow(ay + dy * t, 2));
    if (melhor == null || distancia < melhor.distanciaM) {
      melhor = Encaixe(
        Ponto(
          rota[i].latitude + (rota[i + 1].latitude - rota[i].latitude) * t,
          rota[i].longitude + (rota[i + 1].longitude - rota[i].longitude) * t,
        ),
        distancia.toDouble(),
        i,
      );
    }
  }
  return melhor;
}
