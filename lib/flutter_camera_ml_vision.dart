library flutter_camera_ml_vision;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:collection/collection.dart';
import 'package:device_info/device_info.dart';
import 'package:google_ml_vision/google_ml_vision.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:visibility_detector/visibility_detector.dart';

export 'package:camera/camera.dart';

part 'utils.dart';

typedef HandleDetection<T> = Future<T> Function(GoogleVisionImage image);
typedef ErrorWidgetBuilder = Widget Function(BuildContext context, CameraError error);

enum CameraError {
  unknown,
  cantInitializeCamera,
  androidVersionNotSupported,
  noCameraAvailable,
}

enum _CameraState {
  loading,
  error,
  ready,
}

class CameraMlVision<T> extends StatefulWidget {
  final HandleDetection<T> detector;
  final Function(T) onResult;
  final WidgetBuilder? loadingBuilder;
  final ErrorWidgetBuilder? errorBuilder;
  final WidgetBuilder? overlayBuilder;
  final CameraLensDirection cameraLensDirection;
  final ResolutionPreset? resolution;
  final Function? onDispose;
  final Function? onInvisible;
  final Function? onVisible;

  CameraMlVision({
    Key? key,
    required this.onResult,
    required this.detector,
    this.loadingBuilder,
    this.errorBuilder,
    this.overlayBuilder,
    this.cameraLensDirection = CameraLensDirection.back,
    this.resolution,
    this.onDispose,
    this.onInvisible,
    this.onVisible,
  }) : super(key: key);

  @override
  CameraMlVisionState createState() => CameraMlVisionState<T>();
}

class CameraMlVisionState<T> extends State<CameraMlVision<T>> with WidgetsBindingObserver {
  final _visibilityKey = UniqueKey();
  CameraController? _cameraController;
  ImageRotation? _rotation;
  _CameraState _cameraMlVisionState = _CameraState.loading;
  CameraError _cameraError = CameraError.unknown;
  bool _alreadyCheckingImage = false;
  bool _isStreaming = false;
  bool _isDeactivate = false;

