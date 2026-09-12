import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/advance_calculator.dart';
import '../logic/game_replay.dart';
import '../models/at_bat_result.dart';
import '../models/base_runners.dart';
import '../models/game_event.dart';
import '../models/game_state.dart';
import '../models/player.dart';
import '../models/resolved_event.dart';
import '../models/saved_game.dart';
import '../services/game_sync_service.dart';

/// 試合入力画面の進行状態（打順・イニング・走者・名簿など）。
///
/// [gameEvents]（試合の「事実」）と、それを再生した結果である [replay] を
/// あわせて保持する。UI はこのオブジェクトだけを読めば画面を描画できる。
class GameSessionState {
  /// 記録された全イベント。この配列だけが試合の「事実」であり、
  /// スコアも個人成績もすべて [replay] を通じてここから導出される。
  final List<GameEvent> gameEvents;

  /// 次に発行するイベントID。
  ///
  /// 途中のイベントを削除してもIDが重複しないよう、単調増加のカウンタで管理する。
  final int nextEventId;

  /// 試合が実際に行われた日付（保存日時とは別）。
  final DateTime gameDate;

  final String teamNameTop;
  final String teamNameBottom;
  final int totalInningsConfig;

  final int inning;
  final bool isTop;

  final int batterIndexTop;
  final int batterIndexBottom;
  final int cycleIndexTop;
  final int cycleIndexBottom;

  final List<Player> playersTop;
  final List<Player> playersBottom;

  final String currentPitcherIdTop;
  final String currentPitcherIdBottom;

  /// [gameEvents] を再生した結果。
  final GameState replay;

  /// `undo()` で取り消したイベントを新しい順に積んでおくスタック。
  /// `redo()` で末尾から取り出して [gameEvents] へ戻す。
  /// 新規にイベントを記録・削除するとやり直し先が失われるため空にする。
  final List<GameEvent> redoStack;

  /// この端末が編集権限を持っているか。
  ///
  /// 試合の内容（[SavedGame]）には含まれない、端末ローカルな権限フラグ。
  /// 編集キーを未入力・不一致のまま開いた場合は閲覧のみとなり、
  /// UI側で変更系の操作を無効化する。
  final bool canEdit;

  const GameSessionState({
    required this.gameEvents,
    required this.nextEventId,
    required this.gameDate,
    required this.teamNameTop,
    required this.teamNameBottom,
    required this.totalInningsConfig,
    required this.inning,
    required this.isTop,
    required this.batterIndexTop,
    required this.batterIndexBottom,
    required this.cycleIndexTop,
    required this.cycleIndexBottom,
    required this.playersTop,
    required this.playersBottom,
    required this.currentPitcherIdTop,
    required this.currentPitcherIdBottom,
    required this.replay,
    this.redoStack = const [],
    this.canEdit = true,
  });

  factory GameSessionState.initial() {
    final playersTop = [
      for (var i = 1; i <= 9; i++)
        Player(id: 't$i', name: '選手名$i', position: ''),
    ];
    final playersBottom = [
      for (var i = 1; i <= 9; i++)
        Player(id: 'b$i', name: '選手名$i', position: ''),
    ];
    const totalInningsConfig = 7;
    const inning = 1;
    final now = DateTime.now();
    return GameSessionState(
      gameEvents: const [],
      nextEventId: 1,
      gameDate: DateTime(now.year, now.month, now.day),
      teamNameTop: '自チーム (先)',
      teamNameBottom: '対戦相手 (後)',
      totalInningsConfig: totalInningsConfig,
      inning: inning,
      isTop: true,
      batterIndexTop: 0,
      batterIndexBottom: 0,
      cycleIndexTop: 0,
      cycleIndexBottom: 0,
      playersTop: playersTop,
      playersBottom: playersBottom,
      currentPitcherIdTop: playersTop.last.id,
      currentPitcherIdBottom: playersBottom.last.id,
      replay: replayGame(events: const [], minInnings: totalInningsConfig),
    );
  }

