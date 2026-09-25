/// Marcador, cronómetro y posiciones: los mismos controles del panel de emisión web,
/// escalados al pulgar.
///
/// La diferencia con el panel no es de aspecto sino de tamaño: allí se usa con ratón y
/// sentado, y aquí de pie, con sol y mirando el campo más que la pantalla. Por eso todo
/// lo que se pulsa mide 46 o 50 px de alto, el cronómetro es la cifra más grande de la
/// app, y la tira de arriba enseña exactamente lo que sale al aire, para no tener que
/// preguntarle a nadie si el marcador ya cambió.
library;

import 'package:flutter/material.dart';

import 'package:football_ai_capture/src/capture_labels.dart' show formatClock;
import 'package:football_ai_capture/src/match_board.dart';
import 'package:football_ai_capture/src/match_state.dart';
import 'package:football_ai_capture/src/theme/zero_colors.dart';
import 'package:football_ai_capture/src/theme/zero_mark.dart';
import 'package:football_ai_capture/src/theme/zero_metrics.dart';
import 'package:football_ai_capture/src/theme/zero_type.dart';
import 'package:football_ai_capture/src/widgets/zero_widgets.dart';

class MatchPage extends StatefulWidget {
  const MatchPage({required this.match, this.destinations = 0, this.banner, super.key});

  /// El partido que se enseña y se opera: el de este móvil o el del panel (`match_board.dart`).
  final MatchBoard match;

  /// Lo que va justo debajo de la cabecera, si hay algo que avisar: el mando lo usa para
  /// decir que el panel no contesta o que la transmisión terminó.
  final Widget? banner;

  /// Cuántos destinos hay configurados. Sale de lo que se eligió en la pantalla de
  /// lado, no de un número escrito aquí: decir «2 destinos» cuando no hay ninguno es
  /// peor que no tener la línea.
  final int destinations;

  @override
  State<MatchPage> createState() => _MatchPageState();
}

class _MatchPageState extends State<MatchPage> {
  @override
  void initState() {
    super.initState();
    widget.match.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.match.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final MatchBoard m = widget.match;
    final Widget? banner = widget.banner;
    return SafeArea(
      bottom: false,
      child: Column(
        children: <Widget>[
          _MatchHeader(onAir: m.streaming),
          ?banner,
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(ZeroMetrics.gutter, 14, ZeroMetrics.gutter, 28),
              children: <Widget>[
                _ScoreboardStrip(match: m),
                const SizedBox(height: 9),
                Text(
                  'así se ve en la emisión',
                  textAlign: TextAlign.center,
                  style: ZeroType.data(
                    size: 11,
                    weight: FontWeight.w400,
                    color: ZeroColors.inkTertiary,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                _ClockCard(match: m),
                const SizedBox(height: ZeroMetrics.cardGap),
                _ScoreCard(match: m),
                const SizedBox(height: ZeroMetrics.cardGap),
                _LineupCard(match: m),
                const SizedBox(height: ZeroMetrics.cardGap),
                _OnAirCard(match: m, destinations: widget.destinations),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MatchHeader extends StatelessWidget {
  const _MatchHeader({required this.onAir});

  final bool onAir;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: ZeroMetrics.gutter, vertical: 12),
      decoration: const BoxDecoration(
        color: ZeroColors.chromeFill,
        border: Border(bottom: BorderSide(color: ZeroColors.chrome)),
      ),
      child: Row(
        children: <Widget>[
          const ZeroMark(diameter: 18),
          const SizedBox(width: 10),
          Text(
            'Partido',
            style: ZeroType.archivo(
              size: 15,
              weight: FontWeight.w600,
              color: ZeroColors.ink,
              letterSpacing: -0.3,
              height: 1.0,
            ),
          ),
          const Spacer(),
          if (onAir)
            const ZeroChip(
              'AL AIRE',
              background: ZeroColors.onAirChip,
              border: ZeroColors.dangerStrong,
              foreground: ZeroColors.alarm,
            )
          else
            const ZeroChip.muted('FUERA DEL AIRE'),
        ],
      ),
    );
  }
}

/// La previsualización del overlay. No es un adorno: es lo que el público va a ver, y
/// verlo aquí es lo que evita descubrir en el minuto 70 que el marcador iba al revés.
class _ScoreboardStrip extends StatelessWidget {
  const _ScoreboardStrip({required this.match});

  final MatchBoard match;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(ZeroMetrics.fieldRadius),
      child: Container(
        decoration: BoxDecoration(
          color: ZeroColors.well,
          border: Border.all(color: ZeroColors.outlineSoft),
          borderRadius: BorderRadius.circular(ZeroMetrics.fieldRadius),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const _StripBar(color: ZeroColors.home),
              _StripName(match.homeName),
              _StripGoals(match.homeGoals),
              _StripClock(formatClock(match.elapsed)),
              _StripGoals(match.awayGoals),
              _StripName(match.awayName),
              const _StripBar(color: ZeroColors.accent),
            ],
          ),
        ),
      ),
    );
  }
}

class _StripBar extends StatelessWidget {
  const _StripBar({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(width: 5, child: ColoredBox(color: color));
}

class _StripName extends StatelessWidget {
  const _StripName(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 13),
        child: Center(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ZeroType.plex(
              size: 13,
              weight: FontWeight.w600,
              color: ZeroColors.white,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}

class _StripGoals extends StatelessWidget {
  const _StripGoals(this.goals);

  final int goals;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: ZeroColors.cellFill,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        child: Center(
          child: Text(
            '$goals',
            style: ZeroType.data(
              size: 16,
              weight: FontWeight.w700,
              color: ZeroColors.white,
              height: 1.0,
              tabularFigures: true,
            ),
          ),
        ),
      ),
    );
  }
}

class _StripClock extends StatelessWidget {
  const _StripClock(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: ZeroColors.accentChip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Center(
          child: Text(
            text,
            style: ZeroType.data(
              size: 15,
              weight: FontWeight.w600,
              color: ZeroColors.accentLight,
              height: 1.0,
              tabularFigures: true,
            ),
          ),
        ),
      ),
    );
  }
}

