/// El partido: formaciones, cronómetro y lo que sobrevive a cerrar la app.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Los dorsales en el orden en que se leen, que es lo que cambia al cambiar de
/// formación.
List<int> numbers(List<PlayerSlot> lineup) =>
    lineup.map((PlayerSlot s) => s.player.number).toList();

List<String> positions(List<PlayerSlot> lineup) =>
    lineup.map((PlayerSlot s) => s.position).toList();

void main() {
  group('formaciones', () {
    test('cada formación coloca a los mismos once en otro orden', () {
      final MatchState match = MatchState();

      final List<int> threeFour = numbers(match.visibleLineup);
      match.setFormation('3-5-2');
      final List<int> threeFive = numbers(match.visibleLineup);

      expect(threeFour.toSet(), threeFive.toSet(), reason: 'son los mismos jugadores');
      expect(threeFour, isNot(threeFive), reason: 'pero no en el mismo orden');
      match.dispose();
    });

    test('el 4-3-3 se lee de atrás adelante: el pivote antes que el interior', () {
      // El diseño pone el 4-3-3 local con el interior primero y el visitante con el
      // pivote primero. Una sola regla no puede dar las dos; esta es la de las otras
      // cinco tablas.
      final MatchState match = MatchState();

      expect(numbers(match.visibleLineup), <int>[1, 2, 4, 5, 3, 6, 8, 10, 7, 9, 11]);
      expect(positions(match.visibleLineup), <String>[
        'POR',
        'LTD',
        'DFC',
        'DFC',
        'LTI',
        'MCD',
        'MC',
        'MCO',
        'ED',
        'DC',
        'EI',
      ]);
      match.dispose();
    });

    test('el 4-3-3 visitante sale como en el diseño', () {
      final MatchState match = MatchState()..showLineup(MatchTeam.away);

      expect(numbers(match.visibleLineup), <int>[1, 2, 5, 6, 3, 8, 10, 7, 11, 9, 19]);
      match.dispose();
    });

    test('el 4-4-2 baja al extremo a la banda y sube al mediapunta', () {
      final MatchState match = MatchState()..setFormation('4-4-2');

      expect(numbers(match.visibleLineup), <int>[1, 2, 4, 5, 3, 7, 6, 8, 11, 9, 10]);
      expect(positions(match.visibleLineup), <String>[
        'POR',
        'LTD',
        'DFC',
        'DFC',
        'LTI',
        'MD',
        'MC',
        'MC',
        'MI',
        'DC',
        'DC',
      ]);
      match.dispose();
    });

    test('el 3-5-2 mete al lateral izquierdo dentro y hace carrilero al derecho', () {
      final MatchState match = MatchState()..setFormation('3-5-2');

      expect(numbers(match.visibleLineup), <int>[1, 4, 5, 3, 2, 6, 8, 10, 11, 9, 7]);
      expect(positions(match.visibleLineup), <String>[
        'POR',
        'DFC',
        'DFC',
        'DFC',
        'CAD',
        'MCD',
        'MC',
        'MCO',
        'CAI',
        'DC',
        'DC',
      ]);
      match.dispose();
    });

    test('la visita se coloca con la misma regla', () {
      final MatchState match = MatchState()
        ..showLineup(MatchTeam.away)
        ..setFormation('3-5-2');

      expect(numbers(match.visibleLineup), <int>[1, 5, 6, 3, 2, 8, 10, 7, 19, 9, 11]);

      match.setFormation('4-4-2');
      expect(numbers(match.visibleLineup), <int>[1, 2, 5, 6, 3, 11, 8, 10, 19, 9, 7]);
      match.dispose();
    });

    test('cada equipo recuerda su propia formación', () {
      final MatchState match = MatchState()
        ..setFormation('4-4-2')
        ..showLineup(MatchTeam.away);

      expect(match.visibleFormation, '4-3-3');

      match.showLineup(MatchTeam.home);
      expect(match.visibleFormation, '4-4-2');
      match.dispose();
    });

    test('una plantilla que no encaja sigue dando once y no revienta', () {
      // Las alineaciones acabarán viniendo del servidor, y allí nadie garantiza que
      // haya exactamente un portero y dos centrales.
      final List<Player> odd = List<Player>.generate(
        11,
        (int i) => Player(number: i + 1, name: 'Jugador $i', role: PlayerRole.cm),
      );
      final MatchState match = MatchState(homeSquad: odd);

      expect(match.visibleLineup, hasLength(11));
      match.dispose();
    });
  });

  group('marcador', () {
    test('no baja de cero', () {
      final MatchState match = MatchState()..addGoal(MatchTeam.home, -1);

      expect(match.homeGoals, 0);
      match.dispose();
    });

    test('reiniciar pone los dos a cero', () {
      final MatchState match = MatchState()
        ..addGoal(MatchTeam.home, 3)
        ..addGoal(MatchTeam.away, 1)
        ..resetScore();

      expect(match.homeGoals, 0);
      expect(match.awayGoals, 0);
      match.dispose();
    });
  });

  group('cronómetro', () {
    test('arranca parado y en cero', () {
      final MatchState match = MatchState();

      expect(match.running, isFalse);
      expect(match.elapsed, Duration.zero);
      match.dispose();
    });

    test('±1 min corrige en minutos enteros y nunca por debajo de cero', () {
      final MatchState match = MatchState()..nudgeClock(3);
      expect(match.elapsed, const Duration(minutes: 3));

      match.nudgeClock(-10);
      expect(match.elapsed, Duration.zero);
      match.dispose();
    });

    test('parar no se come la fracción de segundo que llevaba', () async {
      // Guardar segundos enteros al parar perdía hasta 1 s por pausa; tras varias, el
      // reloj del overlay iba por detrás del del árbitro.
      final MatchState match = MatchState()..startClock();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      match.stopClock();

      expect(match.elapsed.inMilliseconds, greaterThanOrEqualTo(300));
      match.dispose();
    });

    test('reiniciar lo para además de ponerlo a cero', () {
      final MatchState match = MatchState()
        ..startClock()
        ..nudgeClock(5)
        ..resetClock();

      expect(match.running, isFalse);
      expect(match.elapsed, Duration.zero);
      match.dispose();
    });
  });

  group('persistencia', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('cerrar la app en el descanso no borra el marcador', () async {
      final MatchState first = MatchState();
      await first.load();
      first
        ..addGoal(MatchTeam.home, 2)
        ..addGoal(MatchTeam.away, 1)
        ..nudgeClock(45)
        ..setFormation('4-4-2');
      // `_save` no se espera dentro del setter; se deja correr la microtarea.
      await Future<void>.delayed(Duration.zero);
      first.dispose();

      final MatchState second = MatchState();
      await second.load();

      expect(second.homeGoals, 2);
      expect(second.awayGoals, 1);
      expect(second.elapsed, const Duration(minutes: 45));
      expect(second.homeFormation, '4-4-2');
      second.dispose();
    });

    test('lo que se toca antes de terminar de cargar gana a lo guardado', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{matchStateKey: '{"homeGoals": 3}'});
      final MatchState match = MatchState();

      final Future<void> loading = match.load();
      match.addGoal(MatchTeam.away, 1);
      await loading;

      expect(match.homeGoals, 0);
      expect(match.awayGoals, 1);
      match.dispose();
    });

    test('cerrar la pantalla mientras carga no deja un temporizador vivo', () async {
      // `ZeroShell` no espera a la carga. Si arrancara el temporizador del reloj sobre
      // un objeto ya liberado, cada segundo lanzaría un aviso durante toda la vida de
      // la app.
      SharedPreferences.setMockInitialValues(<String, Object>{
        matchStateKey: '{"runningSinceMs": ${DateTime.now().millisecondsSinceEpoch}}',
      });
      final MatchState match = MatchState();

      final Future<void> loading = match.load();
      match.dispose();

      await expectLater(loading, completes);
    });

    test('una plantilla guardada ilegible no deja el reloj a medio cargar', () async {
      // Aplicar campo a campo y fallar en la plantilla dejaba el reloj «en marcha» sin
      // temporizador. O se carga todo, o nada.
      SharedPreferences.setMockInitialValues(<String, Object>{
        matchStateKey:
            '{"homeGoals": 2, "runningSinceMs": 1, '
            '"homeSquad": [{"number": 1, "name": "X", "role": "libero"}]}',
      });
      final MatchState match = MatchState();

      await match.load();

      expect(match.running, isFalse);
      expect(match.homeGoals, 0);
      match.dispose();
    });

    test('un estado guardado ilegible no impide empezar el partido', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{matchStateKey: 'esto no es json'});
      final MatchState match = MatchState();

      await match.load();

      expect(match.homeGoals, 0);
      expect(match.visibleLineup, hasLength(11));
      match.dispose();
    });
  });

  group('lo que sale al aire', () {
    test('el JSON del overlay lleva las dos alineaciones ya colocadas', () {
      final MatchState match = MatchState()
        ..addGoal(MatchTeam.home, 1)
        ..setFormation('4-4-2');

      final Map<String, Object?> json = match.toOverlayJson();
      final Map<String, Object?> home = json['home']! as Map<String, Object?>;

      expect(home['goals'], 1);
      expect(home['formation'], '4-4-2');
      expect(home['lineup'], hasLength(11));
      expect(json['onAir'], isFalse);
      match.dispose();
    });
  });
}