  GameSessionState copyWith({
    List<GameEvent>? gameEvents,
    int? nextEventId,
    DateTime? gameDate,
    String? teamNameTop,
    String? teamNameBottom,
    int? totalInningsConfig,
    int? inning,
    bool? isTop,
    int? batterIndexTop,
    int? batterIndexBottom,
    int? cycleIndexTop,
    int? cycleIndexBottom,
    List<Player>? playersTop,
    List<Player>? playersBottom,
    String? currentPitcherIdTop,
    String? currentPitcherIdBottom,
    GameState? replay,
    List<GameEvent>? redoStack,
    bool? canEdit,
  }) {
    return GameSessionState(
      gameEvents: gameEvents ?? this.gameEvents,
      nextEventId: nextEventId ?? this.nextEventId,
      gameDate: gameDate ?? this.gameDate,
      teamNameTop: teamNameTop ?? this.teamNameTop,
      teamNameBottom: teamNameBottom ?? this.teamNameBottom,
      totalInningsConfig: totalInningsConfig ?? this.totalInningsConfig,
      inning: inning ?? this.inning,
      isTop: isTop ?? this.isTop,
      batterIndexTop: batterIndexTop ?? this.batterIndexTop,
      batterIndexBottom: batterIndexBottom ?? this.batterIndexBottom,
      cycleIndexTop: cycleIndexTop ?? this.cycleIndexTop,
      cycleIndexBottom: cycleIndexBottom ?? this.cycleIndexBottom,
      playersTop: playersTop ?? this.playersTop,
      playersBottom: playersBottom ?? this.playersBottom,
      currentPitcherIdTop: currentPitcherIdTop ?? this.currentPitcherIdTop,
      currentPitcherIdBottom:
          currentPitcherIdBottom ?? this.currentPitcherIdBottom,
      replay: replay ?? this.replay,
      redoStack: redoStack ?? this.redoStack,
      canEdit: canEdit ?? this.canEdit,
    );
  }

  /// やり直せる（`redo()` できる）取り消し済みイベントがあるか。
  bool get canRedo => redoStack.isNotEmpty;

  // --- 以下は保持しているフィールドから導出される読み取り専用の値 ---

  List<Player> get currentBatters => isTop ? playersTop : playersBottom;
  List<Player> get defendingPlayers => isTop ? playersBottom : playersTop;

  Player get activePitcher {
    final pId = isTop ? currentPitcherIdBottom : currentPitcherIdTop;
    return findPlayer(pId) ?? defendingPlayers.first;
  }

  int get currentBatterIndex => isTop ? batterIndexTop : batterIndexBottom;
  int get currentCycle => isTop ? cycleIndexTop : cycleIndexBottom;

  List<int> get scoresTop => replay.scoresTop;
  List<int> get scoresBottom => replay.scoresBottom;
  int get errorsTop => replay.errorsTop;
  int get errorsBottom => replay.errorsBottom;
  int get totalScoreTop => replay.totalScoreTop;
  int get totalScoreBottom => replay.totalScoreBottom;

  int get totalHitsTop => playersTop.fold(0, (sum, b) => sum + b.stats.hits);
  int get totalHitsBottom =>
      playersBottom.fold(0, (sum, b) => sum + b.stats.hits);

  Iterable<Player> get allPlayers => [...playersTop, ...playersBottom];

  Player? findPlayer(String? id) {
    if (id == null) {
      return null;
    }
    for (final p in playersTop) {
      if (p.id == id) {
        return p;
      }
    }
    for (final p in playersBottom) {
      if (p.id == id) {
        return p;
      }
    }
    return null;
  }

  int get maxCycleInCurrentInning {
    final evs = replay.events.where(
      (e) => e.inning == inning && e.isTop == isTop && !e.isBaserunningEvent,
    );
    if (evs.isEmpty) {
      return 0;
    }
    return evs.map((e) => e.cycleIndex).reduce((a, b) => a > b ? a : b);
  }

  /// 現在選択中の打席（回・表裏・巡目・打順が一致するイベント）。
  ///
  /// 既に結果が入力済みの打席を選び直しているときは非 null になり、
  /// このとき新たな入力は「上書き」として扱われる。
  ResolvedEvent? get activeEvent {
    return replay.events
        .where(
          (e) =>
              !e.isBaserunningEvent &&
              e.inning == inning &&
              e.isTop == isTop &&
              e.cycleIndex == currentCycle &&
              e.batterIndex == currentBatterIndex,
        )
        .firstOrNull;
  }

  /// 現在の打席開始時点のアウトカウント。
  int get outs {
    final current = activeEvent;
    if (current != null) {
      return current.outsBefore;
    }
    final inningEvents = replay.eventsInHalfInning(
      inning,
      isTop,
      includeIgnored: false,
    );
    return inningEvents.isNotEmpty ? inningEvents.last.outsAfter : 0;
  }

