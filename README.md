# bsky-to-obsidian

Bluesky のログファイル（CAR ファイル）から自分の投稿を取り出し、Obsidian の Daily note に書き込むためのスクリプトです。

Daily note には以下の形式で挿入します。

```md
<!-- bsky-to-obsidian:start -->
12:34
投稿本文全文

13:20
投稿本文全文
<!-- bsky-to-obsidian:end -->
```

挿入した部分を削除するスクリプトも用意しています。

## セットアップ

依存 gem を入れます。

```sh
bundle install
```

`config.example.yml` をコピーして、自分用の `config.yml` を作ります。

```sh
cp config.example.yml config.yml
```

`config.yml` はローカル設定用で、Git 管理しない想定です。

CAR ファイルは次のどちらかで用意します。

1. Bluesky のページで「*設定 > アカウント > 私のデータをエクスポートする > CARファイルをダウンロード*」を選び、ファイルをスクリプトと同じディレクトリに保存する
2. 公開投稿であれば `download_car.rb` でダウンロードする

デフォルトの保存先は `repo.car` です。別の名前を使う場合は `extract.car_path` を変更してください。

## 設定

例:

```yaml
bluesky:
  handle: bsky.app

extract:
  car_path: repo.car
  out_dir: out

obsidian:
  vault_path: "/Users/user/Documents/obsidian"
  timezone: Asia/Tokyo

  daily:
    path_format: "Daily/%Y/%Y-%m-%d.md"

  posts:
    exclude_texts:
      - ""
```

### `bluesky.handle`

`download_car.rb` で CAR ファイルをダウンロードするときに使う Bluesky のハンドルです。手動で CAR ファイルを用意する場合は不要です。

### `extract.car_path`

入力する CAR ファイルです。デフォルト例では `repo.car` です。

### `extract.out_dir`

抽出結果の出力先です。`records.jsonl` と個別 JSON ファイルを書き出します。

### `obsidian.vault_path`

Obsidian vault のパスです。iCloud Drive 上の vault はパスにスペースが入るので、YAML では引用符で囲んでください。

### `obsidian.daily.path_format`

Daily note の相対パスです。日付は `strftime` の形式で指定します。

たとえば次の設定は:

```yaml
path_format: "Daily/%Y/%Y-%m-%d.md"
```

次のような Daily note に対応します。

```text
Daily/2026/2026-05-15.md
```

### `obsidian.posts.exclude_texts`

本文に含まれていたら Obsidian に書き込まない文字列です。

## 使い方

```sh
bundle exec ruby bsky_to_obsidian.rb
```

設定ファイルを明示する場合:

```sh
bundle exec ruby bsky_to_obsidian.rb --config=config.yml
```

抽出だけ実行する場合:

```sh
bundle exec ruby extract_car.rb
```

repo.car をダウンロードする場合:

```sh
bundle exec ruby download_car.rb
```

Obsidian への書き込みだけ実行する場合:

```sh
bundle exec ruby upsert_obsidian_daily_notes.rb
```

書き込んだところを削除する場合:

```sh
bundle exec ruby delete_obsidian_daily_notes.rb
```

## Obsidian への書き込み

Daily note 内の次の管理ブロックを更新します。

```md
<!-- bsky-to-obsidian:start -->
...
<!-- bsky-to-obsidian:end -->
```

ブロックがなければ末尾に追加します。対象日の Daily note がなければ作成します。

## CAR ファイルのダウンロード

投稿を公開している場合は、スクリプトで CAR ファイルをダウンロードできます。保存先は `extract.car_path` です。

以下の設定をしてから、

```yaml
bluesky:
  handle: bsky.app
```

以下を実行します。

```sh
bundle exec ruby download_car.rb
```
