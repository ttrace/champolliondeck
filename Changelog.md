# Changelog

## 0.2.0

0.1.0 からの主なユーザー向け変更点:

- URLスキーム起動時に既存ウインドウを再利用するよう改善
  - 前回のターゲット言語や画面状態を保持しやすくなりました
- URL起動の重複実行抑制を改善
  - 同一 `text + target language + processing mode` の重複処理をスキップ
- 出力ステータス表示を段階化
  - `Ready` / `Preprocessing` / `Translating x/y` / `Completed` を表示
  - 翻訳中に停止ボタン（Stop）を利用可能
- Developer Mode の可観測性を強化
  - Deterministic / Heuristic Analysis を分離表示
  - 各処理時間の表示を追加
  - Console 表示を追加し、エラー詳細やヒューリスティック段階ログを確認可能
- セグメント処理を改善
  - 明示境界（空行・会話形式）ベースの分割
  - AIヒューリスティックによる前段/後段の再セグメント化
- Foundation Models 翻訳の安定性向上
  - ストリームの停止ガード（時間・回数・文字数）を追加
  - unsafe 検出時の再試行とセグメント単位フォールバックで完走性を改善

