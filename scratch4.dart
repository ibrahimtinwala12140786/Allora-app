import 'package:matrix/matrix.dart';
void main() {
  final filter = Filter(
    room: RoomFilter(
      timeline: RoomEventFilter(limit: 20),
    ),
  );
  print(filter.toJson());
}
