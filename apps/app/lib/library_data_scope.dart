/// Portable data groups shared by manual backup, restore and WebDAV. A
/// deselected group is absent from this operation, never a deletion command.
enum LibraryDataSection {
  shelf,
  history,
  readingSettings,
  appSettings,
  translation,
  extensions,
}

const allLibraryDataSections = <LibraryDataSection>{...LibraryDataSection.values};

LibraryDataSection libraryDataSection(String key) {
  final kind = key.substring(0, key.indexOf(':'));
  return switch (kind) {
    'comic' || 'category' || 'preference' => LibraryDataSection.shelf,
    // Chapter metadata is required to restore progress on a fresh device. It
    // contains logical page identities, never downloaded files or requests.
    'chapter' || 'progress' || 'read' => LibraryDataSection.history,
    'reader' => LibraryDataSection.readingSettings,
    'source' => LibraryDataSection.appSettings,
    'setting' => switch (key.substring('setting:'.length).split('\u0000').first) {
      'translation' => LibraryDataSection.translation,
      'repository' || 'plugin' => LibraryDataSection.extensions,
      _ => LibraryDataSection.appSettings,
    },
    _ => throw const FormatException('未知的数据类型'),
  };
}

Map<String, T> selectLibraryData<T>(Map<String, T> records,
  Set<LibraryDataSection> sections) => <String, T>{
    for (final entry in records.entries)
      if (sections.contains(libraryDataSection(entry.key))) entry.key: entry.value,
  };
