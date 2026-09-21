# bsky-to-obsidian

Bluesky の公開 API と X の RSS から自分の投稿を取り出し、Obsidian の Daily note に書き込むためのスクリプトです。
Bluesky の過去分は初回に CAR ファイルから取り込み、以後は API で最新分を取得します。
Bluesky と X は別々のスクリプトで実行し、同じ Daily note 内の専用ブロックをそれぞれ更新します。

Daily note には以下の形式で挿入します。

```md
<!-- bsky-to-obsidian:start -->
`12:34`
投稿本文全文

`13:20`
投稿本文全文
<!-- bsky-to-obsidian:end -->

<!-- x-to-obsidian:start -->
`14:05` [X](https://x.com/kdmsnr/status/1234567890)
X の投稿本文全文
<!-- x-to-obsidian:end -->
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

Bluesky のアカウントを `bluesky.handle`（または `bluesky.did`）に設定します。
ログイン情報と RSS の URL は不要です。
初回は CAR ファイルで過去分をまとめて取り込み、API を呼び出す回数を抑えます。

既存の `out/records.jsonl` があれば再利用します。
抽出結果がなければ CAR ファイルを抽出し、CAR ファイルもなければ自動でダウンロードします。

CAR ファイルをあらかじめ用意する場合は、次のどちらかで取得します。

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

x:
  handle: kdmsnr
  archive_dir: x-archive

obsidian:
  vault_path: "/Users/user/Documents/obsidian"
  timezone: Asia/Tokyo

  daily:
    path_format: "Daily/%Y/%Y-%m-%d.md"

  posts:
    exclude_texts:
      - ""
```

### `bluesky.did` と `bluesky.handle`

公開 API と CAR ファイルの取得対象です。
どちらかの指定が必要で、両方指定した場合は `did` を優先します。
DID を使うと、ハンドルの変更後も同じアカウントを取得できます。

### `extract.car_path`

初回の履歴作成に使う CAR ファイルです。
デフォルトは `repo.car` で、必要なファイルがなければ自動でダウンロードします。
`--refresh-car` または `download_car.rb` で再取得する場合も、このパスに保存します。

### `extract.out_dir`

CAR の抽出結果と Bluesky の投稿履歴の保存先です。
CAR の抽出では `records.jsonl` と個別 JSON ファイルを書き出し、通常の取り込みでは `posts.jsonl` に履歴を蓄積します。
Daily note は `posts.jsonl` を優先し、なければ `records.jsonl` から生成します。
このディレクトリは Git 管理の対象外なので、履歴を残すためにバックアップしてください。
保存先を変更した場合は、必要に応じて `.gitignore` にも追加してください。

### `x.handle`

Daily note に書き込む X のアカウント名です。
RSS に他人の投稿のリポストが含まれていても、その投稿は Daily note には書き込みません。
RSS には返信先を判定する情報がないため、自分の返信は取り込みます。

### `x.feed_url`

X の RSS 2.0 フィードの URL です（省略可）。
省略時は `x.handle` から `https://fxtwitter.com/<handle>/feed.xml` を組み立てます。
別の RSS 取得先を使う場合だけ指定してください。
Bluesky 用スクリプトでは `x` の設定を使いません。

### `x.archive_dir`

取得した RSS と投稿履歴の保存先です。
デフォルトは `x-archive` で、Bluesky の抽出先とは独立しています。
このディレクトリは Git 管理の対象外ですが、過去の投稿を残すためにバックアップしてください。
保存先を変更した場合は、必要に応じて `.gitignore` にも追加してください。

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
Bluesky と X の両方に適用します。
Bluesky と X の履歴ファイルには、除外した投稿も残します。

### `obsidian.posts.days`

Bluesky と X のログを Obsidian に反映する日数です。
省略時は全期間を対象にします。
1 以上の整数を指定すると、`obsidian.timezone` での今日を含む直近 N 日分だけ反映します。
たとえば `days: 7` なら、今日から 6 日前までが対象です。

```yaml
obsidian:
  posts:
    days: 7
```

対象期間外の Daily note は変更しません。
取得と履歴保存の範囲は制限しません。
Bluesky の通常実行では保存済みの投稿に追いつくまで API を取得し、CAR の取り込みと X の RSS 履歴保存では入力全件を対象にします。
コマンドラインの `--days N` を指定した場合は、設定ファイルの値より優先します。

## 使い方

Bluesky を取り込む場合:

```sh
bundle exec ruby bsky_to_obsidian.rb
```

設定ファイルを明示する場合:

```sh
bundle exec ruby bsky_to_obsidian.rb --config=config.yml
```

今日を含む直近 7 日分だけ反映する場合:

```sh
bundle exec ruby bsky_to_obsidian.rb --days 7
```

