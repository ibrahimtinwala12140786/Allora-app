import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/empty_state.dart';
import '../../data/settings/app_settings.dart';
import '../../data/settings/labels.dart';

class SmartFoldersScreen extends ConsumerStatefulWidget {
  const SmartFoldersScreen({super.key});

  static MaterialPageRoute route() =>
      MaterialPageRoute(builder: (_) => const SmartFoldersScreen());

  @override
  ConsumerState<SmartFoldersScreen> createState() => _SmartFoldersScreenState();
}

class _SmartFoldersScreenState extends ConsumerState<SmartFoldersScreen> {
  @override
  Widget build(BuildContext context) {
    final c = context.allora;
    final settings = ref.watch(settingsProvider);
    final rules = settings.smartFolderRules;
    final labelsState = ref.watch(labelsProvider);

    return Scaffold(
      backgroundColor: c.canvas,
      appBar: AppBar(
        title: const Text('Smart Folders'),
        actions: [
          IconButton(
            tooltip: 'Add rule',
            icon: const Icon(Icons.add_rounded),
            onPressed: () => _addRuleDialog(context),
          ),
        ],
      ),
      body: rules.isEmpty
          ? EmptyState(
              icon: Icons.folder_special_rounded,
              title: 'No rules yet',
              message: 'Create rules to automatically label incoming chats based on keywords.',
            )
          : ListView.builder(
              itemCount: rules.length,
              itemBuilder: (context, index) {
                final keyword = rules.keys.elementAt(index);
                final labelId = rules.values.elementAt(index);
                final label = labelsState.labels.firstWhere(
                    (l) => l.id == labelId,
                    orElse: () => const Label(id: '', name: 'Unknown', colorValue: 0, iconIndex: 0, order: 0));

                return ListTile(
                  title: Text('If chat name contains "$keyword"'),
                  subtitle: Text('Apply label: ${label.name}'),
                  leading: Icon(label.icon, color: label.color),
                  trailing: IconButton(
                    icon: Icon(Icons.delete_outline_rounded, color: c.danger),
                    onPressed: () => ref.read(settingsProvider.notifier).removeSmartFolderRule(keyword),
                  ),
                );
              },
            ),
    );
  }

  void _addRuleDialog(BuildContext context) {
    final c = context.allora;
    final keywordCtrl = TextEditingController();
    Label? selectedLabel;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            final labels = ref.watch(labelsProvider).sorted;
            return AlertDialog(
              backgroundColor: c.surface,
              title: const Text('New Rule'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: keywordCtrl,
                    decoration: const InputDecoration(labelText: 'Keyword in chat title'),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<Label>(
                    decoration: const InputDecoration(labelText: 'Apply Label'),
                    value: selectedLabel,
                    items: labels.map((l) {
                      return DropdownMenuItem(
                        value: l,
                        child: Row(
                          children: [
                            Icon(l.icon, color: l.color, size: 20),
                            const SizedBox(width: 8),
                            Text(l.name),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (val) => setState(() => selectedLabel = val),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    final kw = keywordCtrl.text.trim();
                    if (kw.isNotEmpty && selectedLabel != null) {
                      ref.read(settingsProvider.notifier).addSmartFolderRule(kw, selectedLabel!.id);
                      Navigator.pop(ctx);
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
