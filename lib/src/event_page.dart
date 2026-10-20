/// Lo primero que enseña la app: qué se va a transmitir (ADR 0031 del repo football-ai).
///
/// El tipo de evento decide todo lo demás. El fútbol lleva a la pantalla de siempre (el lado,
/// el enlace entre los dos móviles, el servidor, el VPS y «Solo mando»). El espectáculo y el
/// vóleibol van con una sola cámara: su pantalla solo pide la calidad y el VPS. Elegirlo antes
/// que nada es lo que evita configurar dos móviles para un festival.
library;

import 'package:flutter/material.dart';

import 'package:football_ai_capture/src/event_kind.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/mando_page.dart' show PanelControlFactory;
import 'package:football_ai_capture/src/role_page.dart';
import 'package:football_ai_capture/src/theme/zero_colors.dart';
import 'package:football_ai_capture/src/theme/zero_mark.dart';
import 'package:football_ai_capture/src/theme/zero_metrics.dart';
import 'package:football_ai_capture/src/theme/zero_type.dart';
import 'package:football_ai_capture/src/widgets/zero_widgets.dart';

class EventPage extends StatelessWidget {
  const EventPage({this.api, this.mandoControl, this.clockS, super.key});

  /// Inyectables para los tests: pasan tal cual a la pantalla de cada evento.
  final CaptureHostApi? api;
  final PanelControlFactory? mandoControl;
  final int Function()? clockS;

  /// Lo que dice cada bloque debajo de su nombre: qué cámara y qué gráfico trae.
  static const Map<EventKind, String> notes = <EventKind, String>{
    EventKind.football: 'UNO O DOS MÓVILES · MARCADOR, RELOJ, JORNADA Y RESULTADOS',
    EventKind.show: 'UNA CÁMARA · EN VIVO, RÓTULOS, FRANJAS Y VÍDEOS',
    EventKind.volleyball: 'UNA CÁMARA · SIN GRÁFICOS POR AHORA',
  };

  void _open(BuildContext context, EventKind kind) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RolePage(api: api, mandoControl: mandoControl, clockS: clockS, eventKind: kind),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        minimum: const EdgeInsets.only(bottom: 34),
        child: CustomScrollView(
          slivers: <Widget>[
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: ZeroMetrics.gutter),
              sliver: SliverFillRemaining(
                hasScrollBody: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 14, 0, 26),
                      child: Row(
                        children: <Widget>[
                          const ZeroLockup(diameter: 22),
                          const Spacer(),
                          Text(
                            'EVENTO',
                            style: ZeroType.data(
                              size: 10,
                              weight: FontWeight.w500,
                              color: ZeroColors.inkTertiary,
                              letterSpacing: 1.6,
                              height: 1.0,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '¿Qué vas a transmitir?',
                      style: ZeroType.archivo(
                        size: 30,
                        weight: FontWeight.w600,
                        color: ZeroColors.ink,
                        letterSpacing: -1.05,
                        height: 1.08,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Cada evento trae su cámara y sus gráficos.',
                      style: ZeroType.plex(
                        size: 14,
                        weight: FontWeight.w400,
                        color: ZeroColors.inkTertiary,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 22),
                    for (final EventKind kind in EventKind.values) ...<Widget>[
                      if (kind != EventKind.values.first) const SizedBox(height: 12),
                      _EventBlock(
                        label: kind.label.toUpperCase(),
                        note: notes[kind]!,
                        onTap: () => _open(context, kind),
                      ),
                    ],
                    const Spacer(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Un tipo de evento: el nombre grande y debajo lo que trae. Alto mínimo 96, como los
/// bloques de lado: es el primer toque de la app y no se puede fallar.
class _EventBlock extends StatelessWidget {
  const _EventBlock({required this.label, required this.note, required this.onTap});

  final String label;
  final String note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: ZeroTappable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        decoration: BoxDecoration(
          color: ZeroColors.surface,
          border: Border.all(color: ZeroColors.outline),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Container(
          constraints: const BoxConstraints(minHeight: 96),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      label,
                      style: ZeroType.plex(
                        size: 17,
                        weight: FontWeight.w700,
                        color: ZeroColors.ink,
                        letterSpacing: 0.9,
                        height: 1.0,
                      ),
                    ),
                    const SizedBox(height: 9),
                    Text(
                      note,
                      style: ZeroType.data(
                        size: 11,
                        weight: FontWeight.w400,
                        color: ZeroColors.inkSecondary,
                        letterSpacing: 1.1,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              // La flecha de seguir, en el acento: el bloque entero es el botón.
              Text(
                '›',
                style: ZeroType.archivo(size: 30, weight: FontWeight.w500, color: ZeroColors.accent, height: 1.0),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
