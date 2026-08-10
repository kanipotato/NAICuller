# NAICuller

NovelAIで生成したPNG画像（1万枚超）を、タグ付け→絞り込み→選択→JSONエクスポートというワークフローでキーボード中心に仕分けるためのビューワアプリ。

タグは画像ファイル自体のメタデータ（XMP:Subject）に書き込む。移動・削除などファイルシステムへの破壊的操作はアプリでは一切行わない。エクスポートしたJSONのパスをもとに、ユーザー自身がシェルで`mv`/`rm`する前提。

## 機能

- **サムネイルグリッド**：`NSCollectionView`による仮想スクロールで1万枚超でもスクロールが固まらない。表示直前の遅延生成＋前後1画面分の先読みでサムネイルを`~/Library/Caches`にJPEGキャッシュ
- **タグ付け（キーボード中心）**
  - `F`：お気に入り（トグル）
  - `G`：削除対象（トグル。フラグを付けるだけで実際の削除はしない）
  - `1`〜`9`：設定画面で割り当てたカスタムタグ（トグル）
  - 矢印キー：プレビューを維持したまま前後の画像へ移動
  - 右パネルの＋ボタンから既存タグ選択・自由入力タグ追加も可能
- **タグ絞り込み**：サイドバーでタグをチェックして絞り込み。「用途:blog」のような`:`区切りタグは自動でカテゴリ見出しにグルーピング
- **右パネル**：プレビュー画像（アスペクト比を保って幅に追従）／タグ情報／システム情報（パス・サイズ・作成日時等）／プロンプト（折りたたみ表示＋コピー ボタン）
- **JSONエクスポート**：選択画像の`filePath`・`prompt`をJSON配列で書き出し。項目は追加しやすい構造
- **差分スキャン**：2回目以降はmtime/file_sizeが変わっていないファイルを再読み込みしない。ファイルシステム上から消えたレコードは「孤児レコード」として確認の上で削除（自動削除はしない）
- **DBが正データを持たない設計**：タグの正データは画像ファイル側（XMP:Subject）。DB（`~/Library/Application Support`）を削除しても再スキャンで復元できる

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
3. グリッドで画像を選び、矢印キーで移動しながら`F`/`G`/`1`〜`9`でタグ付け
4. サイドバーでタグを選んで絞り込み → 選択 → ツールバー（または右パネル）からJSONエクスポート
5. エクスポートしたJSONの`filePath`を見ながら、シェルで`mv`/`rm`等の実際のファイル操作を行う

## 仕組み

- **SwiftUI**をベースに、性能が必要なサムネイルグリッドだけ`NSViewRepresentable`で`NSCollectionView`を包む（`NSCollectionViewPrefetching`で先読み）
- **SQLite**は外部依存を追加せず、システム標準の`import SQLite3`を直接使用（GRDB/SQLite.swift等は不使用）
- **ExifTool**はバイナリを同梱せず、`brew install exiftool`でインストール済みの`/opt/homebrew/bin/exiftool`等を`Process()`で`-stay_open True -@ -`により常駐させ、パイプ経由でコマンドを流す自前ラッパー
  - `Sources/NAICullerCore/` : DB(`DatabaseService`/`ImageRepository`/`TagRepository`)・ExifTool連携(`ExifToolProcess`/`ExifToolService`)・スキャン差分判定(`ScanService`)・サムネイル生成(`ThumbnailService`)・エクスポート(`ExportService`)・バリデーション(`TagNameValidator`/`RootPathValidator`)など、SwiftUI/AppKitに依存しない純粋なロジック
  - `Sources/NAICuller/` : `NAICullerApp.swift`（アプリ本体）、`AppModel.swift`（状態管理）、`Views/`（UI本体）、`KeyHandling/`（キーボード操作）
  - `Tests/NAICullerCoreTests/` : `swift test` で実行する単体・結合テスト（ExifToolServiceTestsは実際にNovelAI生成PNGでexiftoolサブプロセスを起動する結合テスト）

## タグの保存先

タグの正データは画像ファイル側のメタデータ（`XMP:Subject`、`-XMP-dc:Subject`で読み書き）に持たせる。NovelAIが生成時に書き込む`PNG:Description`（プロンプト本文）・`PNG:Comment`（生成パラメータ）とは別の名前空間なので衝突しない。DB（`~/Library/Application Support/io.github.kanipotato.naiculler/db.sqlite`）はあくまで表示高速化用のキャッシュであり、削除しても再スキャンでタグを復元できる。

## 制限事項（MVP外）

- 複数選択時の一括タグ付けは未対応
- `rm`コマンド文字列のクリップボードコピー補助は無し
- ゴミ箱移動（メニューバー）は無し
- FSEventsによるファイル変更の自動追従は無し（再スキャンは手動ボタンのみ）
- ソート順の細かい制御は無し
- App Store対応・Sandbox対応はしていない（個人ローカル利用のみを想定）

## ライセンス

MIT
