part of '../server.dart';

Route r0Route(UiController Function() uiController, DI di) {
  return Route(
    '',
    routes: [
      Route(
        '',
        method: 'GET',
        handler: (context) async {
          await uiController().index(context.response);
        },
      ),
      Route(
        'main.css',
        method: 'GET',
        handler: (context) async {
          await uiController().stylesheet(context.response);
        },
      ),
      Route(
        'main.client.dart.js',
        method: 'GET',
        handler: (context) async {
          await uiController().bundle(context.response);
        },
      ),
    ],
  );
}