class _ClockCard extends StatelessWidget {
  const _ClockCard({required this.match});

  final MatchBoard match;

  @override
  Widget build(BuildContext context) {
    return ZeroCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ZeroSectionHeader(
            'Cronómetro',
            bottomGap: 10,
            trailing: Text(
              match.running ? 'EN MARCHA' : 'PARADO',
              style: ZeroType.data(
                size: 10,
                weight: FontWeight.w500,
                color: ZeroColors.inkTertiary,
                letterSpacing: 1.4,
                height: 1.0,
              ),
            ),
          ),
          Text(
            formatClock(match.elapsed),
            textAlign: TextAlign.center,
            // Tabular: sin esto, cada segundo cambia el ancho de la cifra y el
            // cronómetro entero tiembla a 58 px.
            style: ZeroType.archivo(
              size: 58,
              weight: FontWeight.w600,
              color: ZeroColors.ink,
              letterSpacing: -2.61,
              height: 1.0,
              tabularFigures: true,
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              Expanded(
                child: match.running
                    ? ZeroButton.destructive(
                        label: 'Parar',
                        onPressed: match.busy ? null : match.stopClock,
                      )
                    : ZeroButton.primary(
                        label: 'Iniciar',
                        onPressed: match.busy ? null : match.startClock,
                      ),
              ),
              const SizedBox(width: 8),
              ZeroButton.secondary(
                label: 'Reiniciar',
                onPressed: match.busy
                    ? null
                    : () => _confirmThen(
                        context,
                        match,
                        '¿Reiniciar el cronómetro a 00:00?',
                        match.resetClock,
                      ),
                height: ZeroMetrics.pillHeight,
                expand: false,
                textStyle: ZeroType.plex(
                  size: 14,
                  weight: FontWeight.w600,
                  color: ZeroColors.ink,
                  height: 1.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: _MinuteButton(
                  label: '−1 min',
                  onTap: match.busy ? null : () => match.nudgeClock(-1),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MinuteButton(
                  label: '+1 min',
                  onTap: match.busy ? null : () => match.nudgeClock(1),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Corregir el cronómetro es un dato, no una frase: va en monoespaciada.
class _MinuteButton extends StatelessWidget {
  const _MinuteButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ZeroButton.secondary(
      label: label,
      onPressed: onTap,
      height: ZeroMetrics.stepperSize,
      textStyle: ZeroType.data(
        size: 14,
        weight: FontWeight.w500,
        color: ZeroColors.ink,
        height: 1.0,
      ),
    );
  }
}

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.match});

  final MatchBoard match;

  @override
  Widget build(BuildContext context) {
    return ZeroCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const ZeroSectionHeader('Marcador'),
          _TeamScoreRow(
            name: match.homeName,
            goals: match.homeGoals,
            barColor: ZeroColors.home,
            plusFill: ZeroColors.homeFill,
            plusBorder: ZeroColors.homeStrong,
            plusInk: ZeroColors.homeLight,
            onPlus: match.busy ? null : () => match.addGoal(MatchTeam.home, 1),
            onMinus: match.busy ? null : () => match.addGoal(MatchTeam.home, -1),
          ),
          const Divider(height: 1, thickness: 1, color: ZeroColors.border),
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 16),
            child: _TeamScoreRow(
              name: match.awayName,
              goals: match.awayGoals,
              barColor: ZeroColors.accent,
              plusFill: ZeroColors.accentFill,
              plusBorder: ZeroColors.accentStrong,
              plusInk: ZeroColors.accentLight,
              onPlus: match.busy ? null : () => match.addGoal(MatchTeam.away, 1),
              onMinus: match.busy ? null : () => match.addGoal(MatchTeam.away, -1),
              padded: false,
            ),
          ),
          ZeroButton.secondary(
            label: 'Reiniciar marcador',
            onPressed: match.busy
                ? null
                : () => _confirmThen(
                    context,
                    match,
                    '¿Poner el marcador a 0-0?',
                    match.resetScore,
                  ),
            foreground: ZeroColors.inkSecondary,
            height: ZeroMetrics.stepperSize,
            textStyle: ZeroType.plex(
              size: 13,
              weight: FontWeight.w600,
              color: ZeroColors.inkSecondary,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

class _TeamScoreRow extends StatelessWidget {
  const _TeamScoreRow({
    required this.name,
    required this.goals,
    required this.barColor,
    required this.plusFill,
    required this.plusBorder,
    required this.plusInk,
    required this.onPlus,
    required this.onMinus,
    this.padded = true,
  });

  final String name;
  final int goals;
  final Color barColor;
  final Color plusFill;
  final Color plusBorder;
  final Color plusInk;
  final VoidCallback? onPlus;
  final VoidCallback? onMinus;
  final bool padded;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: padded ? 14 : 0),
      child: Row(
        children: <Widget>[
          Container(
            width: 5,
            height: 34,
            decoration: BoxDecoration(color: barColor, borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZeroType.plex(
                size: 15,
                weight: FontWeight.w600,
                color: ZeroColors.ink,
                height: 1.2,
              ),
            ),
          ),
          const SizedBox(width: 10),
          ZeroStepper(sign: '−', onTap: onMinus, semanticLabel: 'Un gol menos a $name'),
          SizedBox(
            width: 52,
            // `container` para que el marcador sea un nodo propio y no se lea de
            // corrido con el resto de la tarjeta: quien usa VoiceOver quiere el
            // resultado, no la tarjeta entera.
            child: Semantics(
              container: true,
              label: 'Goles de $name: $goals',
              excludeSemantics: true,
              child: Text(
                '$goals',
                textAlign: TextAlign.center,
                style: ZeroType.archivo(
                  size: 30,
                  weight: FontWeight.w700,
                  color: ZeroColors.ink,
                  letterSpacing: 0,
                  height: 1.0,
                  tabularFigures: true,
                ),
              ),
            ),
          ),
          ZeroStepper(
            sign: '+',
            onTap: onPlus,
            semanticLabel: 'Un gol más a $name',
            background: plusFill,
            border: plusBorder,
            foreground: plusInk,
          ),
        ],
      ),
    );
  }
}

/// Las once posiciones. Cambiar de formación **reordena** la lista y reasigna los
/// puestos: el lateral derecho pasa a carrilero en un 3-5-2 y sube en la lista, que es
/// lo que se comprueba de un vistazo antes de cantarlo por la radio.
class _LineupCard extends StatelessWidget {
  const _LineupCard({required this.match});

  final MatchBoard match;

  @override
  Widget build(BuildContext context) {
    final bool home = match.lineupTeam == MatchTeam.home;
    final Color teamFill = home ? ZeroColors.homeFill : ZeroColors.accentFill;
    final Color teamInk = home ? ZeroColors.homeLight : ZeroColors.accentLight;

    return ZeroCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ZeroSectionHeader(
            'Posiciones',
            trailing: Text(
              '${match.visibleTeamName} · ${match.visibleFormation}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZeroType.data(
                size: 11,
                weight: FontWeight.w400,
                color: ZeroColors.inkTertiary,
                height: 1.0,
              ),
            ),
          ),
          Row(
            children: <Widget>[
              ZeroPill(
                label: 'Local',
                selected: home,
                onTap: () => match.showLineup(MatchTeam.home),
              ),
              const SizedBox(width: 8),
              ZeroPill(
                label: 'Visita',
                selected: !home,
                onTap: () => match.showLineup(MatchTeam.away),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: <Widget>[
              for (final String f in match.formationNames)
                ZeroPill(
                  label: f,
                  selected: f == match.visibleFormation,
                  onTap: match.busy ? null : () => match.setFormation(f),
                  mono: true,
                  // El diseño las dibuja a 40; a 44, porque son tres objetivos
                  // separados 7 px que se aciertan de pie y sin mirar.
                  minHeight: ZeroMetrics.segmentHeight,
                  expand: false,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 2,
            children: <Widget>[
              for (final PlayerSlot slot in match.visibleLineup)
                _PlayerRow(slot: slot, fill: teamFill, ink: teamInk),
            ],
          ),
          if (match.lineupNote case final String note) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              note,
              style: ZeroType.data(
                size: 11,
                weight: FontWeight.w400,
                color: ZeroColors.inkTertiary,
                height: 1.6,
              ),
            ),
          ],
          // Sacarla al aire solo cuando el marcador tiene camino hasta la emisión: el
          // local no lo tiene, y un botón que no hace nada se lee como un fallo.
          if (match.visibleLineupOnAir case final bool onAir) ...<Widget>[
            const SizedBox(height: 14),
            if (onAir)
              ZeroButton.destructive(
                label: 'Quitar alineación del aire',
                onPressed: match.busy ? null : match.toggleLineupOnAir,
              )
            else
              ZeroButton.secondary(
                label: 'Sacar alineación al aire',
                onPressed: match.busy ? null : match.toggleLineupOnAir,
              ),
          ],
        ],
      ),
    );
  }
}

class _PlayerRow extends StatelessWidget {
  const _PlayerRow({required this.slot, required this.fill, required this.ink});

