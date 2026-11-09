import 'dart:convert';

import 'package:nipaplay/models/quark/quark_catalog_item.dart';
import 'package:nipaplay/models/watch_history_database.dart';
import 'package:nipaplay/services/quark/quark_metadata_scraper.dart';
import 'package:sqflite/sqflite.dart';

class QuarkCatalogStore {
  Future<Database> _open() async {
    final db = await WatchHistoryDatabase.instance.database;
    await db.execute('''
      CREATE TABLE IF NOT EXISTS quark_mount_index (
        account TEXT NOT NULL,
        mount TEXT NOT NULL,
        entries TEXT NOT NULL,
        PRIMARY KEY (account, mount)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS quark_work_metadata (
        query TEXT PRIMARY KEY,
        checked_at INTEGER NOT NULL,
        cover TEXT,
        summary TEXT
      )
    ''');
    return db;
  }

  Future<Map<String, QuarkMetadataCacheEntry>> loadMetadata() async {
    final db = await _open();
    final rows = await db.query('quark_work_metadata');
    return {
      for (final row in rows)
        row['query'] as String: (
          checkedAt: row['checked_at'] as int,
          metadata: row['cover'] == null
              ? null
              : (
                  cover: row['cover'] as String,
                  summary: row['summary'] as String
                ),
        ),
    };
  }

  Future<void> saveMetadata(String key, QuarkMetadataCacheEntry entry) async {
    final db = await _open();
    await db.insert(
        'quark_work_metadata',
        {
          'query': key,
          'checked_at': entry.checkedAt,
          'cover': entry.metadata?.cover,
          'summary': entry.metadata?.summary,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, List<QuarkCatalogItem>>> load(String account) async {
    final db = await _open();
    final rows = await db.query(
      'quark_mount_index',
      where: 'account = ?',
      whereArgs: [account],
    );
    return {
      for (final row in rows)
        row['mount'] as String: (jsonDecode(row['entries'] as String) as List)
            .map((entry) =>
                QuarkCatalogItem.fromJson(entry as Map<String, dynamic>))
            .toList(growable: false),
    };
  }

  Future<void> save(
      String account, String mount, List<QuarkCatalogItem> items) async {
    final db = await _open();
    await db.insert(
      'quark_mount_index',
      {
        'account': account,
        'mount': mount,
        'entries': jsonEncode(items.map((item) => item.toJson()).toList()),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
