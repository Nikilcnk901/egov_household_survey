import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../sync/domain/sync_operation.dart';
import '../../sync/domain/sync_queue_summary.dart';
import '../domain/household.dart';
import 'cubit/household_cubit.dart';
import 'cubit/household_state.dart';
import 'household_form_screen.dart';

class HouseholdListScreen extends StatefulWidget {
  const HouseholdListScreen({super.key});

  @override
  State<HouseholdListScreen> createState() => _HouseholdListScreenState();
}

class _HouseholdListScreenState extends State<HouseholdListScreen> {
  @override
  void initState() {
    super.initState();
    context.read<HouseholdCubit>().loadHouseholds();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<HouseholdCubit, HouseholdState>(
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Households'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Row(
                  children: [
                    Text(state.isOnline ? 'Online' : 'Offline'),
                    Switch(
                      value: state.isOnline,
                      onChanged: (online) {
                        context.read<HouseholdCubit>().setOnline(online);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          body: switch (state) {
            HouseholdInitial() || HouseholdLoading() => const Center(
              child: CircularProgressIndicator(),
            ),
            HouseholdError(:final message) => _HouseholdMessage(
              message: message,
              action: TextButton(
                onPressed: () =>
                    context.read<HouseholdCubit>().loadHouseholds(),
                child: const Text('Retry'),
              ),
            ),
            HouseholdLoaded(:final households, :final syncStatus) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(
                    children: [
                      Text('Mode: ${state.isOnline ? 'Online' : 'Offline'}'),
                      const Spacer(),
                      OutlinedButton.icon(
                        onPressed: () =>
                            context.read<HouseholdCubit>().syncNow(),
                        icon: const Icon(Icons.sync, size: 18),
                        label: const Text('Sync Now'),
                      ),
                    ],
                  ),
                ),
                _SyncQueueCard(summary: syncStatus),
                Expanded(
                  child: households.isEmpty
                      ? const Center(child: Text('No households yet'))
                      : ListView(
                          padding: const EdgeInsets.only(bottom: 88),
                          children: [
                            for (final household in households)
                              _HouseholdCard(
                                key: ValueKey(household.id),
                                household: household,
                                syncStatus: _syncStatusFor(
                                  syncStatus,
                                  household.id,
                                ),
                                onEdit: () => _openForm(context, household),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          },
          floatingActionButton: FloatingActionButton(
            onPressed: () => _openForm(context),
            tooltip: 'Add household',
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }

  HouseholdSyncStatus? _syncStatusFor(
    SyncQueueSummary summary,
    String householdId,
  ) {
    for (final household in summary.households) {
      if (household.householdId == householdId) {
        return household;
      }
    }
    return null;
  }

  void _openForm(BuildContext context, [Household? household]) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HouseholdFormScreen(household: household),
      ),
    );
  }
}

class _SyncQueueCard extends StatelessWidget {
  const _SyncQueueCard({required this.summary});

  final SyncQueueSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total =
        summary.pending +
        summary.retrying +
        summary.parked +
        summary.blocked +
        summary.rejected +
        summary.completed;
    final tiles = [
      _QueueTileData(
        keyName: 'pending',
        label: 'Pending',
        count: summary.pending,
        icon: Icons.hourglass_empty,
        foreground: Colors.blueGrey.shade700,
        background: const Color(0xFFF1F2F4),
      ),
      _QueueTileData(
        keyName: 'retrying',
        label: 'Retrying',
        count: summary.retrying,
        icon: Icons.sync,
        foreground: Colors.blue.shade700,
        background: const Color(0xFFE8F1FF),
      ),
      _QueueTileData(
        keyName: 'parked',
        label: 'Parked',
        count: summary.parked,
        icon: Icons.warning_amber_rounded,
        foreground: Colors.orange.shade800,
        background: const Color(0xFFFFF4E5),
      ),
      _QueueTileData(
        keyName: 'blocked',
        label: 'Blocked',
        count: summary.blocked,
        icon: Icons.block,
        foreground: Colors.deepOrange.shade800,
        background: const Color(0xFFFFF1E8),
      ),
      _QueueTileData(
        keyName: 'rejected',
        label: 'Rejected',
        count: summary.rejected,
        icon: Icons.cancel_outlined,
        foreground: Colors.red.shade700,
        background: const Color(0xFFFDECEC),
      ),
      _QueueTileData(
        keyName: 'completed',
        label: 'Completed',
        count: summary.completed,
        icon: Icons.check_circle_outline,
        foreground: Colors.green.shade700,
        background: const Color(0xFFE7F6EC),
      ),
    ];

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          children: [
            Row(
              children: [
                Icon(Icons.sync, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Sync Queue', style: theme.textTheme.titleMedium),
                const Spacer(),
                Text(
                  total == 1 ? '1 operation' : '$total operations',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                const spacing = 8.0;
                final tileWidth = (constraints.maxWidth - (spacing * 2)) / 3;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (final tile in tiles)
                      SizedBox(
                        width: tileWidth,
                        child: _QueueTile(data: tile),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueTileData {
  const _QueueTileData({
    required this.keyName,
    required this.label,
    required this.count,
    required this.icon,
    required this.foreground,
    required this.background,
  });

  final String keyName;
  final String label;
  final int count;
  final IconData icon;
  final Color foreground;
  final Color background;
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({required this.data});

  final _QueueTileData data;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: data.background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Column(
          children: [
            Icon(data.icon, size: 18, color: data.foreground),
            const SizedBox(height: 4),
            Text(
              '${data.count}',
              key: Key('queue-${data.keyName}'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: data.foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              data.label,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: data.foreground),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _HouseholdCard extends StatefulWidget {
  const _HouseholdCard({
    super.key,
    required this.household,
    required this.syncStatus,
    required this.onEdit,
  });

  final Household household;
  final HouseholdSyncStatus? syncStatus;
  final VoidCallback onEdit;

  @override
  State<_HouseholdCard> createState() => _HouseholdCardState();
}

class _HouseholdCardState extends State<_HouseholdCard> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final operations = widget.syncStatus?.operations ?? const [];
    final appearance = _statusAppearance(operations);

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.household.headName,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Edit',
                  onPressed: widget.onEdit,
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: _expanded ? 'Hide operations' : 'Show operations',
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                ),
              ],
            ),
            _StatusChip(appearance: appearance),
            const SizedBox(height: 8),
            _MetaLine(
              icon: Icons.people_outline,
              text: '${widget.household.memberCount} members',
            ),
            const SizedBox(height: 4),
            _MetaLine(
              icon: Icons.location_on_outlined,
              text: widget.household.settlement,
            ),
            if (_expanded) ...[
              const SizedBox(height: 12),
              _OperationsPanel(operations: operations),
            ],
          ],
        ),
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    );
  }
}

class _OperationStateLabel extends StatelessWidget {
  const _OperationStateLabel({required this.appearance});

  final _StatusAppearance appearance;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(appearance.icon, size: 14, color: appearance.color),
        const SizedBox(width: 4),
        Text(
          appearance.label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: appearance.color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.appearance});

  final _StatusAppearance appearance;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: appearance.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(appearance.icon, size: 14, color: appearance.color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              appearance.label,
              softWrap: true,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: appearance.color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OperationsPanel extends StatelessWidget {
  const _OperationsPanel({required this.operations});

  final List<SyncOperation> operations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Operations (${operations.length})',
              style: theme.textTheme.labelLarge,
            ),
            if (operations.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No operations'),
              )
            else
              for (final operation in operations)
                _OperationRow(operation: operation),
          ],
        ),
      ),
    );
  }
}

class _OperationRow extends StatelessWidget {
  const _OperationRow({required this.operation});

  final SyncOperation operation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appearance = _operationAppearance(operation);
    final nextRetryAt = operation.nextRetryAt;
    final lastError = operation.lastError;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_operationIcon(operation), size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_operationTitle(operation)),
                    Text(
                      'Seq: ${operation.seq} · Attempts: ${operation.attemptCount}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (operation.state == 'retrying' && nextRetryAt != null)
                      Text(
                        'Next: ${_formatRetryTime(nextRetryAt)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    if (lastError != null && lastError.isNotEmpty)
                      Text(
                        lastError,
                        softWrap: true,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.red.shade700,
                        ),
                      ),
                    if (operation.state == 'blocked')
                      Text(
                        'An earlier operation must be resolved first.',
                        softWrap: true,
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              _OperationStateLabel(appearance: appearance),
            ],
          ),
          if (operation.state == 'parked')
            TextButton(
              key: Key('retry-${operation.opId}'),
              onPressed: () {
                context.read<HouseholdCubit>().retryParkedOperation(operation);
              },
              child: const Text('Retry'),
            ),
          if (operation.state == 'rejected')
            TextButton(
              key: Key('dismiss-${operation.opId}'),
              onPressed: () {
                context.read<HouseholdCubit>().dismissRejectedOperation(
                  operation,
                );
              },
              child: const Text('Dismiss'),
            ),
        ],
      ),
    );
  }
}

