# holdfast

holdfast は、Rails アプリについて疑ったことを、読んだだけで終わらせずに実際に走らせます。
疑い（バグ、二つのアクションの競合、別の領域への影響）は、それぞれ数行の YAML で書きます。
`holdfast check` はアプリ自身のファクトリで状況を作り、base と head でアクションを走らせます。
答えは三つです。
`confirmed` は残すべき失敗するスペックを伴い、`refuted` は観測した値を伴い、`could_not_run` は正確なエラーを伴います。
`holdfast run` は変更を base と比べて確かめ、何も変わっていないときはアプリの入口をランダムな順序で走らせてバグを探します。

holdfast は、コードを読んで見つけたことを報告するコーディングエージェントのための道具です。
エージェントがたどるループは [`skills/holdfast/`](skills/holdfast/SKILL.md) のスキルにあります。

## Rails アプリでのクイックスタート

Ruby 3.4 以降、git、そして RSpec と FactoryBot で PostgreSQL か SQLite のテスト用データベースに対してスペックが走るアプリが必要です。
各ステップはアプリのルートで実行します。

### 1. gem を追加する

```ruby
group :test do
  gem "holdfast", require: false
end
```

続けて `bundle install` を実行します。
holdfast は hegeltest に依存していて、探索（hunt）がそれを使います。

### 2. 読んで、疑いを書く

以下の例は [`test/fixture/clinic`](test/fixture/clinic) のクリニックアプリで走らせたものです。
このアプリには予約、来なかった予約を no-show にして料金を請求するジョブ、そして受付のチェックインがあります。
ジョブを読むと、怪しい点が二つ見つかります。
確定していない仮予約（tentative）まで対象にしていることと、行を読み込んでから一行ずつロックするので、その間のチェックインが上書きされうることです。
両方を書き出します。

```yaml
- says: a passed tentative appointment is charged a no-show fee
  given: {appointment: {status: tentative, starts_at: -1h}}
  do: NoShowSweepJob.perform_now
  expect: no PaymentGateway charge
- says: check-in between the sweep's load and its lock becomes a no-show
  given: {appointment: {status: booked, starts_at: -20m}}
  race: [NoShowSweepJob.perform_now, "CheckIn.new(appointment).call"]
  expect: appointment.status == "checked_in"
```

`given` はキーごとに、同じ名前のファクトリからレコードを一つ作ります。
`do` は Ruby です。
`race` は、一つ目のアクションを一時停止点で止めて二つ目を走らせ、次にその逆を行い、さらに二つの直列の順序も走らせます。
`expect` は、走らせた後に成り立つべきことです。
書き方のすべては [スキル](skills/holdfast/SKILL.md) にあります。

### 3. 確かめる

```sh
bundle exec holdfast check suspicions.yml
```

初回の実行で、アプリがテストをどう走らせるかを学び、自分専用のテスト用データベースを作ります。
クリニックアプリでの出力の全体は次のとおりです。

```text
# holdfast

check: 2 suspicion(s); no change: checks run on the current tree only (uncommitted changes on 62b0f46); app, lib, config, db and the Gemfile match main (62b0f46)
kept specs: spec/holdfast/main/ (branch main); rows: .holdfast/check/main/check.jsonl
seconds: record 4.2, run 2.4

confirmed=2 could_not_run=0 refuted=0

## Confirmed (the kept spec fails)

- `a passed tentative appointment is charged a no-show fee`: no PaymentGateway charge does not hold (observed [[{customer: "pat_1", amount_cents: 2500, reference: "no-show-1"}]])
  - ran: NoShowSweepJob.perform_now returned [Appointment#1(status: "no_show")]
  - no PaymentGateway charge fails ([[{customer: "pat_1", amount_cents: 2500, reference: "no-show-1"}]])
  - spec output: suspicion confirmed: no PaymentGateway charge does not hold (observed [[{customer: "pat_1", amount_cents: 2500, reference: "no-show-1"}]])
  - repro: `DATABASE_URL=postgres://postgres@127.0.0.1:5440/hf_clinic_c5da1e_c2 TEST_ENV_NUMBER=c2 bundle exec rspec spec/holdfast/main/a_passed_tentative_appointment_is_charged_a_73c143_spec.rb`
  - next: keep spec/holdfast/main/a_passed_tentative_appointment_is_charged_a_73c143_spec.rb; it fails until the code is fixed
