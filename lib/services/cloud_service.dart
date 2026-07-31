import '../models/library_item.dart';
import '../models/task_metadata.dart';

/// Cloud boundary (Smart CNC Studio / 阿里云|AWS MQTT).
///
/// The App deliberately never downloads raw G-code. It only fetches task
/// metadata and a tiny render JSON (handled where the 2D preview lives). The
/// cloud pushes the actual sliced file straight to the MCU over LAN/MQTT.
abstract class CloudService {
  Future<TaskMetadata?> getActiveTask();
  Future<List<LibraryItem>> getInspiration({int page = 0});
  Future<List<LibraryItem>> getMySpace();
  Future<void> pushDiagnostics(String log);
}