class _HouseholdMessage extends StatelessWidget {
  const _HouseholdMessage({required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}

class _StatusAppearance {
  const _StatusAppearance({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;
}

_StatusAppearance _operationAppearance(SyncOperation operation) {
  return _StatusAppearance(
    label: _stateLabel(operation.state),
    color: _stateColor(operation.state),
    icon: _stateIcon(operation.state),
  );
}

_StatusAppearance _statusAppearance(List<SyncOperation> operations) {
  if (operations.isEmpty) {
    return const _StatusAppearance(
      label: 'No operations',
      color: Colors.blueGrey,
      icon: Icons.circle_outlined,
    );
  }

  final counts = <String, int>{};
  for (final operation in operations) {
    counts[operation.state] = (counts[operation.state] ?? 0) + 1;
  }

  const priority = ['rejected', 'parked', 'blocked', 'retrying', 'pending'];
  final unresolved = [
    for (final state in priority)
      if ((counts[state] ?? 0) > 0) state,
  ];
  if (unresolved.isEmpty) {
    return _StatusAppearance(
      label: 'Completed',
      color: Colors.green.shade700,
      icon: Icons.check_circle,
    );
  }

  final label = unresolved
      .map((state) => '${_stateLabel(state)} (${counts[state]})')
      .join(' · ');
  final primary = unresolved.first;
  return _StatusAppearance(
    label: label,
    color: _stateColor(primary),
    icon: _stateIcon(primary),
  );
}

String _operationTitle(SyncOperation operation) {
  if (operation.type == 'create') {
    return 'Create household';
  }
  final fields = operation.payload.keys.toSet();
  if (fields.length == 1 && fields.contains('member_count')) {
    return 'Update members';
  }
  if (fields.length == 1 && fields.contains('head_name')) {
    return 'Update name';
  }
  if (fields.length == 1 && fields.contains('settlement')) {
    return 'Update settlement';
  }
  return 'Update household';
}

IconData _operationIcon(SyncOperation operation) {
  if (operation.type == 'create') {
    return Icons.person_add_alt_1_outlined;
  }
  if (operation.payload.keys.length == 1 &&
      operation.payload.containsKey('member_count')) {
    return Icons.groups_outlined;
  }
  return Icons.edit_outlined;
}

String _stateLabel(String state) {
  if (state.isEmpty) {
    return state;
  }
  return state[0].toUpperCase() + state.substring(1);
}

Color _stateColor(String state) {
  return switch (state) {
    'completed' => Colors.green.shade700,
    'pending' => Colors.blueGrey.shade700,
    'retrying' => Colors.blue.shade700,
    'parked' => Colors.orange.shade800,
    'blocked' => Colors.deepOrange.shade800,
    'rejected' => Colors.red.shade700,
    _ => Colors.blueGrey.shade700,
  };
}

IconData _stateIcon(String state) {
  return switch (state) {
    'completed' => Icons.check_circle,
    'pending' => Icons.hourglass_empty,
    'retrying' => Icons.sync,
    'parked' => Icons.warning_amber_rounded,
    'blocked' => Icons.block,
    'rejected' => Icons.cancel_outlined,
    _ => Icons.circle_outlined,
  };
}

String _formatRetryTime(DateTime time) {
  final local = time.toLocal();
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour >= 12 ? 'PM' : 'AM';
  return '${months[local.month - 1]} ${local.day}, $hour:$minute $period';
}
