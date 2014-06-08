VideoTranscoder for MovableType
==================

* Author:: Yuichi Takeuchi <info@takeyu-web.com>
* Website:: http://takeyu-web.com/
* Copyright:: Copyright 2014 Yuichi Takeuchi
* License:: MIT License

[Amazon Elastic Transcoder](http://aws.amazon.com/jp/elastictranscoder/)による動画変換機能を追加します。

AWSのコマンドラインツールではなくAPIを直接利用しており、比較的多くのサーバ上で利用頂けます。

インストールすると、アイテム一覧から「動画変換」できるようになります。

動画変換ジョブを登録すると、タスク（`run-periodic-tasks`）により、自動的に以下の操作が行われます。

1. 対象の動画ファイルをS3にアップロード
2. Elastic Transcoder Jobを登録
3. Jobの完了を定期的に監視
4. 完了したら変換後の動画ファイルをダウンロードしてアイテム登録


##TODO

- chunkによる分割アップロード／ダウンロード対応
- クライアントライブラリのテスト


##Contributing to VideoTranscoder

Fork, fix, then send me a pull request.


##Copyright

© 2014 Yuichi Takeuchi, released under the MIT license
