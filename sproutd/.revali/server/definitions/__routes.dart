part of '../server.dart';

List<Route> routes(DI di) {
  final _uiController = UiController();
  final _treeController = TreeController(RequestScopedDI.getFrom(di));

  return [
    r0Route(() => _uiController, di),
    apiTreeRoute(() => _treeController, di),
  ];
}
