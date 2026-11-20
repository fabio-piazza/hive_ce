@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:hive_ce/hive_ce.dart';
import 'package:hive_ce/src/backend/js/native/storage_backend_js.dart';
import 'package:hive_ce/src/backend/js/native/utils.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:hive_ce/src/binary/frame.dart';
import 'package:hive_ce/src/box/change_notifier.dart';
import 'package:hive_ce/src/box/keystore.dart';
import 'package:hive_ce/src/hive_impl.dart';
import 'package:hive_ce/src/registry/type_registry_impl.dart';
import 'package:test/test.dart';
import 'package:web/web.dart';

import '../../common.dart';
import '../../frames.dart';

late final IDBDatabase _nullDatabase;
StorageBackendJs _getBackend({
  IDBDatabase? db,
  HiveCipher? cipher,
  TypeRegistry registry = TypeRegistryImpl.nullImpl,
}) {
  return StorageBackendJs(db ?? _nullDatabase, cipher, 'box', registry);
}

Future<IDBDatabase> _openDb([String name = 'testBox']) async {
  final request = window.self.indexedDB.open(name, 1);
  request.onupgradeneeded = (IDBVersionChangeEvent e) {
    final db = (e.target as IDBOpenDBRequest).result as IDBDatabase;
    if (!db.objectStoreNames.contains('box')) {
      db.createObjectStore('box');
    }
  }.toJS;
  return await request.asFuture<IDBDatabase>();
}

IDBObjectStore _getStore(IDBDatabase db) {
  return db.transaction('box'.toJS, 'readwrite').objectStore('box');
}

Future<IDBDatabase> _getDbWith(Map<String, Object?> content) async {
  final db = await _openDb();
  final store = _getStore(db);
  await store.clear().asFuture();
  content.forEach((k, v) => store.put(v.jsify(), k.toJS));
  return db;
}

Future<IDBDatabase> _openDbWithUniqueValues(String name) async {
  final request = window.self.indexedDB.open(name, 1);
  request.onupgradeneeded = (IDBVersionChangeEvent e) {
    final db = (e.target as IDBOpenDBRequest).result as IDBDatabase;
    db.createObjectStore('box').createIndex(
          'value',
          ''.toJS,
          IDBIndexParameters(unique: true),
        );
  }.toJS;
  return await request.asFuture<IDBDatabase>();
}

String _uniqueDbName(String prefix) =>
    '$prefix-${DateTime.timestamp().microsecondsSinceEpoch}';

Future<Map<Object, Object?>> _readAll(StorageBackendJs backend) async {
  return Map.fromIterables(await backend.getKeys(), await backend.getValues());
}

class _Unregistered {}

class _CountingBackend extends StorageBackendJs {
  var encodedFrames = 0;

  _CountingBackend(IDBDatabase db) : super(db, null, 'box');

  @override
  JSAny? encodeValue(Frame frame) {
    encodedFrames++;
    return super.encodeValue(frame);
  }
}

class _CapturingBackend extends StorageBackendJs {
  late IDBObjectStore writeStore;

  _CapturingBackend(IDBDatabase db) : super(db, null, 'box');

  @override
  IDBObjectStore getStore(bool write) {
    final store = super.getStore(write);
    if (write) writeStore = store;
    return store;
  }
}