通常実行では、認証不要の公開 API から100件ずつ取得し、保存済みの通常投稿（リポストを除く）が現れたページまで取り込みます。
保存済みの投稿が見つからない場合は、API が返す最終ページまで取得します。
CAR のダウンロードと抽出は、履歴ができた後の通常実行では行いません。

取得した投稿は AT URI（DID と投稿 ID を含む識別子）で履歴にマージします。
同じ投稿を再取得した場合は内容を更新し、今回取得しなかった投稿も残します。
自分への返信を含めて取り込み、他人への返信と他人の投稿のリポストは Daily note に書き込みません。
API の取得や解析に失敗した場合は、投稿履歴と Daily note を更新せずに終了します。

Daily note は履歴から生成し、内容が変わったファイルだけ書き込みます。
API の取得範囲より古い投稿の変更や削除は追跡しません。
Bluesky 上で削除された投稿も保存済みの履歴には残ります。

ネットワークに接続せず、保存済みの履歴から書き込み直す場合:

```sh
bundle exec ruby bsky_to_obsidian.rb --offline
```

CAR を再取得して過去分を履歴に補完する場合:

```sh
bundle exec ruby bsky_to_obsidian.rb --refresh-car
```

`--refresh-car` も既存の履歴にマージするため、CAR から消えた投稿は履歴から削除しません。
`--offline` と `--refresh-car` は同時に指定できません。
どちらも `--days N` を併用できます。

抽出だけ実行する場合:

```sh
bundle exec ruby extract_car.rb
```

これは CAR の抽出結果だけを更新します。
既存の `posts.jsonl` は変更しません。

repo.car をダウンロードする場合:

```sh
bundle exec ruby download_car.rb
```

Obsidian への書き込みだけ実行する場合:

```sh
bundle exec ruby upsert_obsidian_daily_notes.rb
```

`upsert_obsidian_daily_notes.rb` も、設定ファイルの `obsidian.posts.days` と `--days N` に対応しています。

書き込んだところを削除する場合:

```sh
bundle exec ruby delete_obsidian_daily_notes.rb
```

この削除スクリプトは Bluesky の管理ブロックを対象とします。

## X の取り込みと履歴保存

`config.yml` に `x` の設定を追加して実行します。
X だけを利用する場合は、`x` と `obsidian` の設定があれば実行できます。
CAR ファイルは不要です。

```sh
bundle exec ruby x_to_obsidian.rb
```

設定ファイルを明示する場合:

```sh
bundle exec ruby x_to_obsidian.rb --config=config.yml
```

`obsidian.posts.days` を指定すると、Bluesky と同じ日数で更新対象を絞ります。
`--days N` による上書きも、通常の取得、`--offline`、`--feed-file` のいずれでも使えます。

取得した XML は `x-archive/feeds/latest.xml` に上書きし、直近に取り込んだ原本を1件だけ残します。
投稿は投稿 ID ごとに `x-archive/posts.jsonl` に蓄積し、再取得した投稿は最新の内容で更新します。
RSS から消えた投稿も履歴に残るので、次回の実行で Daily note から消えることはありません。
取得前に RSS の配信範囲から外れた過去の投稿は、RSS だけでは復元できません。

旧形式の `feeds/<SHA-256>.xml` がある場合は、次回の取り込み時に未保存の投稿を履歴へ補完します。
投稿履歴と `latest.xml` の保存に成功した後で、旧形式の原本を削除します。
`--offline` では原本の整理を行いません。

Daily note は保存済みの投稿履歴から日付ごとに生成し、X 専用の管理ブロック内を時刻順に並べます。
本文の改行とリンク先を残し、元投稿へのリンクを付けます。
Bluesky の管理ブロックと手書きの本文は保持します。
RSS の取得や解析に失敗した場合は、履歴と Daily note を更新せずに終了します。

ネットワークに接続せず、保存済みの履歴から書き込み直す場合:

```sh
bundle exec ruby x_to_obsidian.rb --offline
```

保存してある RSS ファイルを履歴に追加して書き込む場合:

```sh
bundle exec ruby x_to_obsidian.rb --feed-file path/to/feed.xml
```

`--offline` と `--feed-file` は同時に指定できません。

## Obsidian への書き込み

Bluesky は Daily note 内の次の管理ブロックを更新します。

```md
<!-- bsky-to-obsidian:start -->
...
<!-- bsky-to-obsidian:end -->
```

ブロックがなければ末尾に追加します。対象日の Daily note がなければ作成します。
X は同じルールで `<!-- x-to-obsidian:start -->` から `<!-- x-to-obsidian:end -->` までを更新します。

## CAR ファイルのダウンロード

投稿を公開している場合は、スクリプトで CAR ファイルをダウンロードできます。保存先は `extract.car_path` です。

`bluesky.handle` または `bluesky.did` を設定してから、

```yaml
bluesky:
  handle: bsky.app
```

以下を実行します。

```sh
bundle exec ruby download_car.rb
```