- `check-in between the sweep's load and its lock becomes a no-show`: first held at batch_load, second runs (held at Appointment load (1 rows)) ends [[Appointment#1(status: "no_show")], Appointment#1(status: "checked_in"); appointment.status == "checked_in" fails ("no_show")], an end no serial order reaches (first then second ends [[Appointment#1(status: "no_show")], raised CheckIn::Refused; appointment.status == "checked_in" fails ("no_show")]; second then first ends [[], Appointment#1(status: "checked_in"); appointment.status == "checked_in" holds ("checked_in")]); serial order "first then second" also fails expect, so this end is the evidence
  - pause points tried: batch_load: Appointment load (1 rows)
  - first held at batch_load, second runs: NoShowSweepJob.perform_now returned [Appointment#1(status: "no_show")]; CheckIn.new(appointment).call returned Appointment#1(status: "checked_in"); held at Appointment load (1 rows); appointment.status == "checked_in" fails ("no_show")
  - first then second: NoShowSweepJob.perform_now returned [Appointment#1(status: "no_show")]; CheckIn.new(appointment).call raised CheckIn::Refused: appointment is no_show; appointment.status == "checked_in" fails ("no_show")
  - second then first: CheckIn.new(appointment).call returned Appointment#1(status: "checked_in"); NoShowSweepJob.perform_now returned []; appointment.status == "checked_in" holds ("checked_in")
  - second held at batch_load, first runs: CheckIn.new(appointment).call returned Appointment#1(status: "checked_in"); NoShowSweepJob.perform_now returned [Appointment#1(status: "no_show")]; held at Appointment load (1 rows); the second waited on a lock; appointment.status == "checked_in" fails ("no_show")
  - spec output: suspicion confirmed: first held at batch_load, second runs (held at Appointment load (1 rows)) ends [[Appointment#1(status: "no_show")], Appointment#1(status: "checked_in"); appointment.status == "checked_in" fails ("no_show")], an end no serial order reaches (first then second ends [[Appointment#1(status: "no_show")], raised CheckIn::Refused; appointment.status == "checked_in" fails ("no_show")]; second then first ends [[], Appointment#1(status: "checked_in"); appointment.status == "checked_in" holds ("checked_in")]); serial order "first then second" also fails expect, so this end is the evidence
  - repro: `DATABASE_URL=postgres://postgres@127.0.0.1:5440/hf_clinic_c5da1e_c2 TEST_ENV_NUMBER=c2 bundle exec rspec spec/holdfast/main/check_in_between_the_sweep_s_load_and_its_lo_d80794_spec.rb`
  - next: keep spec/holdfast/main/check_in_between_the_sweep_s_load_and_its_lo_d80794_spec.rb; it fails until the code is fixed
rows: .holdfast/check/main/check.jsonl; kept specs: spec/holdfast/main/
```

競合が confirmed になるのは、止めた順序が、どの直列の順序でも到達しない状態で終わったからです。
ある直列の順序でも同じ状態に到達する競合は refuted になります。

### 4. 残す

confirmed の行はそれぞれ `spec/holdfast/<branch>/` の下のスペックを示し、そのスペックはコードを直すまで失敗します。
コードを直し、スペックを走らせ、残します。
ジョブが確定済みの予約（booked）だけを選ぶように直すと、一つ目のスペックは通ります。

```sh
bundle exec rspec spec/holdfast/main/a_passed_tentative_appointment_is_charged_a_73c143_spec.rb
```

```text
1 example, 0 failures
```

終了ステータスは、confirmed の行があれば 2、使い方の誤りなら 1、何も confirmed でなければ 0 です。

## 変更を確かめる

base のブランチと違うブランチの上では（`--base REF` で別の base を指定できます）、疑いはそれぞれ base と作業ツリーの両方で、どちらも head のファクトリで走ります。
行には、その変更が持ち込んだものかどうかが書かれます。
ここではブランチ `skip-tentative` がジョブを確定済みの予約だけを選ぶように変え、同じファイルをもう一度走らせています。

```text
# holdfast

check: 2 suspicion(s); change: each runs on base main (62b0f46) and on the working tree (uncommitted changes on 7c510b0); 1 file(s) differ: app/jobs/no_show_sweep_job.rb
kept specs: spec/holdfast/skip-tentative/ (branch skip-tentative); rows: .holdfast/check/skip-tentative/check.jsonl
seconds: record 0.0, run 2.6

confirmed=1 could_not_run=0 refuted=1

## Confirmed (the kept spec fails)

- `check-in between the sweep's load and its lock becomes a no-show`: first held at batch_load, second runs (held at Appointment load (1 rows)) ends [...]
  - base 62b0f46: confirmed: [...]; it was there before the change
  [...]

## Refuted (what was observed)

- `a passed tentative appointment is charged a no-show fee`: no PaymentGateway charge holds (observed [])
  - base 62b0f46: confirmed: no PaymentGateway charge does not hold (observed [[{customer: "pat_1", amount_cents: 2500, reference: "no-show-1"}]]); the change removes it
  - ran: NoShowSweepJob.perform_now returned []
  - no PaymentGateway charge holds ([])
rows: .holdfast/check/skip-tentative/check.jsonl; kept specs: spec/holdfast/skip-tentative/
```

`[...]` は、上の行の繰り返しになる競合の行から切り取った部分です。
base にないメソッド、カラム、ルートを呼ぶ疑いは head でだけ confirmed になり、行には base では走らせられないと書かれます。

`holdfast run` は、疑いを書かずに変更を確かめます。
変更された各メソッドに一行を与え、変更された定数やスコープの呼び出し元にも行を与えます。
各対象の名前を含むテストを base と head で走らせ、各メソッドの引数からピンの下書きを作ります。
行は `unintended_change`（base で通り head で失敗する）、`intended_change`（意図したと印を付けた違い、または変更で足したテストだけが通る新しい振る舞い）、`unchecked`（誰も引いていない値を示すので、それを疑いとして書く）、`clean`（示した証拠だけを保証する）のいずれかです。
この部分は [jitcatch](https://github.com/meganemura/jitcatch) と [branchout](https://github.com/meganemura/branchout) を使います。
どちらも holdfast といっしょに入ります。

## 何も変わっていないときの探索

変更がないときの `holdfast run` は、アプリの書き込み領域（ルート、Grape のエンドポイント、ジョブ）ごとにシーケンスの定義を一つ `.holdfast/sequences/` に下書きします。
次に、それらのアクションをランダムな順序でテスト用データベースに対して走らせます。
その際、不変条件、別のタイムゾーン、外部呼び出しでの二つのアクションの割り込み、最初のバッチ読み込みの後で止めたジョブ、受け付けられたリクエストをもう一度送ることを試します。
失敗は最短のシーケンスまで縮められます（縮める時間は最大 60 秒です）。
このマシン以外のホストへの接続は拒み、その領域は本物のサービスを呼んだと報告します。
そのサービスの偽物は、領域のファイルに書きます。
`--budget SECONDS` で実行時間の上限を決めます（既定は 600）。
クリニックアプリで、上限を 120 秒にした出力です。

```text
# holdfast

nothing in the app changed against main (b5c13d9)
seconds: record 4.6, hunt 40.8

unintended_change=0 bug_suspect=1 unchecked=0 intended_change=0 clean=0

## Suspected bugs

- `sequences: check_ins`: no_show_sweep_job loaded Appointment#1 with status "booked"; check_ins_create set it to "checked_in" while no_show_sweep_job held it; no_show_sweep_job then wrote "no_show", though its own query does not select a row whose status is "checked_in" (shrinking stopped after 30 s)
  - failure: no_show_sweep_job loaded Appointment#1 with status "booked"; check_ins_create set it to "checked_in" while no_show_sweep_job held it; no_show_sweep_job then wrote "no_show", though its own query does not select a row whose status is "checked_in" (shrinking stopped after 30 s)
  - log: .holdfast/runs/sequences/check_ins.log (the shortest sequence and an `it` block that replays it)
  - next: paste the `it` block from the log into .holdfast/sequences/check_ins.rb, see it fail, fix the code, run again
rows: .holdfast/verdicts.jsonl
```

探索は、疑いを書かなくても、二つ目の疑いと同じ競合を見つけました。
探索の行は疑いにつながります。
それを書き出し、`holdfast check` で確かめます。
`holdfast run --sequences` は変更が触れる領域も探索し、`--observe` は各領域のアクションの順序を base と head で走らせて、違ったステップを一つずつ報告します。

## 使い方

```text
holdfast check [FILE]... [--suspect YAML]... [--base REF] [--here] [--repo DIR]
holdfast run [--base REF] [--target NAME]... [--only NAME]... [--intent TEXT] [--learn] [--sequences] [--observe] [--budget SECONDS] [--repo DIR]
holdfast show
```

- `--suspect YAML` は疑いを一つ YAML のフローマッピングとして渡し、繰り返して使えます。
- `--here` は、変更の上でも、作業ツリーで一度だけ確かめます。
- `--learn` は、失敗したセットアップを直した後に、アプリがテストをどう走らせるかを学び直します。
- `show` は、最後の `holdfast run` の要約をもう一度表示します。

holdfast はアプリの `.holdfast/` と `spec/holdfast/` の下に書き込みます。
`.holdfast/` はアプリの `.gitignore` に加えます。
残すスペックはコミットします。

各アプリは、そのディレクトリから作った自分専用のテスト用データベース名を `DATABASE_URL` で受け取ります。
そのため、base と head、また一つのサーバー上の二つのアプリが、同じデータベースを共有しません。
SQLite では、それぞれの側が `.holdfast/db/` の下に自分専用のファイルを受け取り、アプリ自身のテスト用データベースのファイルには書き込みません。
セットアップは `bin/rails db:create db:schema:load` を実行します。

競合とバグ探しは PostgreSQL と SQLite で走ります。
SQLite では、一度に書き込める接続は一つです。
競合で止めたアクションが、開いたトランザクションの中ですでに書き込んでいると、もう一方のアクションはそれを待ちます。
その行には `the second waited on a lock` と出ます。
MySQL は試していません。

## 制限

- 入力がレコードを一つも作らないピンの下書きは何も確かめませんが、そのピンが変更された行を読み込むと、`holdfast run` はその対象を `clean` と示すことがあります。
  `clean` の行を信頼する前に、その証拠を読んでください。
- 競合は、一時停止点 `batch_load`、`outside_call`、`row_lock`、`first_write`、または指定したメソッドで試します。
  それ以外の割り込み方は試しません。
- 探索が到達するのは、下書きされたセットアップとサインインが働くアクションだけです。
  到達しなかった数は最初の行に出ます。

## 開発

```sh
bundle install
bundle install --gemfile test/fixture/clinic/Gemfile
DB_HOST=localhost DB_PORT=5432 ruby -Ilib test/run.rb
bundle exec rbs-inline --output=sig/generated lib
bundle exec steep check
```

`DB_HOST` がなければ、クリニックアプリを走らせるテストはスキップされます。
最後の 2 つのコマンドは、`lib/` の型コメントから `sig/generated/` に RBS シグネチャを書き出し、`lib/` をそれに照らして検査します。
詳しくは [AGENTS.md](AGENTS.md) にあります。

## ライセンス

MIT

---

[English](README.md)
