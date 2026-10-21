/// Elegir lado, servidor y modo. Es lo primero y lo único que no puede equivocarse.
///
/// Si los dos móviles dicen ser el izquierdo, el servidor recibe dos veces la misma
/// mitad del campo y el partido se pierde antes del saque inicial. Por eso los dos
/// bloques de lado son lo más grande de la pantalla y llevan escrito debajo qué implica
/// cada uno: el izquierdo es el maestro del reloj y puede arrancar solo, y el derecho
/// espera a tener reloj común (ADR 0012, decisión 2). Eso hasta hoy solo estaba en el
/// ADR, y quien monta el soporte no lee el ADR en la banda.
///
/// Es la pantalla del fútbol. El espectáculo y el vóleibol (ADR 0031) van con una cámara:
/// con ellos la misma pantalla solo pide la calidad y el VPS, y el móvil dirige siempre.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:football_ai_capture/src/constants.dart';
import 'package:football_ai_capture/src/event_kind.dart';
import 'package:football_ai_capture/src/generated/capture_api.g.dart';
import 'package:football_ai_capture/src/generated/rig_api.g.dart';
import 'package:football_ai_capture/src/mando_page.dart';
import 'package:football_ai_capture/src/panel_pairing.dart';
import 'package:football_ai_capture/src/theme/zero_colors.dart';
import 'package:football_ai_capture/src/theme/zero_mark.dart';
import 'package:football_ai_capture/src/theme/zero_metrics.dart';
import 'package:football_ai_capture/src/theme/zero_type.dart';
import 'package:football_ai_capture/src/vps_pairing.dart';
import 'package:football_ai_capture/src/widgets/zero_widgets.dart';
import 'package:football_ai_capture/src/zero_shell.dart';

/// De dónde salió lo que pone en «Servidor». Decide lo que dice la línea de debajo:
/// atribuir a Bonjour un nombre escrito a mano haría pasar una errata por un servidor
/// encontrado.
enum _ServerOrigin { none, saved, bonjour, typed, scanned }

class RolePage extends StatefulWidget {
  const RolePage({this.api, this.mandoControl, this.clockS, this.eventKind = EventKind.football, super.key});

  /// Lo que se va a transmitir (ADR 0031): el fútbol enseña todo; los demás, una cámara.
  final EventKind eventKind;

  /// Inyectable para los tests.
  final CaptureHostApi? api;

  /// El mando que abre «Solo mando». Inyectable para los tests, como [api].
  final PanelControlFactory? mandoControl;

  /// La hora de pared, en segundos, contra la que caduca el QR Soporte; sin ella,
  /// [wallClockS]. Para los tests.
  final int Function()? clockS;

  @override
  State<RolePage> createState() => _RolePageState();
}

class _RolePageState extends State<RolePage> {
  late final CaptureHostApi _api = widget.api ?? CaptureHostApi();
  final TextEditingController _server = TextEditingController();

  CameraRole _role = CameraRole.left;

  /// «Este móvil dirige» (IOS-80). Se guarda; si nunca se tocó, dirige el izquierdo.
  /// Solo decide al empezar un partido: durante el partido, cambiar de maestro es un
  /// relevo.
  bool? _prefersMaster;
  bool get _directs => _prefersMaster ?? _role == CameraRole.left;

  /// Apagado por defecto: encenderlo en un partido es grabar dos vídeos que no parean.
  bool _standalone = false;

  /// El enlace entre los dos móviles (IOS-58). Se guarda; sin nada, el Multipeer de
  /// siempre, con el que cada móvil emite al pod. Los otros tres son la arquitectura B.
  LinkMode _linkMode = LinkMode.multipeer;

  /// La resolución con «Una cámara (sin pareja)» (IOS-99, ADR 0025 de football-ai): lo
  /// único que se elige en ese modo. Se guarda; sin nada, 1080p.
  ProgramResolution _resolution = ProgramResolution.p1080;

  bool _searching = false;
  _ServerOrigin _origin = _ServerOrigin.none;

  /// Por qué no se pudo abrir el mando, si no se pudo.
  String? _mandoProblem;

  /// IOS-14: emparejando por Wi-Fi Aware, y lo que salió (con quién, o por qué no).
  bool _pairing = false;
  String? _pairingNote;
  bool _pairingFailed = false;

  /// IOS-68: el emparejado con el VPS guardado en el Keychain, y por qué no se pudo
  /// cambiar, si no se pudo.
  VpsPairing? _vps;
  String? _vpsProblem;

  bool get _football => widget.eventKind.isFootball;

  @override
  void initState() {
    super.initState();
    // El servidor del pod (y su búsqueda por Bonjour) es de los dos móviles del fútbol.
    if (_football) {
      unawaited(_loadServer());
    }
    unawaited(_loadPreference());
    unawaited(_loadVps());
  }

