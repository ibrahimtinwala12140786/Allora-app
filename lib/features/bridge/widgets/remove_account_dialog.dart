import 'package:flutter/material.dart';

/// Enterprise account removal confirmation dialog.
/// Validates admin/owner permission for shared team bridge accounts.
class RemoveAccountDialog extends StatelessWidget {
  final String accountName;
  final bool isSharedAccount;
  final bool isUserAdminOrOwner;
  final VoidCallback onConfirmRemove;

  const RemoveAccountDialog({
    super.key,
    required this.accountName,
    this.isSharedAccount = false,
    this.isUserAdminOrOwner = true,
    required this.onConfirmRemove,
  });

  static Future<bool?> show(
    BuildContext context, {
    required String accountName,
    bool isSharedAccount = false,
    bool isUserAdminOrOwner = true,
    required VoidCallback onConfirmRemove,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => RemoveAccountDialog(
        accountName: accountName,
        isSharedAccount: isSharedAccount,
        isUserAdminOrOwner: isUserAdminOrOwner,
        onConfirmRemove: onConfirmRemove,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Normal users cannot remove shared accounts
    final canRemove = !isSharedAccount || isUserAdminOrOwner;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Row(
        children: [
          Icon(
            canRemove ? Icons.warning_amber_rounded : Icons.lock_outline_rounded,
            color: canRemove ? Colors.redAccent : Colors.orangeAccent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              canRemove ? 'Remove $accountName?' : 'Permission Denied',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: canRemove
          ? Text(
              'Are you sure you want to remove $accountName? This will sign out your session and clear all local message caches for this network.',
              style: const TextStyle(fontSize: 14, height: 1.4),
            )
          : Text(
              '$accountName is a shared enterprise account. Only organization administrators or owners are authorized to disconnect shared accounts.',
              style: const TextStyle(fontSize: 14, height: 1.4),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        if (canRemove)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            onPressed: () {
              Navigator.of(context).pop(true);
              onConfirmRemove();
            },
            icon: const Icon(Icons.delete_forever_rounded, size: 18),
            label: const Text('Remove Account'),
          ),
      ],
    );
  }
}