void main() async {
  _nullDatabase = await _openDb('nullTestBox');
  group('StorageBackendJs', () {
    test('.path', () {
      expect(_getBackend().path, null);
    });

    group('.encodeValue()', () {
      test('primitive', () {
        final values = [null, 17.25, true, 'hello'];
        final backend = _getBackend();
        for (final value in values) {
          expect(backend.encodeValue(Frame('key', value)).dartify(), value);
        }

        final bytes = Uint8List.fromList([1, 2, 3]);
        final buffer =
            backend.encodeValue(Frame('key', bytes)) as JSArrayBuffer;
        expect(Uint8List.view(buffer.toDart), [1, 2, 3]);
      });

      test('crypto', () {
        final backend =
            StorageBackendJs(_nullDatabase, testCipher, 'box', testRegistry);
        var i = 0;
        for (final frame in testFrames) {
          final buffer = backend.encodeValue(frame) as JSArrayBuffer;
          final bytes = Uint8List.view(buffer.toDart);
          expect(
            bytes.sublist(28),
            [0x90, 0xA9, ...frameValuesBytesEncrypted[i]].sublist(28),
          );
          i++;
        }
      });

      group('non primitive', () {
        test('map', () {
          final frame = Frame(0, {
            'key': Uint8List.fromList([1, 2, 3]),
            'otherKey': null,
          });
          final backend = StorageBackendJs(_nullDatabase, null, 'box');
          final encoded = Uint8List.view(
            (backend.encodeValue(frame) as JSArrayBuffer).toDart,
          );

          final writer = BinaryWriterImpl(TypeRegistryImpl.nullImpl)
            ..write(frame.value);
          expect(encoded, [0x90, 0xA9, ...writer.toBytes()]);
        });

        test('bytes which start with signature', () {
          final frame = Frame(0, Uint8List.fromList([0x90, 0xA9, 1, 2, 3]));
          final backend = _getBackend();
          final encoded = Uint8List.view(
            (backend.encodeValue(frame) as JSArrayBuffer).toDart,
          );

          final writer = BinaryWriterImpl(TypeRegistryImpl.nullImpl)
            ..write(frame.value);
          expect(encoded, [0x90, 0xA9, ...writer.toBytes()]);
        });
      });
    });

    group('.decodeValue()', () {
      test('primitive', () {
        final backend = _getBackend();
        expect(backend.decodeValue(null), null);
        expect(backend.decodeValue(11.toJS), 11);
        expect(backend.decodeValue(17.25.toJS), 17.25);
        expect(backend.decodeValue(true.toJS), true);
        expect(backend.decodeValue('hello'.toJS), 'hello');
        expect(backend.decodeValue([11, 12, 13].jsify()), [11, 12, 13]);
        expect(backend.decodeValue([17.25, 17.26].jsify()), [17.25, 17.26]);

        final bytes = Uint8List.fromList([1, 2, 3]);
        expect(backend.decodeValue(bytes.buffer.toJS), [1, 2, 3]);
      });

      test('crypto', () {
        final cipher = HiveAesCipher(Uint8List.fromList(List.filled(32, 1)));
        final backend = _getBackend(cipher: cipher, registry: testRegistry);
        var i = 0;
        for (final testFrame in testFrames) {
          final bytes = [0x90, 0xA9, ...frameValuesBytesEncrypted[i]];
          final value =
              backend.decodeValue(Uint8List.fromList(bytes).buffer.toJS);
          expect(value, testFrame.value);
          i++;
        }
      });

      test('non primitive', () {
        final backend = _getBackend(registry: testRegistry);
        for (final testFrame in testFrames) {
          final bytes = backend.encodeValue(testFrame);
          final value = backend.decodeValue(bytes);
          expect(value, testFrame.value);

          // Ensure int and List<int> are not decoded as doubles
          if (testFrame.value is! Uint8List &&
              (testFrame.value is int || testFrame.value is List<int>)) {
            expect(value.runtimeType, testFrame.value.runtimeType);
          }
        }
      });
    });

    group('.getKeys()', () {
      test('with cursor', () async {
        final db = await _getDbWith({'key1': 1, 'key2': 2, 'key3': 3});
        final backend = _getBackend(db: db);

        expect(await backend.getKeys(cursor: true), ['key1', 'key2', 'key3']);
      });

      test('without cursor', () async {
        final db = await _getDbWith({'key1': 1, 'key2': 2, 'key3': 3});
        final backend = _getBackend(db: db);

        expect(await backend.getKeys(), ['key1', 'key2', 'key3']);
      });
    });

    group('.getValues()', () {
      test('with cursor', () async {
        final db = await _getDbWith({'key1': 1, 'key2': null, 'key3': 3});
        final backend = _getBackend(db: db);

        expect(await backend.getValues(cursor: true), [1, null, 3]);
      });

      test('with cursor decodes encoded values', () async {
        final db = await _getDbWith({});
        final backend = _getBackend(db: db);
        await backend.writeFrames([
          Frame('key1', 1),
          Frame('key2', ['a', 'b']),
        ]);

        final values = await backend.getValues(cursor: true);
        expect(values, [
          1,
          ['a', 'b'],
        ]);
        expect(values.last, isA<List<String>>());
      });

      test('without cursor', () async {
        final db = await _getDbWith({'key1': 1, 'key2': null, 'key3': 3});
        final backend = _getBackend(db: db);

        expect(await backend.getValues(), [1, null, 3]);
      });
    });

    group('.initialize()', () {
      test('not lazy', () async {
        final db = await _getDbWith({'key1': 1, 'key2': null, 'key3': 3});
        final backend = _getBackend(db: db);

        final keystore = Keystore.debug(notifier: ChangeNotifier());
        expect(
          await backend.initialize(
            TypeRegistryImpl.nullImpl,
            keystore,
            false,
          ),
          0,
        );
        expect(keystore.frames, [
          Frame('key1', 1),
          Frame('key2', null),
          Frame('key3', 3),
        ]);
      });

      test('lazy', () async {
        final db = await _getDbWith({'key1': 1, 'key2': null, 'key3': 3});
        final backend = _getBackend(db: db);

        final keystore = Keystore.debug(notifier: ChangeNotifier());
        expect(
          await backend.initialize(TypeRegistryImpl.nullImpl, keystore, true),
          0,
        );
        expect(keystore.frames, [
          Frame.lazy('key1'),
          Frame.lazy('key2'),
          Frame.lazy('key3'),
        ]);
      });
    });

    test('.readValue()', () async {
      final db = await _getDbWith({'key1': 1, 'key2': null, 'key3': 3});
      final backend = _getBackend(db: db);

      expect(await backend.readValue(Frame('key1', null)), 1);
      expect(await backend.readValue(Frame('key2', null)), null);
    });

    test('.writeFrames()', () async {
      final db = await _getDbWith({});
      final backend = _getBackend(db: db);

      final frames = [Frame('key1', 123), Frame('key2', null)];
      await backend.writeFrames(frames);
      expect(frames, [Frame('key1', 123), Frame('key2', null)]);
      expect(await backend.getKeys(), ['key1', 'key2']);

      await backend.writeFrames([Frame.deleted('key1')]);
      expect(await backend.getKeys(), ['key2']);
    });

    group('.writeFrames() batch', () {
      test('writes every frame of a large batch', () async {
        final name = _uniqueDbName('largebatch');
        final db = await _openDb(name);
        final frames = [for (var i = 0; i < 500; i++) Frame('key$i', i)];
        await _getBackend(db: db).writeFrames(frames);
        db.close();

        final reopened = await _openDb(name);
        expect(await _readAll(_getBackend(db: reopened)), {
          for (var i = 0; i < 500; i++) 'key$i': i,
        });
        reopened.close();
      });

      test('keeps the last write of a key repeated in one batch', () async {
        final db = await _getDbWith({});
        final backend = _getBackend(db: db);
        await backend.writeFrames([
          Frame('overwritten', 1),
          Frame('overwritten', 2),
          Frame('deletedAfterPut', 1),
          Frame.deleted('deletedAfterPut'),
          Frame.deleted('putAfterDelete'),
          Frame('putAfterDelete', 3),
        ]);

        expect(
          await _readAll(backend),
          {'overwritten': 2, 'putAfterDelete': 3},
        );
      });

      test('issues every request before waiting', () async {
        final db = await _getDbWith({});
        final backend = _CountingBackend(db);
        final frames = [for (var i = 0; i < 500; i++) Frame('key$i', i)];

        final write = backend.writeFrames(frames);
        expect(backend.encodedFrames, 500);
        await write;
      });

      test('writes nothing when a frame fails to encode', () async {
        final db = await _getDbWith({'kept': 0});
        final backend = _getBackend(db: db, registry: TypeRegistryImpl());

        await expectLater(
          backend.writeFrames([
            Frame('kept', 1),
            Frame('added', 2),
            Frame('failing', _Unregistered()),
          ]),
          throwsA(isA<HiveError>()),
        );
        expect(await _readAll(backend), {'kept': 0});
      });

      test('writes nothing when a request fails', () async {
        final db = await _openDbWithUniqueValues(_uniqueDbName('unique'));
        final backend = _getBackend(db: db);

        await expectLater(
          backend
              .writeFrames([Frame('first', 'same'), Frame('second', 'same')]),
          throwsA(
            predicate((e) => (e as DOMException).name == 'ConstraintError'),
          ),
        );
        expect(await backend.getKeys(), isEmpty);
        db.close();
      });

      test('writes nothing when the transaction aborts', () async {
        final db = await _getDbWith({});
        final backend = _CapturingBackend(db);

        final write = backend.writeFrames([Frame('key1', 1), Frame('key2', 2)]);
        backend.writeStore.transaction.abort();

        await expectLater(write, throwsA(anything));
        expect(await backend.getKeys(), isEmpty);
      });

      test('box rolls back a batch that fails to encode', () async {
        final hive = HiveImpl();
        addTearDown(hive.close);
        hive.init(null);
        final name = generateBoxName();
        var box = await hive.openBox(name);
        await box.put('kept', 0);

        await expectLater(
          box.putAll({'kept': 1, 'added': 2, 'failing': _Unregistered()}),
          throwsA(isA<HiveError>()),
        );
        expect(box.toMap(), {'kept': 0});

        await box.close();
        box = await hive.openBox(name);
        expect(box.toMap(), {'kept': 0});
        await box.deleteFromDisk();
      });

      test('box reads back a large putAll after reopening', () async {
        final hive = HiveImpl();
        addTearDown(hive.close);
        hive.init(null);
        final name = generateBoxName();
        final entries = {for (var i = 0; i < 500; i++) 'key$i': i};
        var box = await hive.openBox(name);

        await box.putAll(entries);
        await box.close();
        box = await hive.openBox(name);

        expect(box.toMap(), entries);
        await box.deleteFromDisk();
      });
    });

    test('.compact()', () async {
      final db = await _getDbWith({});
      final backend = _getBackend(db: db);
      expect(
        () async => await backend.compact({}),
        throwsUnsupportedError,
      );
    });

    test('.clear()', () async {
      final db = await _getDbWith({'key1': 1, 'key2': 2, 'key3': 3});
      final backend = _getBackend(db: db);
      await backend.clear();
      expect(await backend.getKeys(), []);
    });

    test('.close()', () async {
      final db = await _getDbWith({'key1': 1, 'key2': 2, 'key3': 3});
      final backend = _getBackend(db: db);
      await backend.close();

      await expectLater(() async => await backend.getKeys(), throwsA(anything));
    });
  });
}