  /// 現在の打席開始時点の走者状況。
  BaseRunners get runners {
    final current = activeEvent;
    if (current != null) {
      return current.runnersBefore;
    }
    final inningEvents = replay.eventsInHalfInning(
      inning,
      isTop,
      includeIgnored: false,
    );
    return inningEvents.isNotEmpty
        ? inningEvents.last.runnersAfter
        : BaseRunners.empty;
  }
}

/// 試合の進行状態を管理する Notifier。
///
/// `_gameEvents` を書き換えるすべての操作は、最後に必ず `replayGame()` で
/// 全体を再計算した [GameSessionState] を `state` へ反映する。
class GameNotifier extends Notifier<GameSessionState> {
  @override
  GameSessionState build() => GameSessionState.initial();

  StreamSubscription<WatchedGame?>? _remoteSub;

  /// 現在リアルタイム購読中の試合ID。`null` の間は完全ローカル動作
  /// （既存の単体テストを含む）で、変更系メソッドはネットワークに触れない。
  String? _syncedGameId;

  /// 購読中のドキュメントについて最後に確認できた `docVersion`。
  /// 変更を送信する際、この版からサーバーが進んでいなければ
  /// 楽観的並行性制御により書き込みが成功する。
  int _lastKnownDocVersion = 0;

  /// 指定した試合のリアルタイム購読を開始する。他の編集者・閲覧者による
  /// 変更が届くたびに [loadGame] で state を最新の内容に置き換える。
  void connectToRemote(String gameId) {
    _remoteSub?.cancel();
    _syncedGameId = gameId;
    _remoteSub = ref.read(gameSyncServiceProvider).watchGame(gameId).listen((
      watched,
    ) {
      if (watched != null) {
        _lastKnownDocVersion = watched.docVersion;
        loadGame(watched.game);
      }
    });
  }

  /// リアルタイム購読を終了する。画面を離れる際に必ず呼ぶこと。
  void disconnectFromRemote() {
    _remoteSub?.cancel();
    _remoteSub = null;
    _syncedGameId = null;
  }

  /// ローカルへ即座に反映しつつ（楽観的更新）、購読中の試合があれば
  /// バックグラウンドでFirestoreへも同期する。
  ///
  /// サーバー側の `docVersion` が自分の知っている版から進んでいた場合
  /// （＝他の人が同時に更新した場合）は書き込みを諦め、競合メッセージを
  /// 表示する。購読中の [connectToRemote] のリスナーが直後に最新の内容を
  /// 配信し、上で楽観的に当てた state を正しい内容へ上書きする。
  void _commitLocalAndSync(GameSessionState next) {
    state = next;
    final gameId = _syncedGameId;
    if (gameId == null) {
      return;
    }
    unawaited(_syncToRemote(gameId, next));
  }

  Future<void> _syncToRemote(String gameId, GameSessionState next) async {
    try {
      await ref
          .read(gameSyncServiceProvider)
          .saveGameIfVersionMatches(toSavedGame(gameId), _lastKnownDocVersion);
    } on StaleGameStateException {
      ref
          .read(conflictMessageProvider.notifier)
          .show('他の人が同時に更新しました。最新の状態を表示しています。もう一度入力してください。');
    }
  }

  GameSessionState _recomputeReplay(GameSessionState s) {
    final replay = replayGame(
      events: s.gameEvents,
      minInnings: s.totalInningsConfig > s.inning
          ? s.totalInningsConfig
          : s.inning,
    );
    for (final player in s.allPlayers) {
      player.stats = replay.statsOf(player.id);
    }
    return s.copyWith(replay: replay);
  }

  GameSessionState _withCurrentBatterIndex(GameSessionState s, int val) =>
      s.isTop
      ? s.copyWith(batterIndexTop: val)
      : s.copyWith(batterIndexBottom: val);

  GameSessionState _withCurrentCycle(GameSessionState s, int val) => s.isTop
      ? s.copyWith(cycleIndexTop: val)
      : s.copyWith(cycleIndexBottom: val);

