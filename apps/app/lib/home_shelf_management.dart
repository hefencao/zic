/// Pure presentation state for bookshelf management mode and batch selection.
///
/// This owner only keeps UI-mode invariants. It deliberately knows nothing
/// about library entities, persistence, navigation, dialogs, or download state.
final class HomeShelfManagement {
  bool _managing = false;
  bool _batchSelecting = false;
  final Set<String> _selectedIdentities = <String>{};

  bool get managing => _managing;

  bool get batchSelecting => _batchSelecting;

  bool get hasSelection => _selectedIdentities.isNotEmpty;

  bool isSelected(String identity) => _selectedIdentities.contains(identity);

  void toggleManaging() {
    _managing = !_managing;
    clearSelection();
  }

  void clearSelection() {
    _selectedIdentities.clear();
    _batchSelecting = false;
  }

  void startBatchSelection(String identity) {
    if (!_managing) return;
    _batchSelecting = true;
    _selectedIdentities.add(identity);
  }

  void toggleBatchSelection(String identity) {
    if (!_managing || !_batchSelecting) return;
    if (!_selectedIdentities.add(identity)) {
      _selectedIdentities.remove(identity);
    }
    if (_selectedIdentities.isEmpty) {
      _batchSelecting = false;
    }
  }

  void removeSelection(String identity) {
    if (!_selectedIdentities.remove(identity)) return;
    if (_selectedIdentities.isEmpty) {
      _batchSelecting = false;
    }
  }
}
