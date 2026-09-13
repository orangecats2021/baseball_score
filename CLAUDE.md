# Baseball Score Web App Rules

- Platform: Flutter Web (Mobile-friendly responsive UI)
- State Management: flutter_riverpod
- Styling: Material 3, optimized for smartphone screens
  (max-width: 480px on narrow screens, up to 900px on desktop-sized screens
  — see `kWideScreenBreakpoint` / `kAppMaxWidthWide` in `lib/app.dart`)
- Storage: Firestore（`games` コレクション、複数人での共有・同時編集用）。
  テーマ設定など端末ローカルな値のみ shared_preferences を使う。
- Routing: go_router（`lib/router.dart`）。GitHub Pages が静的ホスティングの
  ため、Flutter Web標準のハッシュURL戦略のまま使う（`usePathUrlStrategy()`は呼ばない）。

## ローカル開発（Firebase）

Firebase設定値は `--dart-define` で注入する（`lib/firebase_options_web.dart`）。
`dart_define.example.json` を参考に、実際の値を入れた `dart_define.local.json`
（`.gitignore` 対象、コミットしない）を作成し、以下で起動する。

```
flutter run -d chrome --dart-define-from-file=dart_define.local.json
```

CI（`.github/workflows/deploy.yml`）は同じ値をGitHub Secretsから注入する。

# Language

- Respond in Japanese.
- Code comments should be in Japanese.

# 現在の構成

```
lib/models/     at_bat_result / base_runners / game_event / resolved_event
                player / player_stats / game_state / saved_game
lib/logic/      advance_calculator.dart  … 標準的な進塁計算（純粋関数）
                game_replay.dart         … replayGame(): イベント列→全成績（純粋関数）
                box_score_report.dart    … BoxScoreReport組み立て（表示/PDF/Excel共通、純粋関数）
lib/providers/  game_provider.dart       … GameSessionState / GameNotifier
                                            （同期・楽観的排他制御込み）
lib/services/   game_sync_service.dart   … Firestoreへの保存・読込・購読、
                                            編集キー／編集権限／管理者権限の検証
                pdf_export_service.dart  … ボックススコアのPDF生成（printing/PdfGoogleFonts）
                excel_export_service.dart… ボックススコアのxlsx生成
lib/utils/      edit_key_hash.dart       … 編集キーのSHA-256ハッシュ化
lib/firebase_options_web.dart … --dart-define から FirebaseOptions を組み立て
lib/router.dart … go_router のルート定義（'/' と '/game/:gameId'）
lib/app.dart    … BaseballScoreApp（テーマ・ダークテーマ・最大幅480pxの枠）
lib/main.dart   … main()。Firebase初期化・匿名認証を行ってから起動する
lib/screens/    game_list_screen / score_input_screen
lib/widgets/    board/  … 盤面入力タブとその部品
                stats/  … スコア・成績タブとその部品、box_score_view.dart（ボックススコア表示）
                dialogs/… 1ダイアログ1ファイル（admin_key_dialog / box_score_dialog 含む）
firestore.rules … 編集キー・編集権限・管理者権限・楽観的排他制御のルール定義
test/logic/     … ロジックの単体テスト
test/models/    … JSON 変換・PlayerStats集計のテスト
test/utils/     … edit_key_hash のテスト
test/widget_test.dart … 画面の回帰テスト（GameSyncService はフェイク実装で上書き）
```

## 設計の中心

- **`_gameEvents`（`List<GameEvent>`）だけが試合の「事実」**。スコアも個人成績も
  `replayGame()` で毎回ゼロから再計算する（イベントソーシング）。
- `GameEvent` は **入力された事実のみ**を持ち、全フィールド `final`。
  アウトカウントや直前の走者状況は半イニングを再生しないと確定しないため
  `ResolvedEvent` 側が持つ。
- `Player` は名簿情報のみ。成績は `player.stats`（`PlayerStats`）に再生結果が差し込まれる。
- 集計ロジックを変更するときは `lib/logic/` を直し、`test/logic/` にテストを足すこと。
  UI 層（`lib/screens` / `lib/widgets`）に集計ロジックを書き戻さない。
- 画面の再描画は `ScoreInputScreen.build()` 先頭の `ref.watch(gameProvider)` 1箇所だけ。
  タブ・ダイアログへは `GameSessionState` と `GameNotifier` を引数で渡す
  （個別に `ref.watch` する `ConsumerWidget` を増やさない）。

