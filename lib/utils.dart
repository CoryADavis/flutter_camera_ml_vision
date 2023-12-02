part of 'flutter_camera_ml_vision.dart';

CameraDescription? _getCameraOther(CameraLensDirection dir, List<CameraDescription> cameras) {
  final camera = cameras.firstWhereOrNull((camera) => camera.lensDirection == dir);
  return camera ?? (cameras.isEmpty ? null : cameras.first);
}

CameraDescription? _getCameraIOS(CameraLensDirection dir, List<CameraDescription> cameras) {
  final camera = cameras.lastWhereOrNull((camera) => camera.lensDirection == dir);
  return camera ?? (cameras.isEmpty ? null : cameras.first);
}

Future<CameraDescription?> _getCamera(CameraLensDirection dir) async {
  final cameras = await availableCameras();

  if (Platform.isIOS) {
    return _getCameraIOS(dir, cameras);
  } else {
    return _getCameraOther(dir, cameras);
  }
}

Uint8List _concatenatePlanes(List<Plane> planes) {
  if (Platform.isAndroid) {
    // If Android actually returned a NV21 image, no processing is needed.
    if (planes.length == 1) {
      return planes.first.bytes;
    } else {
      final allBytes = WriteBuffer();
      planes.forEach(
        (plane) => allBytes.putUint8List(plane.bytes),
      );
      return allBytes.done().buffer.asUint8List();
    }
  } else {
    // IOS image is already single plane
    return planes.first.bytes;
  }
}

InputImageMetadata buildMetaData(
  CameraImage image,
  InputImageRotation rotation,
) {
  return InputImageMetadata(
    format: InputImageFormatValue.fromRawValue(image.format.raw)!, // used only in iOS
    size: Size(image.width.toDouble(), image.height.toDouble()),
    rotation: rotation, // used only in Android
    bytesPerRow: Platform.isIOS ? image.planes.first.bytesPerRow : 0, // used only in iOS
  );
}

Future<T> _detect<T>(
  CameraImage image,
  HandleDetection<T> handleDetection,
  InputImageRotation rotation,
) async {
  return handleDetection(
    InputImage.fromBytes(
      bytes: _concatenatePlanes(image.planes),
      metadata: buildMetaData(image, rotation),
    ),
  );
}

InputImageRotation _rotationIntToImageRotation(int rotation) {
  switch (rotation) {
    case 0:
      return InputImageRotation.rotation0deg;
    case 90:
      return InputImageRotation.rotation90deg;
    case 180:
      return InputImageRotation.rotation180deg;
    default:
      assert(rotation == 270);
      return InputImageRotation.rotation270deg;
  }
}
