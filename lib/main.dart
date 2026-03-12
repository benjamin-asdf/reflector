import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_audio_capture/flutter_audio_capture.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  runApp(const ReflectorApp());
}

class ReflectorApp extends StatelessWidget {
  const ReflectorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Reflector',
      debugShowCheckedModeBanner: false,
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
  static const double _smoothing = 0.7; // faster response to transients

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

class _TapRipple {
  final int col;
  final int row;
  final double? hue;      // null = no color override, uses existing; set = audio color ripple
  final double force;     // physics push strength
  final double maxRadius; // how far the ripple travels (inf = full grid)
  double phase = 0;
  _TapRipple({required this.col, required this.row, this.hue, this.force = 5.0, this.maxRadius = double.infinity});
}

enum _WavePattern { radial, snake, grow, tetris, spiral, shockwave, rain, cross }

class _AudioWave {
  double phase = 0;
  final double intensity;
  final double hue;
  final double speed;       // how fast the pattern advances
  final double beatForce;   // radial push strength
  final double originR;     // wave origin row (fractional)
  final double originC;     // wave origin col (fractional)
  final _WavePattern pattern;
  final int seed;           // for deterministic pattern shapes
  final List<List<int>>? path; // precomputed path for snake/tetris
  final bool beatSynced;    // if true, only advances on beat
  int beatStep = 0;         // how many beats have advanced this pattern
  _AudioWave({required this.intensity, required this.hue, required this.speed, required this.beatForce, required this.originR, required this.originC, required this.pattern, this.seed = 0, this.path, this.beatSynced = false});
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
  // Shake-to-shuffle: detect ~2-3cm traverse then reversal
  static const double _displacementThreshold = 0.12; // meters (~12cm)
  static const int _shakeWindowMs = 700;
  static const int _shakeCooldownMs = 2000;
  int _lastShakeShuffle = 0;
  // Integrated linear velocity & displacement
  double _linVx = 0, _linVy = 0;
  double _dispX = 0, _dispY = 0;
  // First stroke direction
  double _strokeDx = 0, _strokeDy = 0;
  int _strokeTime = 0;
  bool _hasFirstStroke = false;

  // Audio
  final FlutterAudioCapture _audioCapture = FlutterAudioCapture();
  final AudioAnalyzer _analyzer = AudioAnalyzer();
  bool _micStarted = false;
  final List<_AudioWave> _audioWaves = [];
  double _prevRms = 0; // for beat detection (rising edge)
  int _lastRippleMs = 0; // cooldown for audio ripple spawning
  final List<double> _prevBandEnergy = List.filled(8, 0.0);

  // Extra off-screen margin so cells can flow in from edges
  static const int _extraCols = 2;
  static const int _extraRows = 2;

  // Beat flash — global brightness/scale pulse on bass hits
  double _beatFlash = 0; // 0-1, decays each frame

  // Shake physics — global offset from accelerometer + audio, cells respond with inertia
  double _shakeVx = 0;
  double _shakeVy = 0;
  List<double> _cellOffsetX = []; // per-cell current X displacement
  List<double> _cellOffsetY = [];
  List<double> _cellVelX = [];    // per-cell velocity
  List<double> _cellVelY = [];
  List<double> _beatForceX = [];  // per-cell beat impulse
  List<double> _beatForceY = [];
  static const double _springK = 0.3; 
  static const double _damping = 0.1;   // more friction — less wobble
  static const double _inertiaScale = 0.75;
  List<double> _cellMass = [];             

  // Grid — includes extra off-screen margin
  static const int _visibleCols = 8;
  int _visibleRows = 14;
  int get _cols => _visibleCols + _extraCols * 2;
  int get _rows => _visibleRows + _extraRows * 2;
  int get _total => _cols * _rows;
  int _colorSeed = 0;
  double _hueAnchor = 300; // +300 = green at flat; changes on shuffle
  Random _random = Random();
  List<double> _glow = [];
  List<double> _glowTarget = []; // desired glow — _glow eases toward this
  List<double> _glowNext = [];
  List<double> _audioHue = [];    // per-cell current displayed hue
  List<double> _audioHueTarget = []; // per-cell target hue (inertial)
  List<double> _audioHueNext = [];
  List<double> _hueOffsets = [];
  List<double> _brightOffsets = [];
  List<double> _wobblePhaseX = []; // random per-cell wobble phase
  List<double> _wobblePhaseY = [];
  List<double> _wobbleSpeed = [];  // random per-cell wobble speed
  List<double> _sizeJitter = []; // per-cell size variation

  // Back layer — same grid, offset half a cell, drawn underneath
  List<double> _backHueOffsets = [];
  List<double> _backBrightOffsets = [];
  List<double> _backWobblePhaseX = [];
  List<double> _backWobblePhaseY = [];
  List<double> _backWobbleSpeed = [];
  List<double> _backSizeJitter = [];
  List<double> _backCellOffsetX = [];
  List<double> _backCellOffsetY = [];
  List<double> _backCellVelX = [];
  List<double> _backCellVelY = [];
  List<double> _backCellMass = [];
  List<double> _backBeatForceX = [];
  List<double> _backBeatForceY = [];
  bool _gridInitialized = false;

  // Wave propagation
  static const double _spreadRate = 0.22;
  static const double _decayRate = 0.993;
  // Max glow increase per tick — prevents sudden flashes
  static const double _glowRiseRate = 0.07;

  // Animation
  late Ticker _ticker;
  int _tickCount = 0;

  // Idle patterns
  int _idleTicks = 0; // ticks since last input
  static const int _idleThreshold = 150; // ~2.5 seconds at 60fps
  int _currentPattern = 0;
  double _patternPhase = 0;
  static const int _patternCount = 5;

  // Color sweep — wave that recolors cells as it passes
  bool _colorSweepActive = false;
  double _colorSweepPhase = 0;
  int _colorSweepPattern = 0;
  int _nextColorSeed = 0;
  double _nextHueAnchor = 0;
  List<double> _nextHueOffsets = [];
  List<double> _nextBrightOffsets = [];

  // Sound novelty detection — cache recent fingerprints
  static const int _fpCacheSize = 5;
  static const double _noveltyThreshold = 0.35; // euclidean distance to count as "new"
  final List<List<double>> _recentFingerprints = [];
  bool _noveltyPatternActive = false;
  double _noveltyPatternPhase = 0;
  int _noveltyPattern = 0;

  // Debug
  bool _showDebug = false;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();

    _colorSeed = DateTime.now().millisecondsSinceEpoch;
    _initGrid(_visibleRows);

