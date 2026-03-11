import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_audio_capture/flutter_audio_capture.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

void main() {
  runApp(const ReflectorApp());
}

class ReflectorApp extends StatelessWidget {
  const ReflectorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Reflector',
      home: AccelerometerColorScreen(),
    );
  }
}

// Simple spectral analysis: 8 frequency bands via Goertzel algorithm
class AudioAnalyzer {
  // 8 bands roughly: sub-bass, bass, low-mid, mid, upper-mid, presence, brilliance, air
  // Target frequencies for each band (Hz)
  static const List<double> _bandFreqs = [
    80, 160, 320, 640, 1280, 2560, 5120, 10240,
  ];
  static const int _sampleRate = 44100;

  // Smoothed band energies
  final Float64List _bandEnergies = Float64List(8);
  final Float64List _smoothedEnergies = Float64List(8);
  static const double _smoothing = 0.5;

  // Overall loudness
  double rms = 0;

  void analyze(List<double> samples) {
    if (samples.isEmpty) return;

    // Compute RMS
    double sumSq = 0;
    for (final s in samples) {
      sumSq += s * s;
    }
    rms = sqrt(sumSq / samples.length);

    // Goertzel for each band frequency
    final n = samples.length;
    for (var b = 0; b < _bandFreqs.length; b++) {
      final freq = _bandFreqs[b];
      final k = (freq * n / _sampleRate).roundToDouble();
      final w = 2 * pi * k / n;
      final coeff = 2 * cos(w);

      double s0 = 0, s1 = 0, s2 = 0;
      for (var i = 0; i < n; i++) {
        s0 = samples[i] + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
      }

      final power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
      _bandEnergies[b] = sqrt(power.abs()) / n;
    }

    // Smooth
    for (var b = 0; b < 8; b++) {
      _smoothedEnergies[b] +=
          (_bandEnergies[b] - _smoothedEnergies[b]) * _smoothing;
    }
  }

  /// Returns the dominant band index (0-7)
  int get dominantBand {
    int best = 0;
    double bestVal = 0;
    for (var i = 0; i < 8; i++) {
      if (_smoothedEnergies[i] > bestVal) {
        bestVal = _smoothedEnergies[i];
        best = i;
      }
    }
    return best;
  }

  /// Returns a spectral fingerprint: normalized energy per band
  /// Same sound signature -> same fingerprint -> same cells
  List<double> get fingerprint {
    double total = 0;
    for (var i = 0; i < 8; i++) {
      total += _smoothedEnergies[i];
    }
    if (total < 0.0001) return List.filled(8, 0.0);
    return List.generate(8, (i) => _smoothedEnergies[i] / total);
  }

  double bandEnergy(int band) => _smoothedEnergies[band];
}

class AccelerometerColorScreen extends StatefulWidget {
  const AccelerometerColorScreen({super.key});

  @override
  State<AccelerometerColorScreen> createState() =>
      _AccelerometerColorScreenState();
}