## 複数人同時編集（Firebase）

- 試合データは `games/{gameId}` ドキュメント1件が `SavedGame.toJson()` 相当
  （`docVersion`/`sortOrder`/`updatedAt` を加えたもの）。イベント列以外に
  `editPlayer`/`changePitcher`/`updateTeamNames` などGameEventを発行しない
  変更も含めて丸ごと同期する。
- `GameNotifier` の内容を変更する全メソッド（`jumpTo*`/`selectCycle` などの
  カーソル移動系を除く）は `_commitLocalAndSync()` を経由する。ローカルへ
  即時反映しつつ、購読中の試合があれば `docVersion` を使った楽観的排他制御で
  Firestoreへ書き込む。サーバー側が自分の知っている版から進んでいた場合は
  `StaleGameStateException` を投げて書き込みを諦め、`conflictMessageProvider`
  経由でメッセージを表示する（購読中の `snapshots()` が直後に最新内容を配信する）。
- 編集者／閲覧者の区別は Firebase匿名認証＋作成者が設定する編集キーで行う
  （`firestore.rules` / `lib/services/game_sync_service.dart`）。キーのハッシュは
  誰も読めないドキュメント（`secret/config`）に保存し、本人だけが読める
  `editors/{uid}` の有無で編集権限を判定する。閲覧のみで開いた場合
  （`GameSessionState.canEdit == false`）はUI側で変更系操作を無効化する。
- `test/widget_test.dart` の `FakeGameSyncService` は実際のFirestoreに繋がない
  インメモリ実装。新しいテストもこれを使い、実FirebaseへのアクセスはWebで
  手動確認する（Firebase Local Emulator Suiteは未導入）。
- 管理者モード：全試合共通のマスターキーを知っている端末は、個別の編集キー
  なしにどの試合も編集できる（`admins/{uid}` の有無を `firestore.rules` の
  `isEditor()` がOR条件で見る）。マスターキーのハッシュ（`config/adminKey`）
  はアプリからは書き込めず、Firebaseコンソールから手動で1回だけ登録する
  運用（セットアップ手順は次項参照）。

### 管理者キーのセットアップ手順（初回のみ・手動）

アプリからは `config/adminKey` ドキュメントを書き込めない設計にしている
（「最初にアクセスした人が管理者キーを乗っ取れてしまう」ことを防ぐため）。
そのため、以下の手順で運営者が手動で1回だけ登録する。

1. 管理者キーにしたい文字列を決める。
2. `lib/utils/edit_key_hash.dart` の `hashEditKey()` と同じ
   SHA-256で、そのキーのハッシュ値（16進数64文字）を計算する
   （例: `dart run` で `print(hashEditKey('決めたキー'));` を実行するだけの
   一時スクリプトを書いて実行し、値を確認したら削除する）。
3. Firebaseコンソール → Firestore Database → `config` コレクション →
   ドキュメントID `adminKey` を作成し、フィールド `adminKeyHash`
   （文字列）に2.のハッシュ値を設定する。
4. `firestore.rules` の変更（`isAdmin()` 関数・`config/adminKey` /
   `admins/{uid}` のルール追加）を
   `firebase deploy --only firestore:rules` でデプロイする
   （このコマンドは各自の環境から実行すること。CIには含めていない）。
5. 管理者キーをローテーションしたい場合は、3.の `adminKeyHash` を
   Firebaseコンソールから書き換える（ルールで `update` を禁止しているため、
   一度削除してから作り直す）。既存の `admins/{uid}` は無効化されないため、
   権限を剥奪したい相手がいる場合は該当ドキュメントも合わせて削除する。

## 作業前後に必ず実行

```
flutter analyze --no-pub      # 0件を維持すること
flutter test                  # 全件成功を維持すること
```

残作業は [TODO.md](TODO.md) を参照。

## リリースノートの管理

- ユーザーに見える機能追加・修正をmainに取り込んだら、[README.md](README.md)
  の「更新履歴」に1〜数行で追記する（新しいものを上に）。
- [TODO.md](TODO.md) は残作業のみを保つ。対応が完了した項目は残さず削除し、
  内容が必要ならREADME.mdの更新履歴側に反映する。
