import 'package:equatable/equatable.dart';

import '../../../sync/domain/sync_queue_summary.dart';
import '../../domain/household.dart';

sealed class HouseholdState extends Equatable {
  const HouseholdState({this.isOnline = true});

  final bool isOnline;

  @override
  List<Object?> get props => [isOnline];
}

final class HouseholdInitial extends HouseholdState {
  const HouseholdInitial({super.isOnline});
}

final class HouseholdLoading extends HouseholdState {
  const HouseholdLoading({super.isOnline});
}

final class HouseholdLoaded extends HouseholdState {
  final List<Household> households;
  final SyncQueueSummary syncStatus;

  const HouseholdLoaded(
    this.households, {
    this.syncStatus = const SyncQueueSummary.empty(),
    super.isOnline,
  });

  @override
  List<Object?> get props => [households, syncStatus, isOnline];
}

final class HouseholdError extends HouseholdState {
  final String message;

  const HouseholdError(this.message, {super.isOnline});

  @override
  List<Object?> get props => [message, isOnline];
}
