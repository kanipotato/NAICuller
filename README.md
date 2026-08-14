# NAICuller

NovelAIで生成したPNG画像（1万枚超）を、タグ付け→絞り込み→選択→JSONエクスポートというワークフローでキーボード中心に仕分けるためのビューワアプリ。

タグは画像ファイル自体のメタデータ（XMP:Subject）に書き込む。「削除対象」タグを付けた画像をゴミ箱へ移動する機能を除き、移動・削除などファイルシステムへの破壊的操作はアプリでは行わない。エクスポートしたJSONのパスをもとに、ユーザー自身がシェルで`mv`/`rm`する運用も引き続き可能。

## 機能

- **サムネイルグリッド**：`NSCollectionView`による仮想スクロールで1万枚超でもスクロールが固まらない。表示直前の遅延生成＋前後1画面分の先読みでサムネイルを`~/Library/Caches`にJPEGキャッシュ
- **Finder風の複数選択**：クリック／Cmd+クリック（個別トグル）／Shift+クリック（範囲選択）に対応。右クリックメニューは選択中の全画像が対象になる
- **タグ付け（キーボード中心）**
  - `F`：お気に入り（トグル）
  - `G`：削除対象（トグル。フラグを付けるだけで実際の削除はしない）
  - `1`〜`9`：設定画面で割り当てたカスタムタグ（トグル）
  - 複数選択中は選択画像すべてに一括反映（右クリックメニューからも操作可能）
  - 矢印キー：プレビューを維持したまま前後の画像へ移動
  - 右パネルの＋ボタンから既存タグ選択・自由入力タグ追加も可能
- **絞り込み・検索・並び替え**
  - サイドバーでタグをチェックして絞り込み。「用途:blog」のような`:`区切りタグは自動でカテゴリ見出しにグルーピング
  - 「未タグのみ表示」トグル（タグ絞り込みとは排他）
  - プロンプト文字列でのインクリメンタル検索（デバウンス付き）
  - プロンプト候補絞り込み：有効なルート内の画像プロンプトをカンマ区切りタグとして分析し、頻出語句（2件以上の画像に登場したもののみ、多い順）をチェックボックス候補として表示。選んだ語句すべてを含む画像に絞り込む（AND条件）
  - 並び替え：作成日時（新しい／古い順）・ファイル名（昇順／降順）・ファイルサイズ（大きい／小さい順）
- **大きく表示**
  - Quick Look（スペースキー／右クリック／ツールバー）：選択画像に追従してリサイズ可能な標準パネルで表示
  - 固定表示ウィンドウ（右クリック「この画像を固定表示」）：選択に連動せず1枚だけを表示し続ける独立ウィンドウ。画像ごとに複数枚同時に開けるので、見比べながらの比較用途に使える
- **「削除対象」タグの一括ゴミ箱移動**：選択中／全件のいずれかを`NSWorkspace`経由でゴミ箱へ移動（Finderのゴミ箱から復元可能。完全削除はしない）
- **右パネル**：プレビュー画像（アスペクト比を保って幅に追従）／タグ情報／システム情報（パス・サイズ・作成日時等、パスはコピー ボタン付き）／プロンプト（折りたたみ表示＋コピー ボタン）
- **JSONエクスポート**：選択画像の`filePath`・`prompt`をJSON配列で書き出し。項目は追加しやすい構造
- **差分スキャン**：2回目以降はmtime/file_sizeが変わっていないファイルを再読み込みしない。ファイルシステム上から消えたレコードは「孤児レコード」として確認の上で削除（自動削除はしない）
- **DBが正データを持たない設計**：タグの正データは画像ファイル側（XMP:Subject）。DB（`~/Library/Application Support`）を削除しても再スキャンで復元できる
- **ショートカット一覧をツールバーから表示**：キーボードショートカット・カスタムタグの割当を画面内でいつでも確認できる

## 動作環境

