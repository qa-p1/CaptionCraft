/// Cancellation belongs to one operation, including native sessions allocated
/// after cancellation was requested.
class MediaJob {
  final Map<int, Future<void> Function()> _sessions = {};
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void checkCancelled() {
    if (_cancelled) throw const MediaJobCancelled();
  }

  Future<void> attach(int id, Future<void> Function() cancel) async {
    _sessions[id] = cancel;
    if (_cancelled) await cancel();
  }

  void detach(int id) => _sessions.remove(id);

  Future<void> cancel() async {
    _cancelled = true;
    await Future.wait(_sessions.values.toList().map((cancel) => cancel()));
  }
}

class MediaJobCancelled implements Exception {
  const MediaJobCancelled();

  @override
  String toString() => 'Operation cancelled.';
}
