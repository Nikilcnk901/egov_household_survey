import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../domain/household.dart';
import 'cubit/household_cubit.dart';
import 'cubit/household_state.dart';

class HouseholdFormScreen extends StatefulWidget {
  const HouseholdFormScreen({super.key, this.household});

  final Household? household;

  bool get isEditing => household != null;

  @override
  State<HouseholdFormScreen> createState() => _HouseholdFormScreenState();
}

class _HouseholdFormScreenState extends State<HouseholdFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _headNameController;
  late final TextEditingController _memberCountController;
  late final TextEditingController _settlementController;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    final household = widget.household;
    _headNameController = TextEditingController(
      text: household?.headName ?? '',
    );
    _memberCountController = TextEditingController(
      text: household == null ? '' : household.memberCount.toString(),
    );
    _settlementController = TextEditingController(
      text: household?.settlement ?? '',
    );
  }

  @override
  void dispose() {
    _headNameController.dispose();
    _memberCountController.dispose();
    _settlementController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit household' : 'New household'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _headNameController,
              decoration: const InputDecoration(labelText: 'Head name'),
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Enter a head name';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _memberCountController,
              decoration: const InputDecoration(labelText: 'Member count'),
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
              validator: (value) {
                final count = int.tryParse(value?.trim() ?? '');
                if (count == null || count <= 0) {
                  return 'Enter a member count greater than zero';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _settlementController,
              decoration: const InputDecoration(labelText: 'Settlement'),
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Enter a settlement';
                }
                return null;
              },
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _saving = true);
    final headName = _headNameController.text.trim();
    final memberCount = int.parse(_memberCountController.text.trim());
    final settlement = _settlementController.text.trim();
    final cubit = context.read<HouseholdCubit>();
    final messenger = ScaffoldMessenger.of(context);

    if (widget.household == null) {
      await cubit.createHousehold(
        headName: headName,
        memberCount: memberCount,
        settlement: settlement,
      );
    } else {
      final household = widget.household!;
      await cubit.updateHousehold(
        Household(
          id: household.id,
          serverId: household.serverId,
          headName: headName,
          memberCount: memberCount,
          settlement: settlement,
          lastSeq: household.lastSeq,
          createdAt: household.createdAt,
          updatedAt: household.updatedAt,
        ),
      );
    }

    if (!mounted) {
      return;
    }

    final state = cubit.state;
    if (state is HouseholdError) {
      messenger.showSnackBar(SnackBar(content: Text(state.message)));
      setState(() => _saving = false);
      return;
    }

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          widget.isEditing ? 'Household updated' : 'Household saved',
        ),
      ),
    );
    Navigator.of(context).pop();
  }
}
