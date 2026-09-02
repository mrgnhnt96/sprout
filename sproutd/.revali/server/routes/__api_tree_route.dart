part of '../server.dart';

Route apiTreeRoute(TreeController Function() treeController, DI di) {
  return Route(
    'api/tree',
    routes: [
      Route(
        '',
        method: 'GET',
        handler: (context) async {
          final result = treeController().snapshot();

          context.response.body = {'data': result};
        },
      ),
      WebSocketRoute(
        'events',
        handler: (context) async {
          final controller = treeController();

          return WebSocketHandler(
            onConnect: (context) async* {
              final result = controller.events(
                switch (context.request.queryParameters['since']) {
                  final String data => data,
                  final num data => data.toString(),
                  final bool data => data.toString(),
                  null => null,
                  final Object? mismatched => throw MissingArgumentException(
                    key: 'since',
                    location: '@query',
                    expectedType: 'String',
                    actualType: mismatched?.runtimeType.toString() ?? 'null',
                  ),
                },
                context.data,
                context.data.get() ??
                    (throw MissingArgumentException(
                      key: 'cleanUp',
                      location: '@data',
                      expectedType: 'CleanUp',
                    )),
                AsyncWebSocketSenderImpl<Stream<StringContent>>(
                  (data) =>
                      context.asyncSender.send(data.map((e) => e.toJson())),
                ),
                context.close,
              );

              yield* result.map((e) => e.toJson());
            },
            onMessage: (context) async* {
              final result = controller.events(
                switch (context.request.queryParameters['since']) {
                  final String data => data,
                  final num data => data.toString(),
                  final bool data => data.toString(),
                  null => null,
                  final Object? mismatched => throw MissingArgumentException(
                    key: 'since',
                    location: '@query',
                    expectedType: 'String',
                    actualType: mismatched?.runtimeType.toString() ?? 'null',
                  ),
                },
                context.data,
                context.data.get() ??
                    (throw MissingArgumentException(
                      key: 'cleanUp',
                      location: '@data',
                      expectedType: 'CleanUp',
                    )),
                AsyncWebSocketSenderImpl<Stream<StringContent>>(
                  (data) =>
                      context.asyncSender.send(data.map((e) => e.toJson())),
                ),
                context.close,
              );

              yield* result.map((e) => e.toJson());
            },
          );
        },
        mode: WebSocketMode.twoWay,
        ping: Duration(microseconds: 15000000),
      ),
    ],
  );
}
