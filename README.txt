QR出退勤アプリ v1.1（fixed2 / paid-leave-app共存版）

【このZIPに入っているファイル】
・index.html
・manifest.webmanifest
・sw.js
・supabase-v1.sql
・supabase-v1.txt
・README.txt

【今回の修正内容】
・有給休暇アプリ側とテーブル名が衝突しないよう、出退勤側を qr_attendance_ 接頭辞へ統一
・Supabaseのpgcrypto関数を extensions.crypt / extensions.gen_salt で使用
・index.htmlのRPC呼び出しを、修正版SQLの関数名へすべて変更
・Service Workerのキャッシュ名を更新し、旧版が残りにくいよう変更

【すでにSupabase SQLで Success. No rows returned が出ている場合】
今回の supabase-v1.sql / supabase-v1.txt を再実行する必要はありません。
GitHubへ次の3ファイルを上書きしてください。
1. index.html
2. manifest.webmanifest
3. sw.js

【初回利用時】
1. GitHub Pagesでアプリを開く
2. 下部「設定」から、同じ paid-leave-app Supabase Project URL と anon public key を入力して保存
3. 下部「管理」から管理者ログイン
4. 初期管理者PIN：0000
5. 「従業員管理」から社員コード・氏名・従業員PINを登録
6. 「QR表示」で会社掲示用QRを表示
7. 従業員はQRを読み取り、社員コード＋PINで出勤/退勤を打刻

【重要】
・初期管理者PIN 0000 は実運用前に必ず変更してください。
・このv1.1のQRは共通固定QRです。QR画像を撮影して社外から使う対策はまだ入っていません。
・次版では、一定時間ごとに変わる動的QRや会社周辺のみ打刻できる仕組みを追加できます。