class _AccelerometerColorScreenState extends State<AccelerometerColorScreen>
    with SingleTickerProviderStateMixin {
  // Accelerometer
  double _x = 0;
  double _y = 0;
  double _z = 0;
  static const double _smoothing = 0.15;
  StreamSubscription<AccelerometerEvent>? _accelSub;

  // Audio
  final FlutterAudioCapture _audioCapture = FlutterAudioCapture();
  final AudioAnalyzer _analyzer = AudioAnalyzer();
  bool _micStarted = false;

  // Extra off-screen margin so cells can flow in from edges
  static const int _extraCols = 2;
  static const int _extraRows = 2;

  // Shake physics — global offset from accelerometer + audio, cells respond with inertia
  double _shakeVx = 0;
  double _shakeVy = 0;
  double _audioShakeX = 0; // audio-driven shake impulse
  double _audioShakeY = 0;
  List<double> _cellOffsetX = []; // per-cell current X displacement
  List<double> _cellOffsetY = [];
  List<double> _cellVelX = [];    // per-cell velocity
  List<double> _cellVelY = [];
  static const double _springK = 0.03;   // softer spring (slower return)
  static const double _damping = 0.2;    // less damping (more sloshing)
  static const double _inertiaScale = 1.5; // stronger push from shake
  List<double> _cellMass = [];             // random per-cell mass

  // Grid — includes extra off-screen margin
  static const int _visibleCols = 8;
  int _visibleRows = 14;
  int get _cols => _visibleCols + _extraCols * 2;
  int get _rows => _visibleRows + _extraRows * 2;
  int get _total => _cols * _rows;
  final Random _random = Random();
  List<double> _glow = [];
  List<double> _glowNext = [];
  List<double> _audioHue = [];    // per-cell hue from audio
  List<double> _audioHueNext = [];
  List<double> _hueOffsets = [];
  List<double> _brightOffsets = [];
  List<double> _wobblePhaseX = []; // random per-cell wobble phase
  List<double> _wobblePhaseY = [];
  List<double> _wobbleSpeed = [];  // random per-cell wobble speed
  bool _gridInitialized = false;

  // Wave propagation
  static const double _spreadRate = 0.22;
  static const double _decayRate = 0.993;

  // Animation
  late Ticker _ticker;
  int _tickCount = 0;

  // Idle patterns
  int _idleTicks = 0; // ticks since last audio trigger
  static const int _idleThreshold = 120; // ~2 seconds at 60fps
  int _currentPattern = 0;
  double _patternPhase = 0;
  static const int _patternCount = 5;

  // Debug
  bool _showDebug = false;

  @override
  void initState() {
    super.initState();

    _initGrid(_rows);

    // Accelerometer
    _accelSub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 50),
    ).listen((event) {
      // Shake velocity: raw accel minus smoothed (removes gravity)
      _shakeVx = (event.x - _x) * _inertiaScale;
      _shakeVy = (event.y - _y) * _inertiaScale;

      _x += (event.x - _x) * _smoothing;
      _y += (event.y - _y) * _smoothing;
      _z += (event.z - _z) * _smoothing;
    });

    _startMic();

    // Tick loop for wave propagation
    _ticker = createTicker(_onTick)..start();
  }

  void _initGrid(int visibleRows) {
    _visibleRows = visibleRows;
    final total = _total;
    _glow = List.filled(total, 0.0);
    _glowNext = List.filled(total, 0.0);
    _audioHue = List.filled(total, 0.0);
    _audioHueNext = List.filled(total, 0.0);
    _hueOffsets = List.generate(total, (_) => _random.nextDouble() * 60 - 30);
    _brightOffsets =
        List.generate(total, (_) => _random.nextDouble() * 0.3 - 0.15);
    _wobblePhaseX = List.generate(total, (_) => _random.nextDouble() * 2 * pi);
    _wobblePhaseY = List.generate(total, (_) => _random.nextDouble() * 2 * pi);
    _wobbleSpeed = List.generate(total, (_) => 0.3 + _random.nextDouble() * 0.7);
    _cellOffsetX = List.filled(total, 0.0);
    _cellOffsetY = List.filled(total, 0.0);
    _cellVelX = List.filled(total, 0.0);
    _cellVelY = List.filled(total, 0.0);
    _cellMass = List.generate(total, (_) => 0.5 + _random.nextDouble() * 1.5);
    _gridInitialized = true;
  }

  Future<void> _startMic() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) return;

    await _audioCapture.start(
      _onAudioData,
      _onAudioError,
      sampleRate: 44100,
      bufferSize: 2048,
    );
    _micStarted = true;
  }

  void _onAudioData(dynamic data) {
    // flutter_audio_capture gives Float64List or List<double>
    List<double> samples;
    if (data is Float64List) {
      samples = data.toList();
    } else if (data is List) {
      samples = data.cast<double>();
    } else {
      return;
    }

    _analyzer.analyze(samples);

    if (!_gridInitialized) return;

    final rms = _analyzer.rms;
    if (rms < 0.002) return; // very low silence threshold

    _idleTicks = 0; // reset idle

    // Loud sounds push cells like a shake
    if (rms > 0.05) {
      final shakeForce = (rms * 4).clamp(0.0, 3.0);
      _audioShakeX += ((_random.nextDouble() - 0.5) * 2) * shakeForce;
      _audioShakeY += ((_random.nextDouble() - 0.5) * 2) * shakeForce;
    }

    final fp = _analyzer.fingerprint;
    final dominant = _analyzer.dominantBand;
    final total = _glow.length;
    if (total == 0) return;

    final loudness = (rms * 8).clamp(0.0, 1.0);

    // Derive a hue from the spectral shape:
    // Spectral centroid maps to hue — bass=red, mid=green, treble=blue
    double centroid = 0;
    double totalEnergy = 0;
    for (var b = 0; b < 8; b++) {
      final e = _analyzer.bandEnergy(b);
      centroid += b * e;
      totalEnergy += e;
    }
    if (totalEnergy > 0) centroid /= totalEnergy;
    // centroid is 0-7, map to hue 0-360
    final soundHue = (centroid / 7.0 * 360) % 360;

    // Center of the grid
    final cr = _rows / 2.0;
    final cc = _cols / 2.0;
    final maxDist = sqrt(cr * cr + cc * cc);

    // Each band maps to a ring distance from center:
    // low frequencies = center, high frequencies = outer edge
    // Same sound spectrum = same ring pattern
    for (var band = 0; band < 8; band++) {
      final energy = _analyzer.bandEnergy(band);
      if (energy < 0.001) continue;

      final intensity = (energy * 60 * loudness).clamp(0.0, 1.0);

      // Band determines which ring from center lights up
      final ringDist = (band + 0.5) / 8.0 * maxDist;

      // Fingerprint offsets the angle so similar sounds hit same cells
      final angleOffset = fp[band] * 2 * pi;

      for (var r = 0; r < _rows; r++) {
        for (var c = 0; c < _cols; c++) {
          final dr = r - cr;
          final dc = c - cc;
          final dist = sqrt(dr * dr + dc * dc);

          // Wider ring tolerance so more cells get hit
          final ringDiff = (dist - ringDist).abs();
          if (ringDiff > 3.0) continue;

          final ringFalloff = 1.0 - ringDiff / 3.0;

          // Dominant band lights the full ring, others favor a direction
          double angleFactor = 1.0;
          if (band != dominant) {
            final cellAngle = atan2(dr, dc);
            angleFactor = (cos(cellAngle - angleOffset) + 1.0) / 2.0;
            angleFactor = 0.4 + angleFactor * 0.6;
          }

          final idx = r * _cols + c;
          if (idx >= 0 && idx < total) {
            final v = intensity * ringFalloff * ringFalloff * angleFactor;
            // Per-band hue offset so different bands get different colors
            final bandHue = (soundHue + band * 20) % 360;
            if (v > _glow[idx]) {
              _audioHue[idx] = bandHue;
            }
            _glow[idx] = (_glow[idx] + v).clamp(0.0, 1.0);
          }
        }
      }
    }

  }

  void _onAudioError(Object error) {
    debugPrint('Audio error: $error');
  }

  void _applyIdlePattern() {
    _patternPhase += 0.08; // fast sweep
    final maxDist = (_rows + _cols).toDouble();
    if (_patternPhase > maxDist + 4) {
      _patternPhase = -4.0;
      _currentPattern = (_currentPattern + 1) % _patternCount;
    }

    final phase = _patternPhase;
    const intensity = 0.5;
    const waveWidth = 3.5; // wide overlap so cells bunch together

    for (var r = 0; r < _rows; r++) {
      for (var c = 0; c < _cols; c++) {
        double dist;
        switch (_currentPattern) {
          case 0: // center outward
            final cr = _rows / 2.0;
            final cc = _cols / 2.0;
            dist = sqrt((r - cr) * (r - cr) + (c - cc) * (c - cc));
            break;
          case 1: // left to right
            dist = c.toDouble();
            break;
          case 2: // right to left
            dist = (_cols - 1 - c).toDouble();
            break;
          case 3: // diagonal top-left to bottom-right
            dist = (r + c) * 0.7;
            break;
          case 4: // diagonal bottom-right to top-left
          default:
            dist = (_rows + _cols - 2 - r - c) * 0.7;
            break;
        }

        final diff = (phase - dist).abs();
        if (diff < waveWidth) {
          // Smooth falloff with overlap
          final wave = (1.0 - diff / waveWidth);
          final idx = r * _cols + c;
          _glow[idx] = max(_glow[idx], wave * wave * intensity);
        }
      }
    }
  }

  void _onTick(Duration elapsed) {
    if (!_gridInitialized) return;
    _tickCount++;
    _idleTicks++;

    // Idle shimmer: soft ambient glow on small clusters, not single cells
    if (_tickCount % 12 == 0) {
      final r = _random.nextInt(_rows);
      final c = _random.nextInt(_cols);
      // Light a 2x2 area softly
      for (var dr = 0; dr < 2; dr++) {
        for (var dc = 0; dc < 2; dc++) {
          final nr = r + dr;
          final nc = c + dc;
          if (nr < _rows && nc < _cols) {
            final idx = nr * _cols + nc;
            _glow[idx] = max(_glow[idx], 0.12);
          }
        }
      }
    }

    // Idle patterns when no audio for a while
    if (_idleTicks > _idleThreshold) {
      _applyIdlePattern();
    }

    // Propagate glow
    final glowLen = _glow.length;
    for (var r = 0; r < _rows; r++) {
      for (var c = 0; c < _cols; c++) {
        final idx = r * _cols + c;
        if (idx >= glowLen) continue;
        double neighborMax = 0;
        int bestNeighbor = idx;

        void checkNeighbor(int ni) {
          if (_glow[ni] > neighborMax) {
            neighborMax = _glow[ni];
            bestNeighbor = ni;
          }
        }

        if (r > 0) checkNeighbor((r - 1) * _cols + c);
        if (r < _rows - 1) checkNeighbor((r + 1) * _cols + c);
        if (c > 0) checkNeighbor(r * _cols + c - 1);
        if (c < _cols - 1) checkNeighbor(r * _cols + c + 1);

        final spread = neighborMax * _spreadRate;
        _glowNext[idx] = max(_glow[idx], spread) * _decayRate;

        // Propagate hue from brightest neighbor
        if (spread > _glow[idx]) {
          _audioHueNext[idx] = _audioHue[bestNeighbor];
        } else {
          _audioHueNext[idx] = _audioHue[idx];
        }
      }
    }

    final tmp = _glow;
    _glow = _glowNext;
    _glowNext = tmp;

    final tmpH = _audioHue;
    _audioHue = _audioHueNext;
    _audioHueNext = tmpH;

    // Combine accelerometer shake + audio shake
    final totalShakeX = _shakeVx + _audioShakeX;
    final totalShakeY = _shakeVy + _audioShakeY;
    _audioShakeX *= 0.85; // decay audio shake
    _audioShakeY *= 0.85;

    // Per-cell spring physics: accel pushes, spring pulls back
    final glLen = _cellOffsetX.length;
    for (var i = 0; i < glLen; i++) {
      final mass = _cellMass[i];
      _cellVelX[i] += totalShakeX / mass;
      _cellVelY[i] += totalShakeY / mass;
      // Spring force toward origin
      _cellVelX[i] -= _cellOffsetX[i] * _springK;
      _cellVelY[i] -= _cellOffsetY[i] * _springK;
      // Damping
      _cellVelX[i] *= _damping;
      _cellVelY[i] *= _damping;
      // Integrate
      _cellOffsetX[i] += _cellVelX[i];
      _cellOffsetY[i] += _cellVelY[i];
    }

    setState(() {});
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    if (_micStarted) _audioCapture.stop();
    _ticker.dispose();
    super.dispose();
  }

  double _computeCentroid() {
    double c = 0, total = 0;
    for (var b = 0; b < 8; b++) {
      final e = _analyzer.bandEnergy(b);
      c += b * e;
      total += e;
    }
    return total > 0 ? c / total : 0;
  }

  double _tiltHue() {
    final nx = (_x / 10.0).clamp(-1.0, 1.0);
    final ny = (_y / 10.0).clamp(-1.0, 1.0);
    return (atan2(ny, nx) * 180 / pi + 300) % 360; // flat = green
  }

  double _tiltSaturation() {
    final nx = (_x / 10.0).clamp(-1.0, 1.0);
    final ny = (_y / 10.0).clamp(-1.0, 1.0);
    return (sqrt(nx * nx + ny * ny)).clamp(0.3, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final hue = _tiltHue();
    final sat = _tiltSaturation();
    final zNorm = ((_z / 10.0).clamp(-1.0, 1.0) + 1.0) / 2.0;
    final brightness = 0.5 + zNorm * 0.4;

    return Scaffold(
      backgroundColor: HSVColor.fromAHSV(1, hue, sat * 0.3, 0.15).toColor(),
      body: Stack(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final cellSize = constraints.maxWidth / _visibleCols;
              final neededRows = (constraints.maxHeight / cellSize).ceil();
              if (neededRows != _visibleRows) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _initGrid(neededRows);
                });
              }
              if (!_gridInitialized) return const SizedBox.shrink();

              return CustomPaint(
                size: Size(constraints.maxWidth, constraints.maxHeight),
                painter: _GridPainter(
                  cols: _cols,
                  rows: _rows,
                  extraCols: _extraCols,
                  extraRows: _extraRows,
                  cellSize: cellSize,
                  glow: _glow,
                  hue: hue,
                  saturation: sat,
                  brightness: brightness,
                  hueOffsets: _hueOffsets,
                  brightOffsets: _brightOffsets,
                  audioHue: _audioHue,
                  wobblePhaseX: _wobblePhaseX,
                  wobblePhaseY: _wobblePhaseY,
                  wobbleSpeed: _wobbleSpeed,
                  cellOffsetX: _cellOffsetX,
                  cellOffsetY: _cellOffsetY,
                  tick: _tickCount,
                ),
              );
            },
          ),
          if (_showDebug)
            Positioned(
              left: 12,
              right: 12,
              bottom: 40,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // RMS bar
                    Row(
                      children: [
                        const Text('RMS ', style: TextStyle(color: Colors.white54, fontSize: 12, fontFamily: 'monospace')),
                        Expanded(
                          child: Container(
                            height: 8,
                            decoration: BoxDecoration(
                              color: Colors.white10,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: (_analyzer.rms * 5).clamp(0.0, 1.0),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.greenAccent,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: 8),
                        Text(
                          _analyzer.rms.toStringAsFixed(3),
                          style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Frequency bands with colors
                    SizedBox(
                      height: 100,
                      child: CustomPaint(
                        size: const Size(double.infinity, 100),
                        painter: _AudioDebugPainter(
                          analyzer: _analyzer,
                          tiltHue: hue,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Band labels
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: const [
                        Text('80', style: TextStyle(color: Colors.white38, fontSize: 9, fontFamily: 'monospace')),
                        Text('160', style: TextStyle(color: Colors.white38, fontSize: 9, fontFamily: 'monospace')),
                        Text('320', style: TextStyle(color: Colors.white38, fontSize: 9, fontFamily: 'monospace')),
                        Text('640', style: TextStyle(color: Colors.white38, fontSize: 9, fontFamily: 'monospace')),
                        Text('1.3k', style: TextStyle(color: Colors.white38, fontSize: 9, fontFamily: 'monospace')),
                        Text('2.6k', style: TextStyle(color: Colors.white38, fontSize: 9, fontFamily: 'monospace')),
                        Text('5.1k', style: TextStyle(color: Colors.white38, fontSize: 9, fontFamily: 'monospace')),
                        Text('10k', style: TextStyle(color: Colors.white38, fontSize: 9, fontFamily: 'monospace')),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Centroid and dominant info
                    Row(
                      children: [
                        Text(
                          'Dom: ${_analyzer.dominantBand}  ',
                          style: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'monospace'),
                        ),
                        Text(
                          'Centroid: ${_computeCentroid().toStringAsFixed(1)}  ',
                          style: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'monospace'),
                        ),
                        Container(
                          width: 16, height: 16,
                          decoration: BoxDecoration(
                            color: HSVColor.fromAHSV(1, (_computeCentroid() / 7 * 360) % 360, 0.9, 0.9).toColor(),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const Text('  sound hue', style: TextStyle(color: Colors.white38, fontSize: 11)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Tilt: X${_x.toStringAsFixed(1)} Y${_y.toStringAsFixed(1)} Z${_z.toStringAsFixed(1)}  Idle: $_idleTicks',
                      style: const TextStyle(color: Colors.white38, fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
            ),
          Positioned(
            top: 48,
            right: 16,
            child: IconButton(
              onPressed: () => setState(() => _showDebug = !_showDebug),
              icon: Icon(
                _showDebug ? Icons.bug_report : Icons.bug_report_outlined,
                color: Colors.white54,
                size: 28,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  final int cols;
  final int rows;
  final int extraCols;
  final int extraRows;
  final double cellSize;
  final List<double> glow;
  final double hue;
  final double saturation;
  final double brightness;
  final List<double> hueOffsets;
  final List<double> brightOffsets;
  final List<double> audioHue;
  final List<double> wobblePhaseX;
  final List<double> wobblePhaseY;
  final List<double> wobbleSpeed;
  final List<double> cellOffsetX;
  final List<double> cellOffsetY;
  final int tick;

  _GridPainter({
    required this.cols,
    required this.rows,
    required this.extraCols,
    required this.extraRows,
    required this.cellSize,
    required this.glow,
    required this.hue,
    required this.saturation,
    required this.brightness,
    required this.hueOffsets,
    required this.brightOffsets,
    required this.audioHue,
    required this.wobblePhaseX,
    required this.wobblePhaseY,
    required this.wobbleSpeed,
    required this.cellOffsetX,
    required this.cellOffsetY,
    required this.tick,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final t = tick * 0.015; // slower base time for supple motion
    const maxWobble = 2.0; // gentle idle sway
    const glowWobbleBoost = 5.0; // extra when glowing

    final total = glow.length;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final idx = r * cols + c;
        if (idx >= total) continue;
        final g = glow[idx].clamp(0.0, 1.0);

        // Layered sine waves for organic, supple motion
        final speed = wobbleSpeed[idx];
        final phX = wobblePhaseX[idx];
        final phY = wobblePhaseY[idx];
        final amp = maxWobble + g * glowWobbleBoost;
        final wobbleX = (sin(t * speed + phX) * 0.6 +
                sin(t * speed * 1.7 + phX * 2.3) * 0.3 +
                sin(t * speed * 0.4 + phX * 0.7) * 0.1) *
            amp;
        final wobbleY = (cos(t * speed * 0.8 + phY) * 0.6 +
                cos(t * speed * 1.5 + phY * 1.9) * 0.3 +
                cos(t * speed * 0.3 + phY * 0.5) * 0.1) *
            amp;

        // Base tilt hue + per-cell offset
        final cellHue = (hue + hueOffsets[idx]) % 360;

        // When glowing, blend toward the audio-derived hue
        final aHue = audioHue[idx];
        final blendedHue = g > 0.01
            ? _lerpAngle(cellHue, aHue, g.clamp(0.0, 0.8))
            : cellHue;

        final borderHue = (blendedHue + 30 + g * 40) % 360;

        final isLight = (r + c) % 2 == 0;
        final baseBright =
            ((isLight ? brightness : brightness * 0.7) + brightOffsets[idx])
                .clamp(0.2, 1.0);
        final baseSat = isLight ? saturation : saturation * 0.8;

        // Glow boosts brightness and saturation (colorful, not white)
        final fillBright =
            (baseBright + g * (1.0 - baseBright) * 0.7).clamp(0.0, 1.0);
        final fillSat = (baseSat + g * (1.0 - baseSat) * 0.5).clamp(0.0, 1.0);

        fillPaint.color =
            HSVColor.fromAHSV(1, blendedHue, fillSat, fillBright).toColor();

        final borderBright = (0.4 + g * 0.6).clamp(0.0, 1.0);
        final borderSat = (saturation * 0.6 + g * 0.4).clamp(0.0, 1.0);
        borderPaint.color =
            HSVColor.fromAHSV(1, borderHue, borderSat, borderBright)
                .toColor();

        // Combine wobble + shake physics offset, shifted for off-screen margin
        const inset = 2.0;
        final physX = cellOffsetX[idx];
        final physY = cellOffsetY[idx];
        final originX = (c - extraCols) * cellSize;
        final originY = (r - extraRows) * cellSize;
        final rect = Rect.fromLTWH(
          originX + inset + wobbleX + physX,
          originY + inset + wobbleY + physY,
          cellSize - inset * 2,
          cellSize - inset * 2,
        );

        canvas.drawRect(rect, fillPaint);
        canvas.drawRect(rect, borderPaint);
      }
    }
  }

  // Lerp between two hue angles (0-360) taking the short path
  double _lerpAngle(double a, double b, double t) {
    var diff = (b - a) % 360;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    return (a + diff * t) % 360;
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) => true;
}

class _AudioDebugPainter extends CustomPainter {
  final AudioAnalyzer analyzer;
  final double tiltHue;

  _AudioDebugPainter({required this.analyzer, required this.tiltHue});

  @override
  void paint(Canvas canvas, Size size) {
    final barPaint = Paint()..style = PaintingStyle.fill;
    final outlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white24;

    final barWidth = size.width / 8;
    final fp = analyzer.fingerprint;

    // Compute centroid for marker
    double centroid = 0, totalE = 0;
    for (var b = 0; b < 8; b++) {
      final e = analyzer.bandEnergy(b);
      centroid += b * e;
      totalE += e;
    }
    if (totalE > 0) centroid /= totalE;
    final soundHue = (centroid / 7.0 * 360) % 360;

    // Draw bars
    for (var b = 0; b < 8; b++) {
      final energy = analyzer.bandEnergy(b);
      final barH = (energy * 800).clamp(0.0, size.height); // scale for visibility
      final x = b * barWidth;

      // Color each bar with its derived hue
      final bandHue = (soundHue + b * 20) % 360;
      barPaint.color = HSVColor.fromAHSV(0.9, bandHue, 0.8, 0.9).toColor();

      // Bar
      canvas.drawRect(
        Rect.fromLTWH(x + 2, size.height - barH, barWidth - 4, barH),
        barPaint,
      );

      // Outline
      canvas.drawRect(
        Rect.fromLTWH(x + 2, 0, barWidth - 4, size.height),
        outlinePaint,
      );

      // Fingerprint overlay (white, semi-transparent) showing relative weight
      final fpH = fp[b] * size.height;
      canvas.drawRect(
        Rect.fromLTWH(x + 2, size.height - fpH, barWidth - 4, fpH),
        Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.white.withValues(alpha: 0.15),
      );
    }

    // Centroid marker line
    final centroidX = (centroid / 7.0) * size.width;
    canvas.drawLine(
      Offset(centroidX, 0),
      Offset(centroidX, size.height),
      Paint()
        ..color = Colors.white70
        ..strokeWidth = 2,
    );

    // Dominant band indicator
    final dom = analyzer.dominantBand;
    final domX = dom * barWidth + barWidth / 2;
    canvas.drawCircle(
      Offset(domX, 6),
      4,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _AudioDebugPainter oldDelegate) => true;
}
