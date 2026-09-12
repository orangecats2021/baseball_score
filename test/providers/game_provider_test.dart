import 'package:baseball_score/models/at_bat_result.dart';
import 'package:baseball_score/models/base_runners.dart';
import 'package:baseball_score/providers/game_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GameNotifier — 3アウト成立済み半イニングへの記録防止', () {
    late ProviderContainer container;
    late GameNotifier notifier;

    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
      notifier = container.read(gameProvider.notifier);

      // 表の攻撃を3三振で終わらせる（打者0,1,2番）。
      for (var i = 0; i < 3; i++) {
        notifier.recordOrUpdateAtBat(AtBatResult.strikeout, direction: '');
      }
    });

    test('3アウト後は自動で攻守交代する', () {
      final s = container.read(gameProvider);
      expect(s.isTop, isFalse);
      expect(s.gameEvents, hasLength(3));
    });

    test('完了済みの半イニングへジャンプして打席を記録しても追加されない', () {
      // 表イニングの4番目（記録されていない打者）へ戻る。
      notifier.jumpToAtBat(1, true, 0, 3);
      expect(container.read(gameProvider).outs, 3);

      notifier.recordOrUpdateAtBat(AtBatResult.groundOut, direction: '6');

      expect(container.read(gameProvider).gameEvents, hasLength(3));
    });

    test('完了済みの半イニングへジャンプして走塁イベントを記録しても追加されない', () {
      notifier.jumpToAtBat(1, true, 0, 3);

      notifier.recordBaserunningEvent('盗塁失敗', BaseRunners.empty, outsAdded: 1);

      expect(container.read(gameProvider).gameEvents, hasLength(3));
    });

    test('既存の打席の上書き更新は完了済みの半イニングでも可能', () {
      // 打者0番（1番目に記録した三振）を単打に上書きする。
      notifier.jumpToAtBat(1, true, 0, 0);

      notifier.recordOrUpdateAtBat(AtBatResult.singleHit, direction: '中');

      final events = container.read(gameProvider).gameEvents;
      expect(events, hasLength(3));
      expect(events.first.result, AtBatResult.singleHit);
    });

    test('次に表の攻撃が回ってきたとき、3アウト目を取られた打者ではなく次の打者から再開する', () {
      // 裏の攻撃も3三振で終わらせ、表の攻撃に戻す。
      for (var i = 0; i < 3; i++) {
        notifier.recordOrUpdateAtBat(AtBatResult.strikeout, direction: '');
      }

      final s = container.read(gameProvider);
      expect(s.isTop, isTrue);
      expect(s.inning, 2);
      // 表は0,1,2番が打って3アウトになったので、次は3番（インデックス3）から。
      expect(s.currentBatterIndex, 3);
    });
  });

  group('GameNotifier — 走塁死で3アウト目になった場合の打者継続', () {
    late ProviderContainer container;
    late GameNotifier notifier;

    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
      notifier = container.read(gameProvider.notifier);
    });

    test('打席が完了しないまま走塁死で3アウト目になったら、同じ打者から再開する', () {
      // 2アウトまで凡退で進める（打者0,1番）。
      notifier.recordOrUpdateAtBat(AtBatResult.groundOut, direction: '6');
      notifier.recordOrUpdateAtBat(AtBatResult.groundOut, direction: '6');
      // 打者2番の打席中に走塁死で3アウト目が成立（打席は完了しない）。
      notifier.recordBaserunningEvent('盗塁失敗', BaseRunners.empty, outsAdded: 1);

      final s = container.read(gameProvider);
      expect(s.isTop, isFalse);
      // 表の打者インデックスは進めず、打席が完了しなかった2番のまま。
      expect(s.batterIndexTop, 2);
    });
  });
}
