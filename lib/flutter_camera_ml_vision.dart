library flutter_camera_ml_vision;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';

export 'package:camera/camera.dart';

part 'utils.dart';

typedef HandleDetection<T> = Future<T> Function(InputImage image);
typedef ErrorWidgetBuilder = Widget Function(BuildContext context, CameraError error);

enum CameraError {
  unknown,
  cantInitializeCamera,
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
  final double? width;
  final double? height;

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
    this.width,
    this.height,
  }) : super(key: key);

  @override
  CameraMlVisionState createState() => CameraMlVisionState<T>();
}

class CameraMlVisionState<T> extends State<CameraMlVision<T>> with WidgetsBindingObserver {
  CameraController? _cameraController;
  InputImageRotation? _rotation;
  _CameraState _cameraMlVisionState = _CameraState.loading;
  CameraError _cameraError = CameraError.unknown;
  bool _alreadyCheckingImage = false;
  bool _isStreaming = false;

  var _counter = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _initialize();
  }

  @override
  void dispose() {
    if (widget.onDispose != null) {
      widget.onDispose!();
    }

    if (_cameraController != null) {
      _cameraController?.dispose();
    }

    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
    if (state == AppLifecycleState.inactive) {
      if (_cameraController == null || !_cameraController!.value.isInitialized) {
        return;
      }
      _disposeCamera();
      print('_isStreaming Value Is: $_isStreaming');
    } else if (state == AppLifecycleState.resumed && _isStreaming) {
      _initialize();
    }
  }

  void _disposeCamera() {
    final cameraController = _cameraController;
    _cameraController = null;

    if (cameraController != null) {
      cameraController.dispose();
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
      if (_cameraController?.value.isStreamingImages == true &&
          mounted &&
          _cameraController?.value.isInitialized == true) {
        await _cameraController!.stopImageStream().catchError(
          (e) {
            debugPrint('$e');
          },
        );
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
    if (_isStreaming != true && mounted && _cameraController?.value.isInitialized == true) {
      _cameraController!.startImageStream(_processImage);
      setState(() {
        _isStreaming = true;
      });
    }
  }

  CameraValue? get cameraValue => _cameraController?.value;

  InputImageRotation? get imageRotation => _rotation;

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

  Future<void> _lockAndFocus() async {
    try {
      // TODO: Use on Android once supported
      if (Platform.isIOS) {
        await _cameraController!.lockCaptureOrientation();
        await _cameraController!.setExposureMode(ExposureMode.auto);
        await _cameraController!.setFocusMode(FocusMode.auto);
        await _cameraController!.setZoomLevel(1);
      }
    } catch (ex, stack) {
      debugPrint('$ex, $stack');
    }
  }

  Future<void> _initialize() async {
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
      // official android_camerax returns yuv420, even when requesting nv21
      imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );
    if (!mounted) {
      return;
    }

    try {
      await _cameraController!.initialize();
      await _lockAndFocus();
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
    }
    if (!mounted) {
      return;
    }
    _isStreaming = false;
    start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
  }

  @override
  Widget build(BuildContext context) {
    final cameraController = _cameraController;
    var cameraPreview = _isStreaming && cameraController != null && cameraController.value.isInitialized == true
        ? CameraPreview(
            cameraController,
          )
        : Container(color: Colors.black);

    return Container(
      child: Center(
        child: previewWrapper(cameraPreview),
      ),
    );
  }

  bool shouldProcess() {
    var shouldProcessInner = false;
    // Process every 2nd frame
    if (_counter % 2 == 0) {
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
      child: _cameraMlVisionState == _CameraState.error
          ? widget.errorBuilder == null
              ? Center(child: Text('$_cameraMlVisionState $_cameraError'))
              : widget.errorBuilder!(context, _cameraError)
          : Stack(
              //fit: StackFit.expand,
              children: [
                (cameraController?.value.isInitialized ?? false) ? _buildPreview(cameraPreview) : Container(),
                (cameraController?.value.isInitialized ?? false)
                    ? widget.overlayBuilder != null
                        ? widget.overlayBuilder!(context)
                        : Container()
                    : Container(),
              ],
            ),
    );
  }

  Widget _buildPreview(Widget cameraPreview) {
    final widgetPreviewHeight = widget.height!;
    final widgetPreviewWidth = widget.width!;
    final tmp = cameraController!.value.previewSize!;
    final previewH = max(tmp.height, tmp.width);
    final previewW = min(tmp.height, tmp.width);
    final screenRatio = widgetPreviewHeight / widgetPreviewWidth;
    final previewRatio = previewH / previewW;

    final maxHeight = screenRatio > previewRatio
        ? widgetPreviewHeight
        : previewW != 0
            ? (widgetPreviewWidth / previewW) * previewH
            : 0.0;

    final maxWidth = screenRatio > previewRatio
        ? previewH != 0
            ? (widgetPreviewHeight / previewH) * previewW
            : 0.0
        : widgetPreviewWidth;

    return OverflowBox(
      maxHeight: maxHeight,
      maxWidth: maxWidth,
      child: cameraPreview,
    );
  }
}
