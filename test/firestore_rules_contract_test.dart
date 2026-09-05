import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device quota documents stay private to their bound account', () {
    final rules = File(
      'firestore.rules',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');

    expect(
      rules,
      contains(
        'resource.data.bound_uid == request.auth.uid; '
        '} match /users/{uid}',
      ),
      reason: 'The quota ownership helper must bind existing data to auth.',
    );
    expect(
      rules,
      contains(
        'allow get: if signedIn() && '
        '(resource == null || ownsExistingQuota());',
      ),
      reason: 'Only a missing quota or the bound owner may be read.',
    );
    expect(
      rules,
      contains('allow update: if ownsExistingQuota()'),
      reason: 'A signed-in user must not update another account\'s quota.',
    );
    expect(
      rules,
      contains('request.resource.data.bound_uid == request.auth.uid'),
    );
    expect(rules, contains('allow list: if false;'));
    expect(rules, contains('allow delete: if false;'));
    expect(rules, isNot(contains('allow get: if signedIn();')));
    expect(rules, isNot(contains('allow update: if signedIn()')));
  });
}