  final PlayerSlot slot;
  final Color fill;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: ZeroColors.border)),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(9)),
            child: Text(
              '${slot.player.number}',
              style: ZeroType.data(
                size: 11,
                weight: FontWeight.w600,
                color: ink,
                height: 1.0,
                tabularFigures: true,
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              slot.player.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZeroType.plex(
                size: 14,
                weight: FontWeight.w500,
                color: ZeroColors.ink,
                height: 1.0,
              ),
            ),
          ),
          const SizedBox(width: 11),
          Text(
            slot.position,
            style: ZeroType.data(
              size: 10,
              weight: FontWeight.w500,
              color: ZeroColors.inkTertiary,
              letterSpacing: 1.4,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

class _OnAirCard extends StatelessWidget {
  const _OnAirCard({required this.match, required this.destinations});

  final MatchBoard match;
  final int destinations;

  /// TODO: el diseño dice «marcador y alineación sobre la señal» al emitir. Hoy
  /// no hay camino por el que el marcador llegue al overlay —`MatchState.toOverlayJson`
  /// está listo y nadie lo envía—, así que la línea dice lo que de verdad pasa: la
  /// orden queda dada y guardada, pero todavía no sale. Afirmar que va sobre la señal
  /// haría que nadie lo comprobara en la emisión.
  String get _meta {
    if (destinations == 0) {
      return 'sin destino configurado · solo queda el fichero local';
    }
    final String plural = destinations == 1 ? 'destino' : 'destinos';
    final String configured = destinations == 1 ? 'configurado' : 'configurados';
    return match.streaming
        ? 'marcado para salir · el overlay todavía no se envía · $destinations $plural'
        : 'preparado · $destinations $plural $configured';
  }

  @override
  Widget build(BuildContext context) {
    return ZeroCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const ZeroSectionHeader('Salida al aire'),
          if (match.streaming)
            ZeroButton.destructive(
              label: 'Parar emisión',
              onPressed: match.busy || !match.canStream
                  ? null
                  : () => _confirmThen(
                      context,
                      match,
                      '¿Parar la emisión? El público deja de ver el partido.',
                      match.toggleStreaming,
                    ),
            )
          else
            ZeroButton.primary(
              label: 'Emitir',
              onPressed: match.busy || !match.canStream ? null : match.toggleStreaming,
            ),
          const SizedBox(height: 11),
          Text(
            match.onAirNote ?? _meta,
            style: ZeroType.data(
              size: 11,
              weight: FontWeight.w400,
              color: ZeroColors.inkTertiary,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// Hace `action`, preguntando antes si el marcador lo pide ([MatchBoard.confirmsDestructive]).
///
/// Con el mando, un toque de más en Reiniciar o en Parar emisión no se deshace desde la
/// banda: sale al aire. En el marcador local se hace sin preguntar, como siempre.
Future<void> _confirmThen(
  BuildContext context,
  MatchBoard match,
  String question,
  VoidCallback action,
) async {
  if (!match.confirmsDestructive) {
    action();
    return;
  }
  final bool? sure = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialog) => AlertDialog(
      content: Text(question),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('Cancelar')),
        TextButton(onPressed: () => Navigator.of(dialog).pop(true), child: const Text('Sí')),
      ],
    ),
  );
  if (sure ?? false) {
    action();
  }
}