  // 攻守交代では batterIndexTop/Bottom・cycleIndexTop/Bottom をリセットしない。
  // これらはチームごとの打順位置であり、そのチームの前回の攻撃（1イニング前）の
  // 続きの打者から再開する必要があるため。
  GameSessionState _changeInning(GameSessionState s) {
    return s.copyWith(
      isTop: !s.isTop,
      inning: !s.isTop ? s.inning + 1 : s.inning,
    );
  }

  /// 現在の半イニングが3アウトに達していれば攻守交代する。
  ///
  /// [advanceBatter] が true の場合、交代前にそのチームの打者インデックスを
  /// 次の打者へ進めてから交代する（＝今の打席で打者の出番が完了した場合）。
  /// 走塁死などで打者の打席が完了しないまま3アウト目になった場合は false を
  /// 渡し、次の攻撃を同じ打者から再開できるようにする。
  ///
  /// 戻り値は攻守交代後の状態と、交代したかどうかのペア。
  (GameSessionState, bool) _changeInningIfCompleted(
    GameSessionState s, {
    bool advanceBatter = false,
  }) {
    final events = s.replay.eventsInHalfInning(
      s.inning,
      s.isTop,
      includeIgnored: false,
    );
    if (events.isEmpty || events.last.outsAfter < 3) {
      return (s, false);
    }
    final ready = advanceBatter ? _advanceCurrentBatter(s) : s;
    return (_recomputeReplay(_changeInning(ready)), true);
  }

  // 打者インデックスだけを次の打者へ進める（巡目の繰り上げ込み）。
  // 攻守交代の判定は行わない。
  GameSessionState _advanceCurrentBatter(GameSessionState s) {
    int nextIdx = s.currentBatterIndex + 1;
    var next = s;
    if (nextIdx >= s.currentBatters.length) {
      nextIdx = 0;
      next = _withCurrentCycle(next, next.currentCycle + 1);
    }
    return _withCurrentBatterIndex(next, nextIdx);
  }

  GameSessionState _nextBatter(GameSessionState s) {
    var next = _advanceCurrentBatter(s);

    if (next.outs >= 3) {
      next = _recomputeReplay(_changeInning(next));
    }
    return next;
  }

  /// 直前に記録したイベントを取り消し、選択中の打席もそこへ巻き戻す。
  ///
  /// 取り消したイベントは [GameSessionState.redoStack] に積んでおき、
  /// `redo()` でやり直せるようにする。
  void undo() {
    final s = state;
    if (s.gameEvents.isEmpty) {
      return;
    }
    final events = [...s.gameEvents];
    final last = events.removeLast();
    var next = s.copyWith(
      gameEvents: events,
      redoStack: [...s.redoStack, last],
      inning: last.inning,
      isTop: last.isTop,
    );
    if (last.batterIndex >= 0 && !last.isBaserunningEvent) {
      next = _withCurrentBatterIndex(next, last.batterIndex);
    }
    next = _withCurrentCycle(next, last.cycleIndex);
    _commitLocalAndSync(_recomputeReplay(next));
  }

  /// `undo()` で取り消した直前のイベントを記録し直す。
  void redo() {
    final s = state;
    if (s.redoStack.isEmpty) {
      return;
    }
    final redoStack = [...s.redoStack];
    final event = redoStack.removeLast();

    var next = s.copyWith(
      gameEvents: [...s.gameEvents, event],
      redoStack: redoStack,
      inning: event.inning,
      isTop: event.isTop,
    );
    next = _withCurrentCycle(next, event.cycleIndex);
    if (event.batterIndex >= 0 && !event.isBaserunningEvent) {
      next = _withCurrentBatterIndex(next, event.batterIndex);
    }
    next = _recomputeReplay(next);

    final (afterChange, changed) = _changeInningIfCompleted(
      next,
      advanceBatter: !event.isBaserunningEvent,
    );
    _commitLocalAndSync(
      (!changed && !event.isBaserunningEvent)
          ? _nextBatter(afterChange)
          : afterChange,
    );
  }

  void deleteEvent(int eventId) {
    final events = state.gameEvents.where((e) => e.eventId != eventId).toList();
    _commitLocalAndSync(
      _recomputeReplay(state.copyWith(gameEvents: events, redoStack: const [])),
    );
  }

  void deleteCurrentPlateEvent() {
    final ev = state.activeEvent;
    if (ev == null) {
      return;
    }
    deleteEvent(ev.eventId);
  }