    // Accelerometer
    _accelSub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 50),
    ).listen((event) {
      // Shake velocity: raw accel minus smoothed (removes gravity)
      _shakeVx = (event.x - _x) * _inertiaScale;
      _shakeVy = (event.y - _y) * _inertiaScale;

      // Integrate linear acceleration for displacement-based shake detection
      const double dt = 0.05; // 50ms sampling
      final linAx = event.x - _x; // linear accel (gravity removed)
      final linAy = event.y - _y;
      _linVx += linAx * dt;
      _linVy += linAy * dt;
      _dispX += _linVx * dt;
      _dispY += _linVy * dt;

      final dispMag = sqrt(_dispX * _dispX + _dispY * _dispY);
      final now = DateTime.now().millisecondsSinceEpoch;

      if (dispMag > _displacementThreshold) {
        if (_hasFirstStroke) {
          // Check if this stroke is roughly opposite to the first
          final dot = _dispX * _strokeDx + _dispY * _strokeDy;
          if (dot < 0 &&
              now - _strokeTime < _shakeWindowMs &&
              now - _lastShakeShuffle > _shakeCooldownMs) {
            _lastShakeShuffle = now;
            _colorSeed = now;
            _hueAnchor = Random(_colorSeed).nextDouble() * 360;
            _shuffleColors();
            _hasFirstStroke = false;
          } else {
            // Replace with new first stroke
            _strokeDx = _dispX;
            _strokeDy = _dispY;
            _strokeTime = now;
          }
        } else {
          // Record first stroke
          _strokeDx = _dispX;
          _strokeDy = _dispY;
          _strokeTime = now;
          _hasFirstStroke = true;
        }
        // Reset integration after recording stroke
        _linVx = 0; _linVy = 0;
        _dispX = 0; _dispY = 0;
      }

      // Expire stale first stroke
      if (_hasFirstStroke && now - _strokeTime > _shakeWindowMs) {
        _hasFirstStroke = false;
      }

      // Decay velocity aggressively to fight drift
      _linVx *= 0.8;
      _linVy *= 0.8;

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
    // Seeded random for reproducible color palette
    final colorRng = Random(_colorSeed);
    _random = Random();
    _glow = List.filled(total, 0.0);
    _glowTarget = List.filled(total, 0.0);
    _glowNext = List.filled(total, 0.0);
    _audioHue = List.filled(total, 0.0);
    _audioHueTarget = List.filled(total, 0.0);
    _audioHueNext = List.filled(total, 0.0);
    _hueOffsets = List.generate(total, (_) => colorRng.nextDouble() * 60 - 30);
    _brightOffsets =
        List.generate(total, (_) => colorRng.nextDouble() * 0.3 - 0.15);
    _wobblePhaseX = List.generate(total, (_) => _random.nextDouble() * 2 * pi);
    _wobblePhaseY = List.generate(total, (_) => _random.nextDouble() * 2 * pi);
    _wobbleSpeed = List.generate(total, (_) => 0.3 + _random.nextDouble() * 0.7);
    _sizeJitter = List.generate(total, (_) => 0.85 + colorRng.nextDouble() * 0.15);
    _cellOffsetX = List.filled(total, 0.0);
    _cellOffsetY = List.filled(total, 0.0);
    _cellVelX = List.filled(total, 0.0);
    _cellVelY = List.filled(total, 0.0);
    _beatForceX = List.filled(total, 0.0);
    _beatForceY = List.filled(total, 0.0);
    _cellMass = List.generate(total, (_) => colorRng.nextDouble() * 20.0 + 200.0 );

    // Back layer
    final backRng = Random(_colorSeed + 1);
    _backHueOffsets = List.generate(total, (_) => backRng.nextDouble() * 60 - 30);
    _backBrightOffsets = List.generate(total, (_) => backRng.nextDouble() * 0.3 - 0.15);
    _backWobblePhaseX = List.generate(total, (_) => _random.nextDouble() * 2 * pi);
    _backWobblePhaseY = List.generate(total, (_) => _random.nextDouble() * 2 * pi);
    _backWobbleSpeed = List.generate(total, (_) => 0.3 + _random.nextDouble() * 0.7);
    _backSizeJitter = List.generate(total, (_) => 0.85 + backRng.nextDouble() * 0.15);
    _backCellOffsetX = List.filled(total, 0.0);
    _backCellOffsetY = List.filled(total, 0.0);
    _backCellVelX = List.filled(total, 0.0);
    _backCellVelY = List.filled(total, 0.0);
    _backCellMass = List.generate(total, (_) => backRng.nextDouble() * 20.0 + 80.0);
    _backBeatForceX = List.filled(total, 0.0);
    _backBeatForceY = List.filled(total, 0.0);
    _gridInitialized = true;
  }

  void _shuffleColors() {
    final total = _total;
    final colorRng = Random(_colorSeed);
    _hueOffsets = List.generate(total, (_) => colorRng.nextDouble() * 60 - 30);
    _brightOffsets =
        List.generate(total, (_) => colorRng.nextDouble() * 0.3 - 0.15);
  }

  void _startColorSweep() {
    _nextColorSeed = DateTime.now().millisecondsSinceEpoch;
    _nextHueAnchor = Random(_nextColorSeed).nextDouble() * 360;
    final total = _total;
    final colorRng = Random(_nextColorSeed);
    _nextHueOffsets = List.generate(total, (_) => colorRng.nextDouble() * 60 - 30);
    _nextBrightOffsets = List.generate(total, (_) => colorRng.nextDouble() * 0.3 - 0.15);
    _colorSweepActive = true;
    _colorSweepPhase = -4.0;
    _colorSweepPattern = _random.nextInt(_patternCount);
  }

  void _advanceColorSweep() {
    _colorSweepPhase += 0.15; // slow ripple
    final maxDist = (_rows + _cols).toDouble();
    if (_colorSweepPhase > maxDist + 6) {
      // Sweep finished — commit the new colors
      _colorSeed = _nextColorSeed;
      _hueAnchor = _nextHueAnchor;
      _hueOffsets = _nextHueOffsets;
      _brightOffsets = _nextBrightOffsets;
      _colorSweepActive = false;
      return;
    }

    // Gradually lerp hue anchor toward target
    var anchorDiff = _nextHueAnchor - _hueAnchor;
    if (anchorDiff > 180) anchorDiff -= 360;
    if (anchorDiff < -180) anchorDiff += 360;
    _hueAnchor = (_hueAnchor + anchorDiff * 0.02) % 360;
    if (_hueAnchor < 0) _hueAnchor += 360;

    final phase = _colorSweepPhase;
    const waveWidth = 5.0; // wide transition zone

    for (var r = 0; r < _rows; r++) {
      for (var c = 0; c < _cols; c++) {
        double dist;
        switch (_colorSweepPattern) {
          case 0:
            final cr = _rows / 2.0;
            final cc = _cols / 2.0;
            dist = sqrt((r - cr) * (r - cr) + (c - cc) * (c - cc));
            break;
          case 1:
            dist = c.toDouble();
            break;
          case 2:
            dist = (_cols - 1 - c).toDouble();
            break;
          case 3:
            dist = (r + c) * 0.7;
            break;
          case 4:
          default:
            dist = (_rows + _cols - 2 - r - c) * 0.7;
            break;
        }

        final idx = r * _cols + c;
        // Blend zone: cells within the wavefront gradually transition
        final progress = ((phase - dist) / waveWidth).clamp(0.0, 1.0);
        if (progress > 0) {
          final t = progress * progress; // ease-in for smooth blend
          _hueOffsets[idx] += (_nextHueOffsets[idx] - _hueOffsets[idx]) * t * 0.05;
          _brightOffsets[idx] += (_nextBrightOffsets[idx] - _brightOffsets[idx]) * t * 0.05;
        }
        // Soft glow at the wavefront
        final diff = (phase - dist).abs();
        if (diff < waveWidth) {
          final wave = 1.0 - diff / waveWidth;
          _glowTarget[idx] = max(_glowTarget[idx], wave * wave * 0.4);
        }
      }
    }
  }

  String _micStatus = 'init';

  Future<void> _startMic() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      _micStatus = 'denied: $status';
      return;
    }

    try {
      await _audioCapture.init();
      await _audioCapture.start(
        _onAudioData,
        _onAudioError,
        sampleRate: 44100,
        bufferSize: 2048,
      );
      _micStarted = true;
      _micStatus = 'started';
    } catch (e) {
      _micStatus = 'error: $e';
    }
  }

  int _audioCallbackCount = 0;

  void _onAudioData(dynamic data) {
    _audioCallbackCount++;

    List<double> samples;
    if (data is Float64List) {
      samples = data.toList();
    } else if (data is List) {
      try {
        samples = List<double>.from(data);
      } catch (_) {
        _micStatus = 'bad data: ${data.runtimeType}';
        return;
      }
    } else {
      _micStatus = 'unknown type: ${data.runtimeType}';
      return;
    }

    _analyzer.analyze(samples);

    if (!_gridInitialized) return;

    final rms = _analyzer.rms;
    if (rms < 0.003) return; // silence threshold

    _idleTicks = 0; // any sound above silence threshold resets idle

    // Spectral centroid for hue derivation (overall tonal color)
    double centroid = 0;
    double totalEnergy = 0;
    for (var b = 0; b < 8; b++) {
      final e = _analyzer.bandEnergy(b);
      centroid += b * e;
      totalEnergy += e;
    }
    if (totalEnergy > 0) centroid /= totalEnergy;
    // Hue from spectral centroid — overall sound color
    final soundHue = (centroid / 7.0 * 360) % 360;

    final loudness = (rms * 50).clamp(0.0, 1.0);

    // Per-band: pick a rect deterministically from frequency, spawn a pattern from it
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final canSpawnRipple = nowMs - _lastRippleMs >= 120;
    final quietBoost = rms < 0.015 ? 6.0 : (rms < 0.03 ? 4.0 : (rms < 0.06 ? 2.0 : 1.0));

    for (var b = 0; b < 8; b++) {
      final energy = _analyzer.bandEnergy(b);
      if (energy < 0.000005) continue;
      if (energy <= _prevBandEnergy[b] * 0.90) continue;

      final bandLoudness = sqrt((energy * 80 * quietBoost).clamp(0.0, 1.0));
      final speed = 0.15 + (b / 7.0) * 0.2;
      final force = sqrt((energy * 100 * quietBoost).clamp(0.0, 4.0));
      final bandHue = (soundHue + b * 30) % 360;

      // --- Origin selection: varies by band character ---
      int originC, originR;
      final waveSeed = nowMs + b;
      final patRng = Random(waveSeed);
      final transientRatio = _prevBandEnergy[b] > 0.00001
          ? energy / _prevBandEnergy[b]
          : 10.0;

      if (transientRatio > 5.0) {
        // Sharp transient: random position for surprise
        originC = patRng.nextInt(_cols);
        originR = patRng.nextInt(_rows);
      } else if (b >= 6) {
        // High freq: edges and corners — shimmer from the periphery
        final edge = patRng.nextInt(4);
        originC = edge < 2 ? (edge == 0 ? 0 : _cols - 1) : patRng.nextInt(_cols);
        originR = edge >= 2 ? (edge == 2 ? 0 : _rows - 1) : patRng.nextInt(_rows);
      } else {
        // Mid bands: original mapping — band selects column, energy selects row
        originC = ((b / 7.0) * (_cols - 1)).round().clamp(0, _cols - 1);
        originR = ((energy * 5000).clamp(0.0, 1.0) * (_rows - 1)).round().clamp(0, _rows - 1);
      }
      originC = originC.clamp(0, _cols - 1);
      originR = originR.clamp(0, _rows - 1);


      // Cooldown: only spawn ripples/patterns every 120ms
      if (!canSpawnRipple) continue;

      // Light up the origin square and ripple outward from it
      final originIdx = originR * _cols + originC;
      if (originIdx >= 0 && originIdx < _glowTarget.length) {
        _glowTarget[originIdx] = max(_glowTarget[originIdx], bandLoudness);
        _audioHueTarget[originIdx] = bandHue;
      }
      // Softer sounds ripple fewer cells
      final maxRad = 3.0 + bandLoudness * (_rows + _cols) * 0.5;
      _tapRipples.add(_TapRipple(col: originC, row: originR, hue: bandHue, force: 3.0, maxRadius: maxRad));
      _lastRippleMs = nowMs;

      // --- Pattern selection: audio-reactive, not just random ---
      _WavePattern pattern;
      double patternForce = force;
      double patternSpeed = speed;

      if (transientRatio > 5.0) {
        // Sharp transient (any band): explosive grow or shockwave
        pattern = patRng.nextBool() ? _WavePattern.grow : _WavePattern.shockwave;
        patternForce = force * 1.0;
        patternSpeed = speed * 1.4;
      } else if (b >= 6) {
        // High freq: rain or spiral — delicate, fast
        pattern = patRng.nextBool() ? _WavePattern.rain : _WavePattern.spiral;
        patternForce = force * 0.4;
        patternSpeed = speed * 1.6;
      } else if (b >= 4) {
        // Upper mids: spiral or snake — flowing motion
        pattern = patRng.nextBool() ? _WavePattern.spiral : _WavePattern.snake;
        patternForce = force * 0.7;
        patternSpeed = speed * 1.2;
      } else {
        // Lower mids: tetris or grow — chunky, moderate push
        final choices = [_WavePattern.tetris, _WavePattern.grow, _WavePattern.cross];
        pattern = choices[patRng.nextInt(choices.length)];
        patternForce = force * 0.8;
      }

      final path = _generatePath(pattern, originR, originC, patRng);

      _audioWaves.add(_AudioWave(
        intensity: bandLoudness,
        hue: bandHue,
        speed: patternSpeed,
        beatForce: patternForce,
        originR: originR.toDouble(),
        originC: originC.toDouble(),
        pattern: pattern,
        seed: waveSeed,
        path: path,
      ));
    }

    // Update per-band previous energy
    for (var b = 0; b < 8; b++) {
      _prevBandEnergy[b] = _analyzer.bandEnergy(b);
    }
    _prevRms = rms;

    // Novelty detection: compare current fingerprint against recent cache
    final fp = _analyzer.fingerprint;
    if (rms > 0.01) {
      double minDist = double.infinity;
      int closestIdx = -1;
      for (var j = 0; j < _recentFingerprints.length; j++) {
        double dist = 0;
        for (var i = 0; i < 8; i++) {
          final d = fp[i] - _recentFingerprints[j][i];
          dist += d * d;
        }
        dist = sqrt(dist);
        if (dist < minDist) {
          minDist = dist;
          closestIdx = j;
        }
      }

      if (_recentFingerprints.isEmpty || minDist > _noveltyThreshold) {
        // New sound detected — trigger a pattern sweep
        _noveltyPatternActive = true;
        _noveltyPatternPhase = -4.0;
        _noveltyPattern = _random.nextInt(_patternCount);
        // Also start a color sweep if one isn't already running
        if (!_colorSweepActive) {
          _startColorSweep();
        }
        // Add new fingerprint to cache
        _recentFingerprints.add(List<double>.from(fp));
        if (_recentFingerprints.length > _fpCacheSize) {
          _recentFingerprints.removeAt(0);
        }
      } else {
        // Same sound — refresh the cache entry so it doesn't expire
        _recentFingerprints[closestIdx] = List<double>.from(fp);
      }
    }
  }

  void _onAudioError(Object error) {
    debugPrint('Audio error: $error');
  }

  void _applyNoveltyPattern() {
    _noveltyPatternPhase += 0.15; // faster than idle
    final maxDist = (_rows + _cols).toDouble();
    if (_noveltyPatternPhase > maxDist + 4) {
      _noveltyPatternActive = false;
      return;
    }

    final phase = _noveltyPatternPhase;
    const intensity = 0.4;
    const waveWidth = 3.0;

    for (var r = 0; r < _rows; r++) {
      for (var c = 0; c < _cols; c++) {
        double dist;
        switch (_noveltyPattern) {
          case 0: // center outward
            final cr = _rows / 2.0;
            final cc = _cols / 2.0;
            dist = sqrt((r - cr) * (r - cr) + (c - cc) * (c - cc));
            break;
          case 1:
            dist = c.toDouble();
            break;
          case 2:
            dist = (_cols - 1 - c).toDouble();
            break;
          case 3:
            dist = (r + c) * 0.7;
            break;
          case 4:
          default:
            dist = (_rows + _cols - 2 - r - c) * 0.7;
            break;
        }

        final diff = (phase - dist).abs();
        if (diff < waveWidth) {
          final wave = (1.0 - diff / waveWidth);
          final idx = r * _cols + c;
          _glowTarget[idx] = max(_glowTarget[idx], wave * wave * intensity);
        }
      }
    }
  }

  double _idleHue = 0; // slowly drifting hue for idle ripples

  int _lastIdleRippleMs = 0;

  void _applyIdlePattern() {
    _patternPhase += 0.03;
    _idleHue = (_idleHue + 0.5) % 360;
    final maxDist = (_rows + _cols).toDouble();
    if (_patternPhase > maxDist + 1) {
      _patternPhase = -2.0;
      _currentPattern = (_currentPattern + 1) % _patternCount;
    }

    final phase = _patternPhase;
    const waveWidth = 5.0;

    for (var r = 0; r < _rows; r++) {
      for (var c = 0; c < _cols; c++) {
        double dist;
        switch (_currentPattern) {
          case 0:
            final cr = _rows / 2.0;
            final cc = _cols / 2.0;
            dist = sqrt((r - cr) * (r - cr) + (c - cc) * (c - cc));
            break;
          case 1:
            dist = c.toDouble();
            break;
          case 2:
            dist = (_cols - 1 - c).toDouble();
            break;
          case 3:
            dist = (r + c) * 0.7;
            break;
          case 4:
          default:
            dist = (_rows + _cols - 2 - r - c) * 0.7;
            break;
        }

        final diff = (phase - dist).abs();
        if (diff < waveWidth) {
          final wave = (1.0 - diff / waveWidth);
          final strength = wave * wave;
          final idx = r * _cols + c;
          _glowTarget[idx] = max(_glowTarget[idx], strength * 0.7);
        }
      }
    }

    // Spawn actual ripples frequently — same as audio/tap ripples
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastIdleRippleMs > 800) {
      _lastIdleRippleMs = nowMs;
      final rng = Random(nowMs);
      final rc = rng.nextInt(_rows);
      final cc = rng.nextInt(_cols);
      _tapRipples.add(_TapRipple(
        col: cc, row: rc, force: 0.3,
        maxRadius: 4.0 + rng.nextDouble() * 6.0,
      ));

      // Occasionally trigger a full color sweep — new hue palette
      if (!_colorSweepActive && rng.nextInt(8) == 0) {
        _startColorSweep();
      }
    }
  }

  void _onTick(Duration elapsed) {
    if (!_gridInitialized) return;
    _tickCount++;
    _idleTicks++;
    _beatFlash *= 0.85; // rapid decay — sharp pulse


    // Tap ripples
    _advanceTapRipples();

    // Audio waves — expanding rings from beats
    _advanceAudioWaves();

    // Color sweep — triggered by novel sounds
    if (_colorSweepActive) {
      _advanceColorSweep();
    }

    // Novelty pattern: one-shot sweep when a new sound is heard
    if (_noveltyPatternActive) {
      _applyNoveltyPattern();
    }

    // Idle patterns when no audio for a while
    if (_idleTicks > _idleThreshold) {
      _applyIdlePattern();
    }

    // Ease _glow toward _glowTarget (never jump instantly)
    final glowLen = _glow.length;
    for (var i = 0; i < glowLen; i++) {
      if (_glowTarget[i] > _glow[i]) {
        _glow[i] = min(_glow[i] + _glowRiseRate, _glowTarget[i]);
      }
      // Decay target so it doesn't stay pegged
      _glowTarget[i] *= _decayRate;
    }

    // Propagate glow
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
          _audioHueTarget[idx] = _audioHueTarget[bestNeighbor];
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

    // Hue inertia: lerp displayed hue toward target each frame
    const hueInertia = 0.12; // 0 = frozen, 1 = instant snap
    for (var i = 0; i < glowLen; i++) {
      var diff = _audioHueTarget[i] - _audioHue[i];
      // Shortest path around the 360 circle
      if (diff > 180) diff -= 360;
      if (diff < -180) diff += 360;
      _audioHue[i] = (_audioHue[i] + diff * hueInertia) % 360;
      if (_audioHue[i] < 0) _audioHue[i] += 360;
    }

    // Global shake from audio: sum beat forces to push the whole grid
    double audioShakeX = 0, audioShakeY = 0;
    for (var i = 0; i < glowLen; i++) {
      audioShakeX += _beatForceX[i];
      audioShakeY += _beatForceY[i];
    }
    // Normalize and scale — less force as requested
    final audioShakeScale = 0.003;
    _shakeVx += audioShakeX * audioShakeScale;
    _shakeVy += audioShakeY * audioShakeScale;

    // Per-cell spring physics: accel + beat forces push, spring pulls back
    final totalShakeX = _shakeVx;
    final totalShakeY = _shakeVy;
    final glLen = _cellOffsetX.length;
    const maxOffset = 60.0; // hard clamp to prevent runaway
    const maxVel = 15.0;

    void _stepPhysics(
      List<double> offX, List<double> offY,
      List<double> velX, List<double> velY,
      List<double> massArr,
      List<double> bfX, List<double> bfY,
      double springPhase,
    ) {
      for (var i = 0; i < glLen; i++) {
        final mass = massArr[i].clamp(0.1, 10.0);
        velX[i] += totalShakeX / mass;
        velY[i] += totalShakeY / mass;
        velX[i] += bfX[i] / mass;
        velY[i] += bfY[i] / mass;
        bfX[i] *= 0.90;
        bfY[i] *= 0.90;
        final springMod = 1.0;
        // 0.9 + 0.1 * sin(_tickCount * 0.052 + springPhase);
        final k = _springK * springMod;
        final dx = offX[i];
        final dy = offY[i];
        final dist2 = dx * dx + dy * dy;
        final hystK = k + dist2 * 0.0005;
        velX[i] -= dx * hystK;
        velY[i] -= dy * hystK;
        // Friction: base damping + velocity-dependent drag
        final speed2 = velX[i] * velX[i] + velY[i] * velY[i];
        final drag = speed2 > 25 ? _damping * 0.85 : _damping;
        velX[i] *= drag;
        velY[i] *= drag;
        // Clamp velocity
        velX[i] = velX[i].clamp(-maxVel, maxVel);
        velY[i] = velY[i].clamp(-maxVel, maxVel);
        // NaN guard
        if (velX[i].isNaN) velX[i] = 0;
        if (velY[i].isNaN) velY[i] = 0;
        offX[i] += velX[i];
        offY[i] += velY[i];
        offX[i] = offX[i].clamp(-maxOffset, maxOffset);
        offY[i] = offY[i].clamp(-maxOffset, maxOffset);
        if (offX[i].isNaN) offX[i] = 0;
        if (offY[i].isNaN) offY[i] = 0;
      }
    }

    _stepPhysics(_cellOffsetX, _cellOffsetY, _cellVelX, _cellVelY,
        _cellMass, _beatForceX, _beatForceY, 0);
    _stepPhysics(_backCellOffsetX, _backCellOffsetY, _backCellVelX, _backCellVelY,
        _backCellMass, _backBeatForceX, _backBeatForceY, pi);

    setState(() {});
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    if (_micStarted) _audioCapture.stop();
    _ticker.dispose();
    WakelockPlus.disable();
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

  void _onTap(Offset position) {
    if (!_gridInitialized) return;
    _idleTicks = 0;
    final cellSize = MediaQuery.of(context).size.width / _visibleCols;
    final tapCol = (position.dx / cellSize).floor() + _extraCols;
    final tapRow = (position.dy / cellSize).floor() + _extraRows;
    if (tapCol < 0 || tapCol >= _cols || tapRow < 0 || tapRow >= _rows) return;

    // Big color ripple from tap
    final tapHue = (_random.nextDouble() * 360);
    _tapRipples.add(_TapRipple(
      col: tapCol, row: tapRow, hue: tapHue, force: 3.0,
      maxRadius: (_rows + _cols).toDouble(),
    ));

    // Also spawn an audio wave pattern for extra visual punch
    final rng = Random(DateTime.now().millisecondsSinceEpoch);
    final patterns = [_WavePattern.shockwave, _WavePattern.spiral, _WavePattern.cross];
    final pattern = patterns[rng.nextInt(patterns.length)];
    final path = _generatePath(pattern, tapRow, tapCol, rng);
    _audioWaves.add(_AudioWave(
      intensity: 0.8,
      hue: tapHue,
      speed: 0.2,
      beatForce: 2.0,
      originR: tapRow.toDouble(),
      originC: tapCol.toDouble(),
      pattern: pattern,
      seed: rng.nextInt(99999),
      path: path,
    ));

    // Trigger a color sweep on every other tap
    if (!_colorSweepActive && rng.nextBool()) {
      _startColorSweep();
    }
  }

  final List<_TapRipple> _tapRipples = [];

  void _advanceTapRipples() {
    final total = _glow.length;

    // Track per-cell wave hits: sum of direction vectors weighted by strength
    // When multiple waves overlap, the resultant force = dominant direction
    final waveDirX = List<double>.filled(total, 0.0);
    final waveDirY = List<double>.filled(total, 0.0);
    final waveCount = List<int>.filled(total, 0);

    for (final ripple in _tapRipples) {
      ripple.phase += 0.18;
      if (ripple.phase > ripple.maxRadius) continue; // stop expanding
      const intensity = 1.0;
      const waveWidth = 3.5;

      for (var r = 0; r < _rows; r++) {
        for (var c = 0; c < _cols; c++) {
          final dr = r - ripple.row;
          final dc = c - ripple.col;
          final dist = sqrt((dr * dr + dc * dc).toDouble());
          final diff = (ripple.phase - dist).abs();
          if (diff > waveWidth) continue;

          final wave = (1.0 - diff / waveWidth);
          final idx = r * _cols + c;
          if (idx >= 0 && idx < total) {
            final strength = wave * wave * intensity;
            _glowTarget[idx] = max(_glowTarget[idx], strength);
            // Color ripple: audio ripples paint their hue onto cells
            if (ripple.hue != null && strength > 0.1) {
              _audioHueTarget[idx] = ripple.hue!;
            }

            // Accumulate wave direction per cell
            if (dist > 0.5) {
              final nx = dc / dist;
              final ny = dr / dist;
              waveDirX[idx] += nx * strength * ripple.force;
              waveDirY[idx] += ny * strength * ripple.force;
              waveCount[idx]++;
            }
          }
        }
      }
    }

    // Apply forces: cells with multiple wave hits get extra interference force
    for (var i = 0; i < total; i++) {
      final dx = waveDirX[i];
      final dy = waveDirY[i];
      _beatForceX[i] += dx;
      _beatForceY[i] += dy;
      _backBeatForceX[i] += dx;
      _backBeatForceY[i] += dy;

      // Interference boost: when 2+ waves meet, amplify the resultant force
      if (waveCount[i] >= 2) {
        final boost = 1.5;
        final mag = sqrt(dx * dx + dy * dy);
        if (mag > 0.01) {
          _beatForceX[i] += dx / mag * mag * boost;
          _beatForceY[i] += dy / mag * mag * boost;
          _backBeatForceX[i] += dx / mag * mag * boost;
          _backBeatForceY[i] += dy / mag * mag * boost;
          // Also boost glow at interference points
          _glowTarget[i] = min(1.0, _glowTarget[i] + 0.2 * waveCount[i]);
        }
      }
    }

    // Remove finished ripples
    _tapRipples.removeWhere((r) => r.phase > min(r.maxRadius + 4, (_rows + _cols).toDouble()));
  }

  // Generate a path of [row, col] cells for pattern-based waves
  List<List<int>> _generatePath(_WavePattern pattern, int startR, int startC, Random rng) {
    final path = <List<int>>[];
    var r = startR.clamp(0, _rows - 1);
    var c = startC.clamp(0, _cols - 1);

    switch (pattern) {
      case _WavePattern.snake:
        // Random walk that prefers a direction (glider-like diagonal movement)
        final dirR = rng.nextBool() ? 1 : -1;
        final dirC = rng.nextBool() ? 1 : -1;
        for (var step = 0; step < 40; step++) {
          path.add([r, c]);
          // Glider-like: mostly diagonal, occasionally straight
          if (rng.nextDouble() < 0.7) {
            r += dirR;
            c += dirC;
          } else if (rng.nextBool()) {
            r += dirR;
          } else {
            c += dirC;
          }
          r = r.clamp(0, _rows - 1);
          c = c.clamp(0, _cols - 1);
        }
        break;

      case _WavePattern.grow:
        // Flood-fill like growth from center — BFS order
        final visited = <int>{};
        final queue = <List<int>>[[r, c]];
        while (queue.isNotEmpty && path.length < 20) {
          final idx = rng.nextInt(queue.length);
          final cell = queue.removeAt(idx);
          final key = cell[0] * _cols + cell[1];
          if (visited.contains(key)) continue;
          visited.add(key);
          path.add(cell);
          // Add neighbors in random order
          for (final d in [[-1,0],[1,0],[0,-1],[0,1]]..shuffle(rng)) {
            final nr = cell[0] + d[0];
            final nc = cell[1] + d[1];
            if (nr >= 0 && nr < _rows && nc >= 0 && nc < _cols) {
              queue.add([nr, nc]);
            }
          }
        }
        break;

      case _WavePattern.tetris:
        // Small connected shapes (3-5 cells) that glide diagonally
        // First generate a small tetromino-like shape
        final shape = <List<int>>[[0, 0]];
        for (var i = 0; i < 3 + rng.nextInt(3); i++) {
          final base = shape[rng.nextInt(shape.length)];
          final dirs = [[-1,0],[1,0],[0,-1],[0,1]];
          final d = dirs[rng.nextInt(4)];
          final nr = base[0] + d[0];
          final nc = base[1] + d[1];
          if (!shape.any((s) => s[0] == nr && s[1] == nc)) {
            shape.add([nr, nc]);
          }
        }
        // Now glide the shape diagonally across the grid
        final dR = rng.nextBool() ? 1 : -1;
        final dC = rng.nextBool() ? 1 : -1;
        for (var step = 0; step < 30; step++) {
          for (final s in shape) {
            final pr = r + s[0];
            final pc = c + s[1];
            if (pr >= 0 && pr < _rows && pc >= 0 && pc < _cols) {
              path.add([pr, pc]);
            }
          }
          r += dR;
          c += dC;
          r = r.clamp(0, _rows - 1);
          c = c.clamp(0, _cols - 1);
        }
        break;

      case _WavePattern.spiral:
        // Archimedean spiral outward from origin
        for (var step = 0; step < 50; step++) {
          final angle = step * 0.6;
          final radius = step * 0.3;
          final sr = startR + (sin(angle) * radius).round();
          final sc = startC + (cos(angle) * radius).round();
          if (sr >= 0 && sr < _rows && sc >= 0 && sc < _cols) {
            path.add([sr, sc]);
          }
        }
        break;

      case _WavePattern.shockwave:
        // Concentric diamond rings expanding outward (manhattan distance)
        for (var ring = 0; ring < (_rows + _cols) ~/ 2; ring++) {
          final cells = <List<int>>[];
          for (var dr = -ring; dr <= ring; dr++) {
            final dc = ring - dr.abs();
            for (final d in [dc, -dc]) {
              final sr = startR + dr;
              final sc = startC + d;
              if (sr >= 0 && sr < _rows && sc >= 0 && sc < _cols) {
                cells.add([sr, sc]);
              }
            }
          }
          cells.shuffle(rng);
          path.addAll(cells);
        }
        break;

      case _WavePattern.rain:
        // Vertical columns dropping down from origin row
        final width = 2 + rng.nextInt(4);
        final startCol = (startC - width ~/ 2).clamp(0, _cols - 1);
        final endCol = (startC + width ~/ 2).clamp(0, _cols - 1);
        for (var row = startR; row < _rows; row++) {
          for (var col = startCol; col <= endCol; col++) {
            path.add([row, col]);
          }
        }
        // Wrap around top
        for (var row = 0; row < startR; row++) {
          for (var col = startCol; col <= endCol; col++) {
            path.add([row, col]);
          }
        }
        break;

      case _WavePattern.cross:
        // Expanding cross / plus pattern — arms grow simultaneously
        for (var arm = 1; arm < (_rows + _cols) ~/ 2; arm++) {
          for (final d in [
            [arm, 0], [-arm, 0], [0, arm], [0, -arm], // cardinal
            [arm, arm], [-arm, -arm], [arm, -arm], [-arm, arm], // diagonal
          ]) {
            final sr = startR + d[0];
            final sc = startC + d[1];
            if (sr >= 0 && sr < _rows && sc >= 0 && sc < _cols) {
              path.add([sr, sc]);
            }
          }
        }
        break;

      case _WavePattern.radial:
        break; // radial doesn't use path
    }
    return path;
  }

  void _advanceAudioWaves() {
    final total = _glow.length;
    final maxDist = sqrt((_rows * _rows + _cols * _cols).toDouble());

    for (final wave in _audioWaves) {
      wave.phase += wave.speed;

      if (wave.pattern == _WavePattern.radial) {
        // Original expanding ring
        const waveWidth = 2.5;
        final or = wave.originR;
        final oc = wave.originC;
        for (var r = 0; r < _rows; r++) {
          for (var c = 0; c < _cols; c++) {
            final dr = r - or;
            final dc = c - oc;
            final dist = sqrt(dr * dr + dc * dc);
            final diff = (wave.phase - dist).abs();
            if (diff > waveWidth) continue;

            final falloff = 1.0 - diff / waveWidth;
            final v = falloff * falloff * wave.intensity;
            final idx = r * _cols + c;
            if (idx < 0 || idx >= total) continue;

            if (v > _glowTarget[idx]) _audioHueTarget[idx] = wave.hue;
            _glowTarget[idx] = max(_glowTarget[idx], v);

            if (dist > 0.5 && wave.beatForce > 0) {
              final force = wave.beatForce * falloff * falloff;
              final nx = dc / dist;
              final ny = dr / dist;
              _beatForceX[idx] += nx * force;
              _beatForceY[idx] += ny * force;
              _backBeatForceX[idx] += nx * force;
              _backBeatForceY[idx] += ny * force;
            }
          }
        }
      } else if (wave.path != null) {
        // Path-based patterns: light up cells along the path sequentially
        final path = wave.path!;
        // Beat-synced patterns advance via beatStep, others via phase
        final headPos = wave.beatSynced ? wave.beatStep : (wave.phase * 3).floor();
        const tailLen = 8; // how many cells stay lit behind the head

        for (var i = max(0, headPos - tailLen); i < min(headPos, path.length); i++) {
          final cell = path[i];
          final r = cell[0];
          final c = cell[1];
          if (r < 0 || r >= _rows || c < 0 || c >= _cols) continue;
          final idx = r * _cols + c;
          if (idx < 0 || idx >= total) continue;

          // Fade: brightest at head, fading toward tail
          final age = (headPos - i) / tailLen;
          final v = wave.intensity * (1.0 - age) * (1.0 - age);

          if (v > _glowTarget[idx]) _audioHueTarget[idx] = wave.hue;
          _glowTarget[idx] = max(_glowTarget[idx], v);

          // Pattern-specific force behavior
          if (wave.beatForce > 0) {
            double fx = 0, fy = 0;
            if (wave.pattern == _WavePattern.shockwave || wave.pattern == _WavePattern.cross) {
              // Outward explosion from origin
              final dr = r - wave.originR;
              final dc = c - wave.originC;
              final d = sqrt(dr * dr + dc * dc);
              if (d > 0.3) {
                final force = wave.beatForce * v * 0.4;
                fx = dc / d * force;
                fy = dr / d * force;
              }
            } else if (wave.pattern == _WavePattern.rain) {
              // Downward gravity pull
              final force = wave.beatForce * v * 0.25;
              fy = force;
              // Slight horizontal scatter
              fx = (((idx * 7) % 5) - 2) * force * 0.1;
            } else if (wave.pattern == _WavePattern.spiral) {
              // Tangential swirl force (perpendicular to radius)
              final dr = r - wave.originR;
              final dc = c - wave.originC;
              final d = sqrt(dr * dr + dc * dc);
              if (d > 0.3) {
                final force = wave.beatForce * v * 0.3;
                // Perpendicular = rotate 90 degrees
                fx = -dr / d * force;
                fy = dc / d * force;
              }
            } else if (i + 1 < path.length) {
              // Default: push in path direction (snake, tetris, grow)
              final next = path[min(i + 1, path.length - 1)];
              final dr = (next[0] - r).toDouble();
              final dc = (next[1] - c).toDouble();
              final d = sqrt(dr * dr + dc * dc);
              if (d > 0.1) {
                final force = wave.beatForce * v * 0.2;
                fx = dc / d * force;
                fy = dr / d * force;
              }
            }
            _beatForceX[idx] += fx;
            _beatForceY[idx] += fy;
            _backBeatForceX[idx] += fx;
            _backBeatForceY[idx] += fy;
          }
        }
      }
    }

    // Remove finished waves
    _audioWaves.removeWhere((w) {
      if (w.pattern == _WavePattern.radial) return w.phase > maxDist + 4;
      if (w.beatSynced && w.path != null) return w.beatStep > w.path!.length + 10;
      if (w.path != null) return (w.phase * 3).floor() > w.path!.length + 8;
      return w.phase > 30;
    });
  }

  double _tiltHue() {
    final nx = (_x / 10.0).clamp(-1.0, 1.0);
    final ny = (_y / 10.0).clamp(-1.0, 1.0);
    return (atan2(ny, nx) * 180 / pi + _hueAnchor) % 360;
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
          GestureDetector(
            onTapDown: (details) => _onTap(details.localPosition),
            child: LayoutBuilder(
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
                  sizeJitter: _sizeJitter,
                  backHueOffsets: _backHueOffsets,
                  backBrightOffsets: _backBrightOffsets,
                  backWobblePhaseX: _backWobblePhaseX,
                  backWobblePhaseY: _backWobblePhaseY,
                  backWobbleSpeed: _backWobbleSpeed,
                  backSizeJitter: _backSizeJitter,
                  backCellOffsetX: _backCellOffsetX,
                  backCellOffsetY: _backCellOffsetY,
                  tick: _tickCount,
                  beatFlash: _beatFlash,
                ),
              );
              },
            ),
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
                      'Tilt: X${_x.toStringAsFixed(1)} Y${_y.toStringAsFixed(1)} Z${_z.toStringAsFixed(1)}',
                      style: const TextStyle(color: Colors.white38, fontSize: 11, fontFamily: 'monospace'),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Mic: $_micStatus  Callbacks: $_audioCallbackCount  RMS: ${_analyzer.rms.toStringAsFixed(4)}',
                      style: const TextStyle(color: Colors.orangeAccent, fontSize: 11, fontFamily: 'monospace'),
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
  final List<double> sizeJitter;
  final List<double> backHueOffsets;
  final List<double> backBrightOffsets;
  final List<double> backWobblePhaseX;
  final List<double> backWobblePhaseY;
  final List<double> backWobbleSpeed;
  final List<double> backSizeJitter;
  final List<double> backCellOffsetX;
  final List<double> backCellOffsetY;
  final int tick;
  final double beatFlash;

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
    required this.sizeJitter,
    required this.backHueOffsets,
    required this.backBrightOffsets,
    required this.backWobblePhaseX,
    required this.backWobblePhaseY,
    required this.backWobbleSpeed,
    required this.backSizeJitter,
    required this.backCellOffsetX,
    required this.backCellOffsetY,
    required this.tick,
    required this.beatFlash,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 15.0;

    final t = tick * 0.015; // slower base time for supple motion
    const maxWobble = 0.8; // gentle idle sway
    const glowWobbleBoost = 2.0; // extra when glowing
    final radius = Radius.circular(cellSize * 0.08);
    // Beat pulse: cells scale up slightly on beat
    final beatScale = 1.0 + beatFlash * 0.08;

    final total = glow.length;

    // Pass 1: draw dark base tiles at home positions to fill gaps
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final idx = r * cols + c;
        if (idx >= total) continue;
        final cellHue = (hue + hueOffsets[idx]) % 360;
        final isLight = (r + c) % 2 == 0;
        final baseBright = ((isLight ? brightness : brightness * 0.7) + brightOffsets[idx])
            .clamp(0.2, 1.0) * 0.4;
        final baseSat = (isLight ? saturation : saturation * 0.8) * 0.5;

        fillPaint.color = HSVColor.fromAHSV(1, cellHue, baseSat, baseBright).toColor();
        final originX = (c - extraCols) * cellSize;
        final originY = (r - extraRows) * cellSize;
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(originX, originY, cellSize, cellSize), radius),
          fillPaint,
        );
      }
    }

    // Pass 2: back layer — offset by half a cell, darker
    final halfCell = cellSize * 0.5;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final idx = r * cols + c;
        if (idx >= total) continue;
        final g = glow[idx].clamp(0.0, 1.0);

        final speed = backWobbleSpeed[idx];
        final phX = backWobblePhaseX[idx];
        final phY = backWobblePhaseY[idx];
        final amp = maxWobble + g * glowWobbleBoost;
        final wobbleX = (sin(t * speed * 0.8 + phX) * 0.6 +
                sin(t * speed * 1.5 + phX * 2.1) * 0.3) * amp;
        final wobbleY = (cos(t * speed * 0.7 + phY) * 0.6 +
                cos(t * speed * 1.3 + phY * 1.7) * 0.3) * amp;

        final cellHue = (hue + backHueOffsets[idx]) % 360;
        final blendedHue = g > 0.01
            ? _lerpAngle(cellHue, audioHue[idx], g.clamp(0.0, 0.8))
            : cellHue;

        final isLight = (r + c) % 2 == 0;
        final baseBright = ((isLight ? brightness : brightness * 0.7) + backBrightOffsets[idx])
            .clamp(0.2, 1.0) * 0.7; // darker than front
        final baseSat = (isLight ? saturation : saturation * 0.8) * 0.9;
        final fillBright = (baseBright + g * (1.0 - baseBright) * 0.5).clamp(0.0, 1.0);
        final fillSat = (baseSat + g * (1.0 - baseSat) * 0.4).clamp(0.0, 1.0);

        final physX = backCellOffsetX[idx];
        final physY = backCellOffsetY[idx];
        final originX = (c - extraCols) * cellSize + halfCell;
        final originY = (r - extraRows) * cellSize + halfCell;
        final sz = (cellSize - 1.0) * backSizeJitter[idx] * beatScale;
        final pad = (cellSize - 1.0 - sz) / 2;
        final x = originX + pad + wobbleX + physX;
        final y = originY + pad + wobbleY + physY;

        final rrect = RRect.fromRectAndRadius(Rect.fromLTWH(x, y, sz, sz), radius);

        fillPaint.color = HSVColor.fromAHSV(1, blendedHue, fillSat, fillBright).toColor();
        canvas.drawRRect(rrect, fillPaint);

        final borderHue = (blendedHue + 180) % 360;
        borderPaint.color = HSVColor.fromAHSV(0.2, borderHue, fillSat, fillBright).toColor();

        canvas.drawRRect(rrect, borderPaint);
      }
    }

    // Pass 3: front layer — displaced cells on top
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

        final isLight = (r + c) % 2 == 0;
        final baseBright =
            ((isLight ? brightness : brightness * 0.7) + brightOffsets[idx])
                .clamp(0.2, 1.0);
        final baseSat = isLight ? saturation : saturation * 0.8;

        // Glow boosts brightness and saturation (colorful, not white)
        final fillBright =
            (baseBright + g * (1.0 - baseBright) * 0.7).clamp(0.0, 1.0);
        final fillSat = (baseSat + g * (1.0 - baseSat) * 0.5).clamp(0.0, 1.0);

        // Combine wobble + shake physics offset, shifted for off-screen margin
        const inset = 0.5;
        final physX = cellOffsetX[idx];
        final physY = cellOffsetY[idx];
        final originX = (c - extraCols) * cellSize;
        final originY = (r - extraRows) * cellSize;
        final sz = (cellSize - inset * 2) * sizeJitter[idx] * beatScale;
        final pad = (cellSize - inset * 2 - sz) / 2;
        final x = originX + inset + pad + wobbleX + physX;
        final y = originY + inset + pad + wobbleY + physY;

        final rrect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, sz, sz), radius,
        );

        // Main fill
        fillPaint.color = HSVColor.fromAHSV(1, blendedHue, fillSat, fillBright).toColor();
        canvas.drawRRect(rrect, fillPaint);

        final borderHue = (blendedHue + 180) % 360;
        borderPaint.color = HSVColor.fromAHSV(0.1, borderHue, fillSat, fillBright).toColor();

        canvas.drawRRect(rrect, borderPaint);
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
