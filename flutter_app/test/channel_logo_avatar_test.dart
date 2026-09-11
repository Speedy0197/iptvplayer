import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_app/screens/home/widgets/channel_logo_avatar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    debugNetworkImageHttpClientProvider = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  testWidgets(
    'large logos decode to display size without distorting aspect ratio',
    (tester) async {
      final bytes = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 2048, 1024),
          Paint()..color = Colors.blue,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(2048, 1024);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        return png!.buffer.asUint8List();
      });
      debugNetworkImageHttpClientProvider = () => _ImageClient(bytes!);
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(devicePixelRatio: 2),
            child: Center(
              child: ChannelLogoAvatar(
                logoUrl: 'https://example.invalid/logo.png',
              ),
            ),
          ),
        ),
      );
      final widget = tester.widget<Image>(find.byType(Image));
      final info = await tester.runAsync(() async {
        final ready = Completer<ImageInfo>();
        final stream = widget.image.resolve(const ImageConfiguration());
        final listener = ImageStreamListener(
          (info, _) => ready.complete(info),
          onError: ready.completeError,
        );
        stream.addListener(listener);
        try {
          return await ready.future;
        } finally {
          stream.removeListener(listener);
        }
      });
      addTearDown(info!.dispose);
      debugNetworkImageHttpClientProvider = null;
      expect(info.image.width, lessThanOrEqualTo(80));
      expect(info.image.height, lessThanOrEqualTo(80));
      expect(info.image.width / info.image.height, 2);
    },
  );

  testWidgets('empty and broken logos show the TV fallback', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ChannelLogoAvatar(logoUrl: '  ')),
    );
    expect(find.byIcon(Icons.tv), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    debugNetworkImageHttpClientProvider = () => _ImageClient(Uint8List(0));
    await tester.pumpWidget(
      const MaterialApp(
        home: ChannelLogoAvatar(logoUrl: 'https://example.invalid/broken.png'),
      ),
    );
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pump();
    debugNetworkImageHttpClientProvider = null;
    expect(find.byIcon(Icons.tv), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _ImageClient implements HttpClient {
  _ImageClient(this.bytes);
  final Uint8List bytes;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _ImageRequest(bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageRequest implements HttpClientRequest {
  _ImageRequest(this.bytes);
  final Uint8List bytes;
  @override
  Future<HttpClientResponse> close() async => _ImageResponse(bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  _ImageResponse(this.bytes);
  final Uint8List bytes;
  @override
  int get statusCode => HttpStatus.ok;
  @override
  int get contentLength => bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
