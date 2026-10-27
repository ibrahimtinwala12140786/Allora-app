import 'package:matrix/matrix.dart';
void main() {
  print(Client('Test', database: MemoryDatabase()).useSlidingSync);
}