  int _nowS() => (widget.clockS ?? wallClockS)();

  Future<void> _loadVps() async {
    VpsPairing? guardado;
    try {
      guardado = await VpsPairing.load(_api);
    } on Exception {
      // Sin nativo (tests) no hay Keychain.
    }
    if (mounted) {
      setState(() => _vps = guardado);
    }
  }

  Future<void> _scanVps() async {
    String found = '';
    try {
      found = await _api.scanServerQr();
    } on Exception {
      // Sin nativo no hay cámara.
    }
    if (found.trim().isNotEmpty && mounted) {
      await _adoptVps(found);
    }
  }

  /// El QR Soporte, comprobado (caducidad incluida) y guardado en el Keychain. Un QR
  /// que no vale no toca lo que ya había.
  Future<void> _adoptVps(String text) async {
    final VpsPairing nuevo;
    try {
      nuevo = VpsPairing.parse(text, nowS: _nowS());
    } on VpsPairingException catch (e) {
      setState(() => _vpsProblem = e.message);
      return;
    }
    String? problema;
    try {
      await _api.saveVpsPairing(nuevo.qrText);
    } on Exception catch (e) {
      final String? motivo = e is PlatformException ? e.message : null;
      problema = 'No se pudo guardar en el Keychain: ${motivo ?? 'error'}';
    }
    if (mounted) {
      setState(() {
        _vps = problema == null ? nuevo : _vps;
        _vpsProblem = problema;
      });
    }
  }

  Future<void> _unpairVps() async {
    String? problema;
    try {
      await _api.clearVpsPairing();
    } on Exception {
      problema = 'No se pudo borrar del Keychain.';
    }
    if (mounted) {
      setState(() {
        _vps = problema == null ? null : _vps;
        _vpsProblem = problema;
      });
    }
  }

