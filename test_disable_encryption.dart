import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  
  final client = Client(
    'Allora',
    databaseBuilder: (_) async {
      return MatrixSqfliteDatabase(
        'allora_matrix',
        databaseFactory: databaseFactoryFfi,
      );
    },
  );

  await client.init();

  if (!client.isLogged()) {
    print('Not logged in!');
    return;
  }

  print('Logged in as ${client.userID}');

  int count = 0;
  for (final room in client.rooms) {
    if (room.encrypted) {
      final isWa = room.id.contains('whatsapp') || 
                   room.getParticipants().any((p) => p.id.contains('whatsappbot'));
                   
      if (isWa) {
        print('Disabling encryption for room ${room.id} (${room.displayname})...');
        try {
          await client.setRoomStateWithKey(room.id, EventTypes.Encryption, '', {});
          print('  -> Success!');
          count++;
        } catch (e) {
          print('  -> Failed: $e');
        }
      }
    }
  }
  
  print('Disabled encryption in $count rooms.');
}
