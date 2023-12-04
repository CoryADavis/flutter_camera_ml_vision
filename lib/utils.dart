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

void unpackPlane(Plane plane, Uint8List out, int offset, int pixelStride, int width, int height) {
  var buffer = plane.bytes;
  for (var row = 0; row < height; row++) {
    var bufferPos = row * plane.bytesPerRow;
    var outputPos = offset + row * width;
    for (var col = 0; col < width; col += pixelStride) {
      out[outputPos++] = buffer[bufferPos];
      bufferPos += plane.bytesPerPixel!;
    }
  }
}

void unpackUVPlanes(Plane uPlane, Plane vPlane, Uint8List out, int offset, int width, int height) {
  var uBuffer = uPlane.bytes;
  var vBuffer = vPlane.bytes;
  var uvWidth = width ~/ 2;
  var uvHeight = height ~/ 2;

  for (var row = 0; row < uvHeight; row++) {
    var uBufferPos = row * uPlane.bytesPerRow;
    var vBufferPos = row * vPlane.bytesPerRow;
    var outputPos = offset + row * uvWidth * 2;
    for (var col = 0; col < uvWidth; col++) {
      out[outputPos++] = vBuffer[vBufferPos];
      out[outputPos++] = uBuffer[uBufferPos];
      uBufferPos += uPlane.bytesPerPixel!;
      vBufferPos += vPlane.bytesPerPixel!;
    }
  }
}

Uint8List _concatenatePlanes(List<Plane> planes, int height, int width) {
  if (Platform.isIOS) {
    // IOS image is already single plane
    return planes.first.bytes;
  }

  if (planes.length == 1) {
    // Image may be an Android NV21 format image which also already has one plane
    return planes.first.bytes;
  }

  // Now assuming Android YUV420 format which has 3 planes

  var imageSize = width * height;
  var nv21 = Uint8List(imageSize + imageSize ~/ 2);

  // Unpack and copy Y plane.
  unpackPlane(planes[0], nv21, 0, 1, width, height);

  // Interleave U and V planes.
  unpackUVPlanes(planes[1], planes[2], nv21, imageSize, width, height);

  return nv21;
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
      bytes: _concatenatePlanes(
        image.planes,
        image.height,
        image.width,
      ),
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