- macOS 13以降
- ビルドに Swift Package Manager（Xcode Command Line Tools に同梱）が必要
- [ExifTool](https://exiftool.org/) が必要（`brew install exiftool`）。未インストールの場合は起動時に案内ダイアログが出て、スキャン・タグ付け機能がグレーアウトする

## ビルドとインストール

```sh
./build.sh
```

`swift build -c release` でコンパイル → ad-hoc署名 → `~/Applications/NAICuller.app` に配置まで自動で行う。起動は:

```sh
open ~/Applications/NAICuller.app
```

## 使い方

1. ツールバーの「ルート追加」（または設定画面）からNovelAI画像が入ったフォルダを登録
2. 「再スキャン」でDBに取り込み（ExifToolでプロンプト・画像サイズを読み込む）
3. グリッドで画像を選び、矢印キーで移動しながら`F`/`G`/`1`〜`9`でタグ付け（複数選択中は一括反映）
4. サイドバーのタグ絞り込み・プロンプト検索・並び替えで見たい画像を絞り込む
5. 選択 → ツールバー（または右パネル）からJSONエクスポート。「削除対象」タグを付けたものはメニューからゴミ箱へまとめて移動も可能
6. 大きく見たいときはスペースキー（選択に追従）、比較したいときは右クリック「この画像を固定表示」（選択に非追従、複数枚同時表示可）

## 仕組み

- **SwiftUI**をベースに、性能が必要なサムネイルグリッドだけ`NSViewRepresentable`で`NSCollectionView`を包む（`NSCollectionViewPrefetching`で先読み、Shift+クリックの範囲選択は`NSCollectionView`に無いため自前実装）
- **SQLite**は外部依存を追加せず、システム標準の`import SQLite3`を直接使用（GRDB/SQLite.swift等は不使用）
- **ExifTool**はバイナリを同梱せず、`brew install exiftool`でインストール済みの`/opt/homebrew/bin/exiftool`等を`Process()`で`-stay_open True -@ -`により常駐させ、パイプ経由でコマンドを流す自前ラッパー
- **QLPreviewPanel（QuickLookUI）**で選択追従のプレビューを実装。アプリ全体で1インスタンスしか持てない制約があるため、比較用の固定表示ウィンドウはSwiftUIの値付き`WindowGroup(for:)` + `openWindow(value:)`で別実装している
  - `Sources/NAICullerCore/` : DB(`DatabaseService`/`ImageRepository`/`TagRepository`)・ExifTool連携(`ExifToolProcess`/`ExifToolService`)・スキャン差分判定(`ScanService`)・サムネイル生成(`ThumbnailService`)・エクスポート(`ExportService`)・バリデーション(`TagNameValidator`/`RootPathValidator`)など、SwiftUI/AppKitに依存しない純粋なロジック
  - `Sources/NAICuller/` : `NAICullerApp.swift`（アプリ本体）、`AppModel.swift`（状態管理）、`Views/`（UI本体）、`KeyHandling/`（キーボード操作）
  - `Tests/NAICullerCoreTests/` : `swift test` で実行する単体・結合テスト（ExifToolServiceTestsは実際にNovelAI生成PNGでexiftoolサブプロセスを起動する結合テスト）

## タグの保存先

タグの正データは画像ファイル側のメタデータ（`XMP:Subject`、`-XMP-dc:Subject`で読み書き）に持たせる。NovelAIが生成時に書き込む`PNG:Description`（プロンプト本文）・`PNG:Comment`（生成パラメータ）とは別の名前空間なので衝突しない。DB（`~/Library/Application Support/io.github.kanipotato.naiculler/db.sqlite`）はあくまで表示高速化用のキャッシュであり、削除しても再スキャンでタグを復元できる。

## 制限事項（MVP外）

- `rm`コマンド文字列のクリップボードコピー補助は無し（「削除対象」タグの一括ゴミ箱移動で概ね代替可能）
- FSEventsによるファイル変更の自動追従は無し（再スキャンは手動ボタンのみ）
- App Store対応・Sandbox対応はしていない（個人ローカル利用のみを想定）

## ライセンス

MIT