  void jumpToInning(int targetInn, bool targetIsTop) {
    var next = state.copyWith(inning: targetInn, isTop: targetIsTop);
    next = _withCurrentCycle(next, 0);
    next = _withCurrentBatterIndex(next, 0);
    state = _recomputeReplay(next);
  }

  void jumpToBatter(int targetIdx) {
    state = _withCurrentBatterIndex(state, targetIdx);
  }

  /// 過去に記録した打席（回・表裏・巡目・打順）へ直接ジャンプする。
  void jumpToAtBat(
    int targetInn,
    bool targetIsTop,
    int cycleIndex,
    int batterIndex,
  ) {
    var next = state.copyWith(inning: targetInn, isTop: targetIsTop);
    next = _withCurrentCycle(next, cycleIndex);
    next = _withCurrentBatterIndex(next, batterIndex);
    state = _recomputeReplay(next);
  }

  /// 現在のイニング内で表示する巡目を切り替える。
  void selectCycle(int cycleIndex, {int batterIndex = 0}) {
    var next = _withCurrentCycle(state, cycleIndex);
    next = _withCurrentBatterIndex(next, batterIndex);
    state = next;
  }

  /// 走塁イベント（盗塁・WP・PB・走塁死など）を記録する。
  ///
  /// [runnerId] にはイベントの主体となる走者を渡す。盗塁数はこの走者に記録される。
  void recordBaserunningEvent(
    String desc,
    BaseRunners newRunners, {
    bool isSteal = false,
    String? batterId,
    String? runnerId,
    int runs = 0,
    int outsAdded = 0,
    List<String>? scoredIds,
  }) {
    final s = state;
    // ジャンプ機能で既に3アウト成立済みの半イニングへ戻っている場合、
    // ここで新規イベントを追加すると集計対象外のまま残り続けてしまうため記録しない。
    if (s.outs >= 3) {
      return;
    }
    final events = [
      ...s.gameEvents,
      GameEvent(
        eventId: s.nextEventId,
        inning: s.inning,
        isTop: s.isTop,
        description: desc,
        batterId: batterId,
        batterIndex: s.currentBatterIndex,
        pitcherId: s.activePitcher.id,
        cycleIndex: s.currentCycle,
        runs: runs,
        earnedRuns: runs,
        scoredPlayerIds: scoredIds,
        runnerId: runnerId,
        runnersAfter: newRunners,
        outsAdded: outsAdded,
        isBaserunningEvent: true,
        isSteal: isSteal,
      ),
    ];
    final next = _recomputeReplay(
      s.copyWith(
        gameEvents: events,
        nextEventId: s.nextEventId + 1,
        redoStack: const [],
      ),
    );
    final (afterChange, _) = _changeInningIfCompleted(next);
    _commitLocalAndSync(afterChange);
  }

  /// 打席結果を、標準的な進塁ルールにしたがって記録する。
  void recordOrUpdateAtBat(
    AtBatResult result, {
    required String direction,
    String? errorPlayerId,
  }) {
    final s = state;
    final batter = s.currentBatters[s.currentBatterIndex];
    final advance = calculateDefaultAdvance(
      result: result,
      runners: s.runners,
      batterId: batter.id,
    );
    commitAtBat(
      result: result,
      direction: direction,
      runnersAfter: advance.runners,
      runs: advance.runs,
      rbi: advance.rbi,
      outsAdded: advance.outsAdded,
      scoredPlayerIds: advance.scoredPlayerIds,
      errorPlayerId: errorPlayerId,
    );
  }

  /// 走者ごとの行き先をダイアログで指定した打席結果を記録する。
  void applyCustomHitResult(
    AtBatResult result,
    String direction,
    BaseRunners customRunners,
    int runs,
    int rbi,
    List<String> scoredIds, {
    required int outsAdded,
    String? errorPlayerId,
  }) {
    commitAtBat(
      result: result,
      direction: direction,
      runnersAfter: customRunners,
      runs: runs,
      rbi: rbi,
      outsAdded: outsAdded,
      scoredPlayerIds: scoredIds,
      errorPlayerId: errorPlayerId,
    );
  }

