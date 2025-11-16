import 'dart:async';

class ToolIterationPrompt {
  ToolIterationPrompt({required this.exhaustedIterations})
    : completer = Completer<int?>();

  final int exhaustedIterations;
  final Completer<int?> completer;

  bool get isPending => !completer.isCompleted;

  void resolve(int? value) {
    if (!completer.isCompleted) {
      completer.complete(value);
    }
  }
}
