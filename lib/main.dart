import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'features/households/presentation/cubit/household_cubit.dart';
import 'features/households/presentation/household_list_screen.dart';

void main() {
  runApp(const HouseholdSurveyApp());
}

class HouseholdSurveyApp extends StatelessWidget {
  const HouseholdSurveyApp({super.key, this.householdCubit});

  final HouseholdCubit? householdCubit;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => householdCubit ?? HouseholdCubit(),
      child: MaterialApp(
        title: 'Household Survey',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        ),
        home: const HouseholdListScreen(),
      ),
    );
  }
}