  var _opacity = 0.0;
  var _counter = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance!.addObserver(this);
    _initialize();
  }

  @override
  void didUpdateWidget(CameraMlVision<T> oldWidget) {
    if (oldWidget.resolution != widget.resolution) {
      _initialize();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App state changed before we got the chance to initialize.
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    if (state == AppLifecycleState.inactive) {
      if (widget.onInvisible != null) {
        widget.onInvisible!();
      }
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.resumed && _isStreaming) {
      _initialize();
      if (widget.onVisible != null) {
        widget.onVisible!();
      }
    }
  }

  Future<void> stop() async {
    if (_cameraController != null) {
      await _stop(true);
    }
  }

  Future<void> _stop(bool silently) {
    final completer = Completer();
    scheduleMicrotask(() async {
      if (_cameraController?.value.isStreamingImages == true && mounted) {
        await _cameraController!.stopImageStream().catchError((_) {});
      }

      if (silently) {
        _isStreaming = false;
      } else {
        setState(() {
          _isStreaming = false;
        });
      }
      completer.complete();
    });
    return completer.future;
  }

  void start() {
    if (_cameraController != null) {
      _start();
    }
  }

  void _start() {
    if (_isStreaming != true) {
      _cameraController!.startImageStream(_processImage);
      setState(() {
        _isStreaming = true;
      });
    }
  }

  CameraValue? get cameraValue => _cameraController?.value;

  ImageRotation? get imageRotation => _rotation;

  Future<void> Function() get prepareForVideoRecording => _cameraController!.prepareForVideoRecording;

  Future<void> startVideoRecording() async {
    await _cameraController!.stopImageStream();
    return _cameraController!.startVideoRecording();
  }

  Future<XFile> stopVideoRecording(String path) async {
    final file = await _cameraController!.stopVideoRecording();
    await _cameraController!.startImageStream(_processImage);
    return file;
  }

  CameraController? get cameraController => _cameraController;

  Future<void> flash(FlashMode mode) async {
    await _cameraController!.setFlashMode(mode);
  }

  Future<void> focus(FocusMode mode) async {
    await _cameraController!.setFocusMode(mode);
  }

  Future<void> focusPoint(Offset point) async {
    await _cameraController!.setFocusPoint(point);
  }

  Future<void> zoom(double zoom) async {
    await _cameraController!.setZoomLevel(zoom);
  }

  Future<void> exposure(ExposureMode mode) async {
    await _cameraController!.setExposureMode(mode);
  }

  Future<void> exposureOffset(double offset) async {
    await _cameraController!.setExposureOffset(offset);
  }

  Future<void> exposurePoint(Offset offset) async {
    await _cameraController!.setExposurePoint(offset);
  }

  Future<void> _initialize() async {
    if (Platform.isAndroid) {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      if (androidInfo.version.sdkInt < 24) {
        debugPrint('Camera plugin doesn\'t support android under version 24');
        if (mounted) {
          setState(() {
            _cameraMlVisionState = _CameraState.error;
            _cameraError = CameraError.androidVersionNotSupported;
          });
        }
        return;
      }
    }

    final description = await _getCamera(widget.cameraLensDirection);
    if (description == null) {
      _cameraMlVisionState = _CameraState.error;
      _cameraError = CameraError.noCameraAvailable;

      return;
    }
    if (_cameraController != null) {
      await _cameraController?.dispose();
    }
    _cameraController = CameraController(
      description,
      widget.resolution ?? ResolutionPreset.high,
      enableAudio: false,
    );
    if (!mounted) {
      return;
    }

    try {
      await _cameraController!.initialize();
    } catch (ex, stack) {
      debugPrint('Can\'t initialize camera');
      debugPrint('$ex, $stack');
      if (mounted) {
        setState(() {
          _cameraMlVisionState = _CameraState.error;
          _cameraError = CameraError.cantInitializeCamera;
        });
      }
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _cameraMlVisionState = _CameraState.ready;
    });
    _rotation = _rotationIntToImageRotation(
      description.sensorOrientation,
    );

    //FIXME hacky technique to avoid having black screen on some android devices
    if (Platform.isAndroid) {
      await Future.delayed(Duration(milliseconds: 50));
    } else {
      await Future.delayed(Duration(milliseconds: 50));
    }
    if (!mounted) {
      return;
    }
    _isStreaming = false;
    start();
  }

  @override
  void dispose() {
    if (widget.onDispose != null) {
      widget.onDispose!();
    }
    if (_cameraController != null) {
      _cameraController?.dispose();
    }

    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    Future.delayed(const Duration(milliseconds: 60), () {
      setState(() => _opacity = 1.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    var cameraPreview = _isStreaming
        ? CameraPreview(
            _cameraController!,
          )
        : Container(color: Colors.black);

    return VisibilityDetector(
      onVisibilityChanged: (VisibilityInfo info) {
        if ((info.visibleFraction * 100) <= 5) {
          //invisible stop the streaming
          _isDeactivate = true;
          _cameraController!.setFlashMode(FlashMode.off);
          if (widget.onInvisible != null) {
            widget.onInvisible!();
          }
          _stop(true);
        } else if (_isDeactivate) {
          //visible restart streaming if needed
          _isDeactivate = false;
          _start();
          if (widget.onVisible != null) {
            widget.onVisible!();
          }
        }
      },
      key: _visibilityKey,
      child: Container(
        child: Center(
          child: previewWrapper(cameraPreview),
        ),
      ),
    );
  }

  bool shouldProcess() {
    var shouldProcessInner = false;
    // Process every 5th frame
    if (_counter % 5 == 0) {
      shouldProcessInner = true;
    }

    // Don't let counter go out of control forever
    if (_counter == 1000) {
      _counter = 0;
    } else {
      _counter++;
    }

    return shouldProcessInner;
  }

  void _processImage(CameraImage cameraImage) async {
    if (!_alreadyCheckingImage && mounted && shouldProcess()) {
      _alreadyCheckingImage = true;
      try {
        final results = await _detect<T>(cameraImage, widget.detector, _rotation!);
        widget.onResult(results);
      } catch (ex, stack) {
        debugPrint('$ex, $stack');
      }
      _alreadyCheckingImage = false;
    }
  }

  void toggle() {
    if (_isStreaming && _cameraController!.value.isStreamingImages) {
      stop();
    } else {
      start();
    }
  }

  Widget previewWrapper(Widget cameraPreview) {
    return ColoredBox(
      color: Colors.black,
      child: AnimatedOpacity(
        opacity: _opacity,
        duration: const Duration(milliseconds: 300),
        child: _cameraMlVisionState == _CameraState.error
            ? widget.errorBuilder == null
                ? Center(child: Text('$_cameraMlVisionState $_cameraError'))
                : widget.errorBuilder!(context, _cameraError)
            : Stack(
                fit: StackFit.expand,
                children: [
                  (cameraController?.value.isInitialized ?? false) ? _buildPreview(cameraPreview) : Container(),
                  (cameraController?.value.isInitialized ?? false)
                      ? widget.overlayBuilder != null
                          ? widget.overlayBuilder!(context)
                          : Container()
                      : Container(),
                ],
              ),
      ),
    );
  }

  Widget _buildPreview(Widget cameraPreview) {
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(width: 720.0, height: 1280.0, child: cameraPreview),
    );
  }
}