  /// [event] の説明文だけを差し替えた新しいイベントを返す。
  GameEvent _withDescription(GameEvent event, String description) => GameEvent(
    eventId: event.eventId,
    inning: event.inning,
    isTop: event.isTop,
    description: description,
    batterId: event.batterId,
    batterIndex: event.batterIndex,
    pitcherId: event.pitcherId,
    cycleIndex: event.cycleIndex,
    result: event.result,
    direction: event.direction,
    rbi: event.rbi,
    runs: event.runs,
    earnedRuns: event.earnedRuns,
    scoredPlayerIds: event.scoredPlayerIds,
    errorPlayerId: event.errorPlayerId,
    runnerId: event.runnerId,
    runnersAfter: event.runnersAfter,
    outsAdded: event.outsAdded,
    isBaserunningEvent: event.isBaserunningEvent,
    isSteal: event.isSteal,
  );

  /// 打席結果をイベントとして確定させる。
  ///
  /// 現在の打席にすでに結果が入力されている場合は、同じイベントIDのまま
  /// 新しい内容で差し替える（＝上書き入力）。
  void commitAtBat({
    required AtBatResult result,
    required String direction,
    required BaseRunners runnersAfter,
    required int runs,
    required int rbi,
    required int outsAdded,
    required List<String> scoredPlayerIds,
    String? errorPlayerId,
  }) {
    final s = state;
    final batter = s.currentBatters[s.currentBatterIndex];
    final target = s.activeEvent;
    final isUpdate = target != null;

    // ジャンプ機能で既に3アウト成立済みの半イニングへ戻っている場合、
    // 新規の打席入力（上書き更新ではない）を追加すると集計対象外のまま
    // 残り続けてしまうため記録しない。
    if (!isUpdate && s.outs >= 3) {
      return;
    }

    final event = GameEvent(
      eventId: isUpdate ? target.eventId : s.nextEventId,
      inning: s.inning,
      isTop: s.isTop,
      description: '',
      batterId: batter.id,
      batterIndex: s.currentBatterIndex,
      pitcherId: isUpdate ? target.pitcherId : s.activePitcher.id,
      cycleIndex: s.currentCycle,
      result: result,
      direction: direction,
      errorPlayerId: errorPlayerId,
      rbi: rbi,
      runs: runs,
      // 失策がからむ得点は自責点に含めない。
      earnedRuns: (result == AtBatResult.error || errorPlayerId != null)
          ? 0
          : runs,
      scoredPlayerIds: scoredPlayerIds,
      runnersAfter: runnersAfter,
      outsAdded: outsAdded,
    );

    // 説明文は displayShortLabel を使うため、確定後のイベントから組み立てる。
    final described = _withDescription(
      event,
      '${s.currentBatterIndex + 1}番 ${batter.name}: ${event.displayShortLabel}',
    );

    List<GameEvent> events;
    if (isUpdate) {
      events = [...s.gameEvents];
      final index = events.indexWhere((e) => e.eventId == event.eventId);
      events[index] = described;
    } else {
      events = [...s.gameEvents, described];
    }

    var next = s.copyWith(
      gameEvents: events,
      nextEventId: isUpdate ? s.nextEventId : s.nextEventId + 1,
      redoStack: const [],
    );
    next = _recomputeReplay(next);

    final (afterChange, changed) = _changeInningIfCompleted(
      next,
      advanceBatter: !isUpdate,
    );
    _commitLocalAndSync(
      (!changed && !isUpdate) ? _nextBatter(afterChange) : afterChange,
    );
  }

  /// 名簿・チーム名も含めて初期状態から新しい試合を開始する。
  void startNewGame() {
    state = GameSessionState.initial();
  }

  /// 保存済みの試合データから状態を復元する。
  void loadGame(SavedGame saved) {
    final placeholder = GameSessionState(
      gameEvents: saved.gameEvents,
      nextEventId: saved.nextEventId,
      gameDate: saved.gameDate,
      teamNameTop: saved.teamNameTop,
      teamNameBottom: saved.teamNameBottom,
      totalInningsConfig: saved.totalInningsConfig,
      inning: saved.inning,
      isTop: saved.isTop,
      batterIndexTop: saved.batterIndexTop,
      batterIndexBottom: saved.batterIndexBottom,
      cycleIndexTop: saved.cycleIndexTop,
      cycleIndexBottom: saved.cycleIndexBottom,
      playersTop: saved.playersTop,
      playersBottom: saved.playersBottom,
      currentPitcherIdTop: saved.currentPitcherIdTop,
      currentPitcherIdBottom: saved.currentPitcherIdBottom,
      replay: GameState.initial(innings: saved.totalInningsConfig),
      // 編集権限は端末ローカルな情報であり SavedGame には含まれないため、
      // 読込前の値を引き継ぐ（リアルタイム更新の取り込みでリセットしない）。
      canEdit: state.canEdit,
    );
    state = _recomputeReplay(placeholder);
  }