  Future<void> _loadPreference() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final bool? guardada = prefs.getBool(prefersMasterKey);
      if (guardada != null && mounted) {
        setState(() => _prefersMaster = guardada);
      }
      final String? enlace = prefs.getString(linkModeKey);
      final LinkMode? modo = LinkMode.values.where((LinkMode m) => m.name == enlace).firstOrNull;
      if (modo != null && mounted) {
        setState(() => _linkMode = modo);
      }
      final String? resolucion = prefs.getString(singleResolutionKey);
      final ProgramResolution? r =
          ProgramResolution.values.where((ProgramResolution v) => v.name == resolucion).firstOrNull;
      if (r != null && mounted) {
        setState(() => _resolution = r);
      }
    } on Exception {
      // Sin almacenamiento (tests): manda el valor por defecto.
    }
  }

  Future<void> _setLinkMode(LinkMode mode) async {
    setState(() => _linkMode = mode);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(linkModeKey, mode.name);
    } on Exception {
      // Si no se guarda, vale para esta vez.
    }
  }

  Future<void> _setResolution(ProgramResolution resolution) async {
    setState(() => _resolution = resolution);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(singleResolutionKey, resolution.name);
    } on Exception {
      // Si no se guarda, vale para esta vez.
    }
  }

  /// Al cambiar de lado, «Este móvil dirige» vuelve a lo del lado (el izquierdo dirige, el
  /// derecho no): lo que se guardó en el otro lado no se arrastra. Si no, un móvil que dirigía
  /// en la izquierda seguía queriendo dirigir al pasarlo a la derecha, y con los papeles
  /// invertidos los dos querían ser maestro (21-oct).
  Future<void> _setRole(CameraRole role) async {
    if (role == _role) {
      return;
    }
    setState(() {
      _role = role;
      _prefersMaster = null;
    });
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefersMasterKey);
    } on Exception {
      // Si no se borra, vale para esta vez.
    }
  }

  Future<void> _toggleDirects() async {
    final bool nuevo = !_directs;
    setState(() => _prefersMaster = nuevo);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefersMasterKey, nuevo);
    } on Exception {
      // Si no se guarda, vale para esta vez.
    }
  }

  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }

  /// Lo guardado manda; si no hay nada, se busca el servidor por Bonjour y se guarda lo
  /// encontrado, para no teclear una IP nunca.
  Future<void> _loadServer() async {
    try {
      _server.text = await _api.loadServerHost();
      if (_server.text.isNotEmpty) {
        _origin = _ServerOrigin.saved;
      }
    } on Exception {
      // Sin nativo (tests) no hay nada guardado. Se queda vacío: solo grabación.
    }
    if (_server.text.isEmpty) {
      await _discoverServer();
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _discoverServer() async {
    if (mounted) {
      setState(() => _searching = true);
    }
    try {
      final String found = await _api.discoverServer();
      if (found.isNotEmpty) {
        _server.text = found;
        _origin = _ServerOrigin.bonjour;
        await _saveServer(found);
      }
    } on Exception {
      // Sin nativo no hay red que buscar.
    }
    if (mounted) {
      setState(() => _searching = false);
    }
  }

  /// El QR de la tarjeta «Cámaras» del panel trae la dirección tal cual va en el campo.
  Future<void> _scanServer() async {
    String found = '';
    try {
      found = await _api.scanServerQr();
    } on Exception {
      // Sin nativo (tests) no hay cámara.
    }
    if (found.trim().isEmpty || !mounted) {
      return;
    }
    // El QR Soporte lleva las claves del VPS: nunca al campo, que se ve en pantalla.
    if (VpsPairing.looksLike(found)) {
      await _adoptVps(found);
      return;
    }
    setState(() {
      _server.text = found.trim();
      _origin = _ServerOrigin.scanned;
    });
    await _saveServer(found);
  }

  Future<void> _saveServer(String host) async {
    try {
      await _api.saveServerHost(host.trim());
    } on Exception {
      // Igual que arriba: sin nativo no se guarda, y no pasa nada.
    }
  }

  void _onTyped(String value) {
    unawaited(_saveServer(value));
    setState(() => _origin = value.trim().isEmpty ? _ServerOrigin.none : _ServerOrigin.typed);
  }

  /// El protocolo se deduce de lo escrito: sin esquema o `srt://` es SRT.
  String get _protocol => _server.text.trim().startsWith('rtmp') ? 'rtmp' : 'srt';

  /// Cambiar de protocolo reescribe el campo, para no teclear el esquema en el móvil.
  void _setProtocol(String protocol) {
    final String bare = _server.text.trim().replaceFirst(RegExp(r'^[a-z]+://'), '');
    final String next = (protocol == 'rtmp' && bare.isNotEmpty) ? 'rtmp://$bare' : bare;
    setState(() => _server.text = next);
    unawaited(_saveServer(next));
  }

  String get _serverNote {
    if (_searching) {
      return 'buscando el servidor en la red…';
    }
    return switch (_origin) {
      _ServerOrigin.bonjour => 'encontrado por Bonjour · vacío = solo graba en el móvil',
      _ServerOrigin.saved => 'guardado en el móvil · vacío = solo graba en el móvil',
      _ServerOrigin.scanned => 'leído del QR del panel · vacío = solo graba en el móvil',
      _ServerOrigin.typed || _ServerOrigin.none => 'vacío = solo graba en el móvil',
    };
  }

  void _open() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _football
            ? ZeroShell(
                role: _role,
                standalone: _standalone,
                serverHost: _server.text.trim(),
                // «Una cámara» dirige siempre, aunque «Este móvil dirige» esté apagado.
                prefersMaster: _directs || _linkMode == LinkMode.single,
                linkMode: _linkMode,
                resolution: _resolution,
              )
            // El espectáculo y el vóley (ADR 0031): «Una cámara (sin pareja)», que dirige.
            : ZeroShell(
                role: CameraRole.left,
                prefersMaster: true,
                linkMode: LinkMode.single,
                resolution: _resolution,
                eventKind: widget.eventKind,
              ),
      ),
    );
  }

  /// Wi-Fi Aware, el plan B del enlace sin router (IOS-14): se empareja una vez y el
  /// sistema lo recuerda. El izquierdo enseña un código y el derecho lo teclea, así que
  /// el lado elegido arriba decide qué hoja sale.
  Future<void> _pairWithoutCable() async {
    setState(() {
      _pairing = true;
      _pairingNote = null;
    });
    String note;
    bool failed = false;
    try {
      final String peer = await _api.pairWithoutCable(_role);
      note = peer.isEmpty ? 'Sin emparejar.' : 'Emparejado sin cable con $peer.';
    } on PlatformException catch (e) {
      note = 'No se pudo emparejar: ${e.message ?? e.code}';
      failed = true;
    } on Exception {
      // Sin nativo (tests sin el método) no hay Wi-Fi Aware.
      note = 'No se pudo emparejar.';
      failed = true;
    }
    if (mounted) {
      setState(() {
        _pairing = false;
        _pairingNote = note;
        _pairingFailed = failed;
      });
    }
  }

  /// El móvil como mando del panel, sin cámara (ADR 0017 de football-ai).
  ///
  /// Con un emparejamiento guardado entra directo; sin él, pide el QR «Mando» del panel
  /// y lo guarda. Un QR que no es de Mando —el de «Cámaras», una web— se dice aquí, en
  /// vez de abrir una pantalla que no va a poder conectar.
  Future<void> _openMando() async {
    PanelPairing? pairing;
    try {
      pairing = PanelPairing.parse(await _api.loadPanelPairing());
    } on Exception {
      // Sin nativo (tests) no hay nada guardado.
    }
    if (pairing == null) {
      String scanned = '';
      try {
        scanned = await _api.scanServerQr();
      } on Exception {
        // Sin nativo no hay cámara.
      }
      if (scanned.trim().isEmpty) {
        return; // cancelado
      }
      pairing = PanelPairing.parse(scanned);
      if (pairing == null) {
        if (mounted) {
          setState(
            () => _mandoProblem = 'Ese QR no es el de Mando: en el panel, tarjeta «Mando».',
          );
        }
        return;
      }
      try {
        await _api.savePanelPairing(pairing.qrText);
      } on Exception {
        // Si no se guarda, vale para esta vez.
      }
    }
    if (!mounted) {
      return;
    }
    final PanelPairing chosen = pairing;
    setState(() => _mandoProblem = null);
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              MandoPage(pairing: chosen, api: _api, controlFactory: widget.mandoControl),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_football) {
      return _buildOneCamera(context);
    }
    return Scaffold(
      // Los 34 px de abajo del diseño son el indicador de inicio del iPhone, no un
      // margen aparte: `minimum` deja el mayor de los dos en vez de sumarlos, y en un
      // móvil sin indicador el botón sigue sin pegarse al borde.
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
                    const _TopBar(kicker: 'FÚTBOL · CAPTURA'),
                    Text(
                      '¿Qué mitad cubre este móvil?',
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
                      'Si los dos dicen lo mismo, el servidor recibe dos veces media cancha.',
                      style: ZeroType.plex(
                        size: 14,
                        weight: FontWeight.w400,
                        color: ZeroColors.inkTertiary,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 22),
                    // `IntrinsicHeight` para que los dos bloques midan lo mismo aunque
                    // «SIGUE AL RELOJ» ocupe dos líneas y «MAESTRO» una: dos bloques de
                    // distinto alto se leen como si uno valiera más que el otro.
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Expanded(
                            child: _SideBlock(
                              label: 'IZQUIERDA',
                              note: 'MAESTRO',
                              selected: _role == CameraRole.left,
                              onTap: () => unawaited(_setRole(CameraRole.left)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _SideBlock(
                              label: 'DERECHA',
                              note: 'SIGUE AL RELOJ',
                              selected: _role == CameraRole.right,
                              onTap: () => unawaited(_setRole(CameraRole.right)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 26),
                    _ServerCard(
                      controller: _server,
                      searching: _searching,
                      note: _serverNote,
                      protocol: _protocol,
                      onChanged: _onTyped,
                      onFind: () => unawaited(_discoverServer()),
                      onScan: () => unawaited(_scanServer()),
                      onProtocol: _setProtocol,
                    ),
                    const SizedBox(height: ZeroMetrics.innerGap),
                    _StandaloneRow(
                      value: _directs,
                      onChanged: () => unawaited(_toggleDirects()),
                      title: 'Este móvil dirige',
                      subtitle: 'Al empezar un partido, este manda el soporte.',
                      danger: false,
                    ),
                    const SizedBox(height: ZeroMetrics.innerGap),
                    _StandaloneRow(
                      value: _standalone,
                      onChanged: () => setState(() => _standalone = !_standalone),
                    ),
                    const SizedBox(height: ZeroMetrics.innerGap),
                    // IOS-58: el enlace decide qué hace EMITIR. Va junto a lo que la
                    // arquitectura B necesita: emparejar sin cable y el VPS.
                    _LinkCard(
                      mode: _linkMode,
                      onMode: (LinkMode m) => unawaited(_setLinkMode(m)),
                      resolution: _resolution,
                      onResolution: (ProgramResolution r) => unawaited(_setResolution(r)),
                    ),
                    const SizedBox(height: ZeroMetrics.innerGap),
                    // Una vez por soporte, con los dos móviles delante: el plan B si no
                    // hay cable ni router (IOS-14).
                    ZeroButton.secondary(
                      label: _pairing ? 'Emparejando…' : 'Emparejar sin cable',
                      onPressed: _pairing ? null : () => unawaited(_pairWithoutCable()),
                    ),
                    if (_pairingNote case final String note)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          note,
                          textAlign: TextAlign.center,
                          style: ZeroType.plex(
                            size: 12,
                            weight: FontWeight.w500,
                            color: _pairingFailed ? ZeroColors.alarm : ZeroColors.inkTertiary,
                            height: 1.4,
                          ),
                        ),
                      ),
                    // El VPS, después del otro emparejado: se hace una vez por soporte y el
                    // QR se renueva cada 12 h (IOS-68).
                    const SizedBox(height: ZeroMetrics.innerGap),
                    _VpsCard(
                      pairing: _vps,
                      nowS: _nowS(),
                      problem: _vpsProblem,
                      onScan: () => unawaited(_scanVps()),
                      onUnpair: () => unawaited(_unpairVps()),
                    ),
                    const Spacer(),
                    const SizedBox(height: 20),
                    ZeroButton.primary(
                      label: 'Abrir cámara ${_role == CameraRole.left ? 'izquierda' : 'derecha'}',
                      height: ZeroMetrics.primaryHeight,
                      textStyle: ZeroType.plex(
                        size: 17,
                        weight: FontWeight.w600,
                        color: ZeroColors.onAccent,
                        height: 1.0,
                      ),
                      onPressed: _open,
                    ),
                    const SizedBox(height: 10),
                    // Aparte de los dos lados: este móvil no va en el soporte y no abre la
                    // cámara. Lleva el marcador del panel desde la banda.
                    ZeroButton.secondary(
                      label: 'Solo mando, sin cámara',
                      onPressed: () => unawaited(_openMando()),
                    ),
                    if (_mandoProblem case final String problem)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          problem,
                          textAlign: TextAlign.center,
                          style: ZeroType.plex(
                            size: 13,
                            weight: FontWeight.w500,
                            color: ZeroColors.alarm,
                            height: 1.4,
                          ),
                        ),
                      ),
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

extension on _RolePageState {
  /// La pantalla del espectáculo y del vóleibol (ADR 0031): una cámara, sin lado ni pareja.
  /// Solo la calidad y el VPS, que es a donde sale el programa.
  Widget _buildOneCamera(BuildContext context) {
    final String nota = widget.eventKind == EventKind.show
        ? 'Este móvil emite solo, con EN VIVO. Los rótulos, las franjas y los vídeos se sacan '
              'desde el mando web: el QR «Mando» de la pantalla de captura.'
        : 'Este móvil emite solo, con la cámara tal cual. Los gráficos del vóley llegan más '
              'adelante.';
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
                    _TopBar(kicker: widget.eventKind.label.toUpperCase()),
                    Text(
                      'Una cámara',
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
                      nota,
                      style: ZeroType.plex(
                        size: 14,
                        weight: FontWeight.w400,
                        color: ZeroColors.inkTertiary,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 22),
                    _ResolutionCard(
                      resolution: _resolution,
                      onResolution: (ProgramResolution r) => unawaited(_setResolution(r)),
                    ),
                    const SizedBox(height: ZeroMetrics.innerGap),
                    _VpsCard(
                      pairing: _vps,
                      nowS: _nowS(),
                      problem: _vpsProblem,
                      onScan: () => unawaited(_scanVps()),
                      onUnpair: () => unawaited(_unpairVps()),
                    ),
                    const Spacer(),
                    const SizedBox(height: 20),
                    ZeroButton.primary(
                      label: 'Abrir cámara',
                      height: ZeroMetrics.primaryHeight,
                      textStyle: ZeroType.plex(
                        size: 17,
                        weight: FontWeight.w600,
                        color: ZeroColors.onAccent,
                        height: 1.0,
                      ),
                      onPressed: _open,
                    ),
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

/// La cabecera: la marca, la etiqueta de la esquina y, si se llegó desde la pantalla del
/// evento, el «‹» para volver a ella.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.kicker});

  final String kicker;

  @override
  Widget build(BuildContext context) {
    final NavigatorState? nav = Navigator.maybeOf(context);
    final bool atras = nav != null && nav.canPop();
    return Padding(
      padding: EdgeInsets.fromLTRB(0, atras ? 2 : 14, 0, atras ? 14 : 26),
      child: Row(
        children: <Widget>[
          if (atras) ...<Widget>[
            Semantics(
              button: true,
              label: 'Cambiar de evento',
              child: ZeroTappable(
                onTap: () => nav.maybePop(),
                borderRadius: BorderRadius.circular(ZeroMetrics.fieldRadius),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: Text(
                      '‹',
                      style: ZeroType.archivo(size: 30, weight: FontWeight.w500, color: ZeroColors.ink, height: 1.0),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
          const ZeroLockup(diameter: 22),
          const Spacer(),
          _Kicker(kicker),
        ],
      ),
    );
  }
}

/// La calidad de la emisión con una cámara (IOS-99): lo único que se elige, además del VPS.
class _ResolutionCard extends StatelessWidget {
  const _ResolutionCard({required this.resolution, required this.onResolution});

  final ProgramResolution resolution;
  final ValueChanged<ProgramResolution> onResolution;

  @override
  Widget build(BuildContext context) {
    // Lo que pide de subida cada resolución: PRIMER-DESPLIEGUE.md de football-ai, §4b y §5.
    final String nota = switch (resolution) {
      ProgramResolution.p1080 => '1080p, hasta 6 Mbit/s: ~12 de subida.',
      ProgramResolution.p720 => '720p, hasta 3 Mbit/s: ~6 de subida. Para una conexión justa.',
    };
    return ZeroCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const ZeroSectionHeader('Calidad'),
          Row(
            children: <Widget>[
              for (final (ProgramResolution r, String label) in _LinkCard._resolutions) ...<Widget>[
                if (r != _LinkCard._resolutions.first.$1) const SizedBox(width: 8),
                ZeroPill(label: label, selected: resolution == r, onTap: () => onResolution(r)),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Text(
            nota,
            style: ZeroType.data(
              size: 11,
              weight: FontWeight.w400,
              color: ZeroColors.inkTertiary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// La etiqueta pequeña de la esquina.
class _Kicker extends StatelessWidget {
  const _Kicker(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: ZeroType.data(
        size: 10,
        weight: FontWeight.w500,
        color: ZeroColors.inkTertiary,
        letterSpacing: 1.6,
        height: 1.0,
      ),
    );
  }
}

/// Uno de los dos bloques de lado. Alto mínimo 96 porque es el toque que no se puede
/// fallar, y el único de la pantalla que se da con el móvil ya en el soporte.
class _SideBlock extends StatelessWidget {
  const _SideBlock({
    required this.label,
    required this.note,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String note;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color fill = selected ? ZeroColors.accent : Colors.transparent;
    final Color ink = selected ? ZeroColors.onAccent : ZeroColors.ink;
    // El diseño lo pide al 70 %, ya mezclado aquí contra el fondo del bloque para que se
    // pinte opaco. Va al 80 %: al 70 % la tinta oscura sobre el teal da 4.1:1, y un
    // subtítulo de 11 px necesita 4.5. Al 80 % da 5.0 sobre teal y 10 sobre el fondo.
    final Color noteInk = ZeroColors.blend(
      ink,
      0.8,
      selected ? ZeroColors.accent : ZeroColors.background,
    );

    return Semantics(
      button: true,
      selected: selected,
      child: ZeroTappable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: selected ? ZeroColors.accent : ZeroColors.outline),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Container(
          constraints: const BoxConstraints(minHeight: 96),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                label,
                textAlign: TextAlign.center,
                style: ZeroType.plex(
                  size: 15,
                  weight: FontWeight.w700,
                  color: ink,
                  letterSpacing: 0.9,
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 9),
              Text(
                note,
                textAlign: TextAlign.center,
                style: ZeroType.data(
                  size: 11,
                  weight: FontWeight.w400,
                  color: noteInk,
                  letterSpacing: 1.1,
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A dónde se emite. Vacío es una respuesta válida: sin servidor el móvil sigue
/// grabando en local, que es lo que convierte un fallo de red en un partido en diferido.
class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.controller,
    required this.searching,
    required this.note,
    required this.protocol,
    required this.onChanged,
    required this.onFind,
    required this.onScan,
    required this.onProtocol,
  });

  final TextEditingController controller;
  final bool searching;
  final String note;
  final String protocol;
  final ValueChanged<String> onChanged;
  final VoidCallback onFind;
  final VoidCallback onScan;
  final ValueChanged<String> onProtocol;

  @override
  Widget build(BuildContext context) {
    final bool hasHost = controller.text.trim().isNotEmpty;
    return ZeroCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const ZeroSectionHeader('Servidor'),
          Container(
            padding: const EdgeInsets.only(left: 16),
            decoration: BoxDecoration(
              color: ZeroColors.well,
              border: Border.all(color: ZeroColors.outlineSoft),
              borderRadius: BorderRadius.circular(ZeroMetrics.fieldRadius),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  // El `hint` desaparece al escribir: sin etiqueta, VoiceOver lee
                  // solo la URL, sin decir para qué es el campo.
                  child: Semantics(
                    label: 'Servidor',
                    child: TextField(
                      controller: controller,
                      onChanged: onChanged,
                      autocorrect: false,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.done,
                      style: ZeroType.data(
                        size: 15,
                        weight: FontWeight.w500,
                        color: ZeroColors.ink,
                        height: 1.2,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'mediamtx.local',
                        hintStyle: ZeroType.data(
                          size: 15,
                          weight: FontWeight.w500,
                          color: ZeroColors.inkTertiary,
                          height: 1.2,
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ),
                // El punto de estado es el botón de buscar en la red. Un icono de lupa a
                // su lado sería un segundo objetivo de 8 px en la misma esquina. La zona
                // de toque mide 48×44 y llega hasta el borde del campo; el punto queda a
                // 16 px de ese borde, como el texto por la izquierda.
                Semantics(
                  button: true,
                  enabled: !searching,
                  label: 'Buscar el servidor en la red',
                  child: ZeroTappable(
                    onTap: searching ? null : onFind,
                    borderRadius: BorderRadius.circular(ZeroMetrics.fieldRadius),
                    child: SizedBox(
                      width: 48,
                      height: 44,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Container(
                          margin: const EdgeInsets.only(right: 16),
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: hasHost && !searching
                                ? ZeroColors.accent
                                : ZeroColors.inkTertiary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            note,
            style: ZeroType.data(
              size: 11,
              weight: FontWeight.w400,
              color: ZeroColors.inkTertiary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          // SRT es el bueno para Starlink (recupera lo que se pierde en cada traspaso);
          // RTMP, el único que entra a un pod de RunPod. Elegir reescribe el campo.
          Row(
            children: <Widget>[
              ZeroPill(label: 'SRT', selected: protocol == 'srt', onTap: () => onProtocol('srt')),
              const SizedBox(width: 8),
              ZeroPill(
                label: 'RTMP',
                selected: protocol == 'rtmp',
                onTap: () => onProtocol('rtmp'),
              ),
              const SizedBox(width: 8),
              // La dirección del pod cambia con cada despliegue y no se teclea en la
              // cancha: el panel la enseña como QR (tarjeta «Cámaras») y aquí se lee.
              Expanded(
                child: ZeroButton.secondary(
                  label: 'Escanear QR',
                  onPressed: searching ? null : onScan,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// El enlace entre los dos móviles (IOS-58), y con él qué hace EMITIR: con Multipeer,
/// cada móvil emite su cámara al servidor de arriba (el pod); con los otros tres, el
/// maestro compone el programa y lo sube al VPS del QR Soporte (arquitectura B). Los dos
/// móviles tienen que elegir el mismo. Debajo, «Una cámara (sin pareja)» (2026-10-15): la
/// arquitectura B con este móvil solo, sin enlace, cuando no hay forma de enlazar.
class _LinkCard extends StatelessWidget {
  const _LinkCard({
    required this.mode,
    required this.onMode,
    required this.resolution,
    required this.onResolution,
  });

  final LinkMode mode;
  final ValueChanged<LinkMode> onMode;

  /// IOS-99: la resolución de «Una cámara», que solo se ve con ella elegida.
  final ProgramResolution resolution;
  final ValueChanged<ProgramResolution> onResolution;

  static const List<(ProgramResolution, String)> _resolutions = <(ProgramResolution, String)>[
    (ProgramResolution.p1080, '1080p'),
    (ProgramResolution.p720, '720p'),
  ];

  static const List<(LinkMode, String)> _choices = <(LinkMode, String)>[
    (LinkMode.multipeer, 'Pod'),
    (LinkMode.wifi, 'Wi-Fi'),
    (LinkMode.aware, 'Aware'),
    (LinkMode.ethernet, 'Cable'),
  ];

  @override
  Widget build(BuildContext context) {
    final String nota = switch (mode) {
      LinkMode.multipeer => 'Multipeer: cada móvil emite su cámara al servidor de arriba.',
      LinkMode.wifi => 'Por la Wi-Fi del router. El maestro compone y sube el programa al VPS.',
      LinkMode.aware =>
        'Wi-Fi Aware, sin router: empareja antes sin cable. El maestro sube el programa al VPS.',
      LinkMode.ethernet => 'Hub USB-C con Ethernet. El maestro compone y sube el programa al VPS.',
      // Lo que pide de subida cada resolución: PRIMER-DESPLIEGUE.md de football-ai, §4b y §5.
      LinkMode.single => switch (resolution) {
        ProgramResolution.p1080 =>
          'Sin pareja: este móvil emite solo con su cámara (1080p, hasta 6 Mbit/s: ~12 de subida), '
              'con el director, el gráfico y la franja. Sin enlace ni el otro móvil.',
        ProgramResolution.p720 =>
          'Sin pareja: este móvil emite solo con su cámara (720p, hasta 3 Mbit/s: ~6 de subida), '
              'con el director, el gráfico y la franja. Sin enlace ni el otro móvil.',
      },
    };
    return ZeroCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const ZeroSectionHeader('Enlace y emisión'),
          Row(
            children: <Widget>[
              for (final (LinkMode m, String label) in _choices) ...<Widget>[
                if (m != _choices.first.$1) const SizedBox(width: 8),
                // ZeroPill ya se expande en la fila.
                ZeroPill(label: label, selected: mode == m, onTap: () => onMode(m)),
              ],
            ],
          ),
          // Aparte y a lo ancho: no es un enlace más, es no tener ninguno.
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              ZeroPill(
                label: 'Una cámara (sin pareja)',
                selected: mode == LinkMode.single,
                onTap: () => onMode(LinkMode.single),
              ),
            ],
          ),
          // IOS-99 (ADR 0025): con una cámara, lo único que se elige es la resolución.
          if (mode == LinkMode.single) ...<Widget>[
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                for (final (ProgramResolution r, String label) in _resolutions) ...<Widget>[
                  if (r != _resolutions.first.$1) const SizedBox(width: 8),
                  ZeroPill(label: label, selected: resolution == r, onTap: () => onResolution(r)),
                ],
              ],
            ),
          ],
          const SizedBox(height: 10),
          Text(
            nota,
            style: ZeroType.data(
              size: 11,
              weight: FontWeight.w400,
              color: ZeroColors.inkTertiary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// El emparejado con el VPS (IOS-68): con quién y hasta cuándo vale la llave del túnel.
/// El QR Soporte sale en `/pair` del VPS; sin él, el programa no sale al VPS.
class _VpsCard extends StatelessWidget {
  const _VpsCard({
    required this.pairing,
    required this.nowS,
    required this.problem,
    required this.onScan,
    required this.onUnpair,
  });

  final VpsPairing? pairing;
  final int nowS;
  final String? problem;
  final VoidCallback onScan;
  final VoidCallback onUnpair;

  @override
  Widget build(BuildContext context) {
    final VpsPairing? p = pairing;
    final bool caducado = p != null && p.expiredAt(nowS);
    final String nota =
        problem ??
        switch (p) {
          null => 'Escanea el QR Soporte de /pair en el VPS.',
          _ when caducado => 'rig ${p.rigId} · la llave del túnel caducó: escanea otra vez',
          _ => 'rig ${p.rigId} · caduca en ${_remaining(p.validFor(nowS))}',
        };
    return ZeroCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const ZeroSectionHeader('VPS'),
          Text(
            p == null ? 'Sin emparejar' : 'Emparejado con ${p.domain}',
            style: ZeroType.data(
              size: 15,
              weight: FontWeight.w500,
              color: ZeroColors.ink,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            nota,
            style: ZeroType.data(
              size: 11,
              weight: FontWeight.w400,
              color: problem != null || caducado ? ZeroColors.alarm : ZeroColors.inkTertiary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: ZeroButton.secondary(
                  label: p == null ? 'Escanear QR Soporte' : 'Escanear otra vez',
                  onPressed: onScan,
                ),
              ),
              if (p != null) ...<Widget>[
                const SizedBox(width: 8),
                Expanded(
                  child: ZeroButton.secondary(label: 'Desemparejar', onPressed: onUnpair),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// «11 h 59 min», «12 h», «35 min».
  static String _remaining(Duration d) {
    final int horas = d.inHours;
    final int minutos = d.inMinutes.remainder(Duration.minutesPerHour);
    if (horas == 0) {
      return '${math.max(1, minutos)} min';
    }
    return minutos == 0 ? '$horas h' : '$horas h $minutos min';
  }
}

/// Un solo móvil, sin reloj.
///
/// La tarjeta entera se tiñe de rojo al encenderlo, y no solo el interruptor, porque
/// encenderlo sin querer en un partido de verdad es volver con dos vídeos que no parean
/// y no enterarse hasta que el servidor los rechace.
class _StandaloneRow extends StatelessWidget {
  const _StandaloneRow({
    required this.value,
    required this.onChanged,
    this.title = 'Un solo móvil, sin reloj',
    this.subtitle = 'Lo grabado así no parea con el otro.',
    this.danger = true,
  });

  final bool value;
  final VoidCallback onChanged;
  final String title;
  final String subtitle;

  /// En rojo cuando encenderlo es un riesgo (un solo móvil); neutro si es una opción.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    // `excludeSemantics` se lleva la acción del `InkWell`: el toque se declara aquí o
    // el interruptor se anuncia pero no se puede accionar con VoiceOver o TalkBack.
    return Semantics(
      toggled: value,
      label: title,
      onTap: onChanged,
      excludeSemantics: true,
      child: ZeroTappable(
        onTap: onChanged,
        borderRadius: BorderRadius.circular(ZeroMetrics.cardRadius),
        decoration: BoxDecoration(
          color: value && danger ? ZeroColors.dangerRow : ZeroColors.surface,
          border: Border.all(color: value && danger ? ZeroColors.dangerBorder : ZeroColors.border),
          borderRadius: BorderRadius.circular(ZeroMetrics.cardRadius),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: ZeroType.plex(
                        size: 15,
                        weight: FontWeight.w600,
                        color: ZeroColors.ink,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      subtitle,
                      style: ZeroType.plex(
                        size: 12,
                        weight: FontWeight.w400,
                        color: ZeroColors.inkTertiary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              _Switch(value: value, danger: danger),
            ],
          ),
        ),
      ),
    );
  }
}

class _Switch extends StatelessWidget {
  const _Switch({required this.value, this.danger = true});

  final bool value;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 32,
      decoration: BoxDecoration(
        color: value ? (danger ? ZeroColors.danger : ZeroColors.accent) : ZeroColors.switchTrack,
        borderRadius: BorderRadius.circular(999),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 180),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.all(3),
          width: 26,
          height: 26,
          decoration: const BoxDecoration(color: ZeroColors.white, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