  /// 端末がこの試合の編集権限を持っているかどうかを設定する。
  void setCanEdit(bool value) {
    state = state.copyWith(canEdit: value);
  }

  /// 現在の状態を保存用スナップショットに変換する。
  SavedGame toSavedGame(String gameId, {DateTime? savedAt}) {
    final s = state;
    return SavedGame(
      gameId: gameId,
      savedAt: savedAt ?? DateTime.now(),
      gameDate: s.gameDate,
      teamNameTop: s.teamNameTop,
      teamNameBottom: s.teamNameBottom,
      totalInningsConfig: s.totalInningsConfig,
      inning: s.inning,
      isTop: s.isTop,
      batterIndexTop: s.batterIndexTop,
      batterIndexBottom: s.batterIndexBottom,
      cycleIndexTop: s.cycleIndexTop,
      cycleIndexBottom: s.cycleIndexBottom,
      currentPitcherIdTop: s.currentPitcherIdTop,
      currentPitcherIdBottom: s.currentPitcherIdBottom,
      nextEventId: s.nextEventId,
      playersTop: s.playersTop,
      playersBottom: s.playersBottom,
      gameEvents: s.gameEvents,
    );
  }

  void changePitcher(String playerId) {
    final s = state;
    _commitLocalAndSync(
      s.isTop
          ? s.copyWith(currentPitcherIdBottom: playerId)
          : s.copyWith(currentPitcherIdTop: playerId),
    );
  }

  void setTotalInnings(int val) {
    _commitLocalAndSync(
      _recomputeReplay(state.copyWith(totalInningsConfig: val)),
    );
  }

  void updateTeamNames({required String top, required String bottom}) {
    _commitLocalAndSync(
      state.copyWith(teamNameTop: top, teamNameBottom: bottom),
    );
  }

  void updateGameDate(DateTime date) {
    _commitLocalAndSync(state.copyWith(gameDate: date));
  }

  void resetGame() {
    _commitLocalAndSync(
      _recomputeReplay(
        state.copyWith(
          gameEvents: const [],
          nextEventId: 1,
          inning: 1,
          isTop: true,
          batterIndexTop: 0,
          batterIndexBottom: 0,
          cycleIndexTop: 0,
          cycleIndexBottom: 0,
          redoStack: const [],
        ),
      ),
    );
  }

  /// 打者の氏名・守備位置を編集する（空欄の場合は変更しない）。
  ///
  /// 得点や失策はイベントの再生結果から自動集計されるため、ここでは編集しない。
  void editPlayer(Player player, {String? name, String? position}) {
    if (name != null && name.isNotEmpty) {
      player.name = name;
    }
    if (position != null && position.isNotEmpty) {
      player.position = position;
    }
    touch();
  }

  /// 指定したチームの打順末尾に新しい選手を追加する。
  void addPlayer(bool toTopTeam) {
    final s = state;
    final list = toTopTeam ? s.playersTop : s.playersBottom;
    final newPlayer = Player(
      id: '${toTopTeam ? "t" : "b"}${list.length + 1}',
      name: '選手名${list.length + 1}',
      position: '',
    );
    _commitLocalAndSync(
      toTopTeam
          ? s.copyWith(playersTop: [...list, newPlayer])
          : s.copyWith(playersBottom: [...list, newPlayer]),
    );
  }

  /// 選手一覧の中身を直接ミューテートした後、UI に変更を通知する。
  void touch() {
    _commitLocalAndSync(state.copyWith());
  }
}

final gameProvider = NotifierProvider<GameNotifier, GameSessionState>(
  GameNotifier.new,
);

/// 楽観的並行性制御で書き込みが競合した際に表示するメッセージ。
///
/// `null` は「表示すべきメッセージなし」を表す。表示側
/// （`ScoreInputScreen`）は `ref.listen` で監視し、表示後にこの値を
/// `null` へ戻す。
class ConflictMessageNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void show(String message) => state = message;
  void clear() => state = null;
}

final conflictMessageProvider =
    NotifierProvider<ConflictMessageNotifier, String?>(
      ConflictMessageNotifier.new,
    );
