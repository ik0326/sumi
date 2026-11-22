#!/usr/bin/env python3
"""Japanese UI strings. Writes Sumi/ja.lproj/Localizable.strings.  Run: python3 scripts/ja.py"""
import os

T = {
# AI
"Summarize": "要約", "Key Points": "要点", "Improve Writing": "文章を推敲", "Fix Spelling and Grammar": "誤字と文法を修正",
"Make Shorter": "短くする", "Continue Writing": "続きを書く", "Translate to English": "英語に翻訳",
"Translate to Japanese": "日本語に翻訳", "Suggest a Title": "タイトル案", "Suggest Tags": "タグ案",
"Ask About This Note…": "このノートについて質問…",
"This Mac does not support Apple Intelligence.": "この Mac は Apple Intelligence に対応していません。",
"Apple Intelligence is turned off. Turn it on in System Settings › Apple Intelligence & Siri.":
    "Apple Intelligence がオフになっています。システム設定 › Apple Intelligence と Siri でオンにしてください。",
"The Apple Intelligence model is still downloading. Try again later.": "Apple Intelligence のモデルをダウンロード中です。しばらくしてからもう一度試してください。",
"Apple Intelligence is not available right now.": "Apple Intelligence は現在使えません。",
"Apple Intelligence needs macOS 26 or later.": "Apple Intelligence には macOS 26 以降が必要です。",
"Selection": "選択範囲", "Whole note": "ノート全体", " (first part only)": "（先頭部分のみ）",
"Ask a question about this note": "このノートについて質問", "Ask": "質問", "Thinking…": "考え中…",
"On-device · Apple Intelligence": "この Mac 上で処理 · Apple Intelligence", "Close": "閉じる", "Try Again": "やり直す",
"Copy": "コピー", "Set as Title": "タイトルにする", "Add Tags": "タグを追加", "Insert Below": "下に挿入",
"Replace Selection": "選択範囲を置き換え", "Replace Note": "ノートを置き換え",
# Commands
"New Note": "新規ノート", "Quick Note": "クイックノート", "New Quick Note": "新規クイックノート", "New Quick Note (⌘N)": "新規クイックノート (⌘N)", "New Notebook": "新規ノートブック", "New Notebook…": "新規ノートブック…",
"Choose a Template": "テンプレートを選ぶ", "Choose a Template…": "テンプレートを選ぶ…",
"Toggle Preview": "プレビューを切り替え", "Toggle Side by Side": "左右分割を切り替え",
"Toggle Distraction Free": "集中モードを切り替え", "Toggle Sidebar": "サイドバーを切り替え",
"Search Notes": "ノートを検索", "Search All Notes": "すべてのノートを検索", "Go Back": "戻る", "Go Forward": "進む",
"Open Next Note": "次のノートを開く", "Open Previous Note": "前のノートを開く", "Focus Sidebar": "サイドバーへ移動",
"Focus Note List": "ノート一覧へ移動", "Focus Editor": "エディタへ移動", "Focus Title": "タイトルへ移動",
"Note Actions…": "ノートの操作…", "Table of Contents": "目次", "Table of Contents…": "目次…", "AI Actions…": "AI の操作…",
"Search Tags…": "タグを検索…", "Search Notebooks…": "ノートブックを検索…", "Clear Tag Filter": "タグの絞り込みを解除",
"Copy Note Link": "ノートのリンクをコピー", "Revision History…": "変更履歴…", "Export as HTML…": "HTML として書き出す…",
"Print / Save as PDF…": "プリント / PDF として保存…", "Highlight": "ハイライト", "Duplicate Note": "ノートを複製",
"Pin / Unpin Note": "ノートのピン留めを切り替え", "Move Note to Trash": "ノートをゴミ箱に入れる",
"Status: None": "ステータス: なし", "Status: Active": "ステータス: 進行中", "Status: On Hold": "ステータス: 保留",
"Status: Completed": "ステータス: 完了", "Status: Dropped": "ステータス: 中止", "Status: %@": "ステータス: %@",
"Bold": "太字", "Italic": "斜体", "Strikethrough": "取り消し線", "Inline Code": "インラインコード", "Insert Link": "リンクを挿入",
"Toggle Blockquote": "引用を切り替え", "Toggle Bulleted List": "箇条書きを切り替え", "Toggle Numbered List": "番号付きリストを切り替え",
"Toggle Task List": "タスクリストを切り替え", "Heading 1": "見出し 1", "Heading 2": "見出し 2", "Heading 3": "見出し 3",
"Insert Code Block": "コードブロックを挿入", "Insert Horizontal Rule": "区切り線を挿入", "Insert Table": "表を挿入",
"Insert Alert: Note": "アラートを挿入: Note", "Insert Alert: Tip": "アラートを挿入: Tip",
"Insert Alert: Important": "アラートを挿入: Important", "Insert Alert: Warning": "アラートを挿入: Warning",
"Insert Alert: Caution": "アラートを挿入: Caution",
"Table: Format": "表: 整形", "Table: Format All Tables": "表: すべての表を整形", "Table: Insert Row": "表: 行を挿入",
"Table: Insert Column": "表: 列を挿入", "Table: Delete Row": "表: 行を削除", "Table: Delete Column": "表: 列を削除",
"Table: Move Row Up": "表: 行を上へ", "Table: Move Row Down": "表: 行を下へ", "Table: Move Column Left": "表: 列を左へ",
"Table: Move Column Right": "表: 列を右へ", "Table: Align Column Left": "表: 列を左揃え",
"Table: Align Column Center": "表: 列を中央揃え", "Table: Align Column Right": "表: 列を右揃え",
"Table: Clear Column Alignment": "表: 列の揃えを解除", "Save": "保存",
# Menus
"Acknowledgements": "謝辞（ライセンス表示）", "Import Markdown…": "Markdown を読み込む…", "Export as Markdown…": "Markdown として書き出す…",
"Telescope": "Telescope", "Back": "戻る", "Forward": "進む", "Format": "フォーマット", "Link": "リンク", "Blockquote": "引用",
"Bulleted List": "箇条書き", "Numbered List": "番号付きリスト", "Task List": "タスクリスト", "Code Block": "コードブロック",
"Horizontal Rule": "区切り線", "Table": "表", "Insert Row": "行を挿入", "Insert Column": "列を挿入", "Delete Row": "行を削除",
"Delete Column": "列を削除", "Move Row Up": "行を上へ", "Move Row Down": "行を下へ", "Move Column Left": "列を左へ",
"Move Column Right": "列を右へ", "Align Left": "左揃え", "Align Center": "中央揃え", "Align Right": "右揃え",
"Clear Alignment": "揃えを解除", "Note": "ノート", "Pin / Unpin": "ピン留めを切り替え", "View": "表示",
# Keymap / recorder
"Cannot use key “%@”": "キー「%@」は使えません", "“%@” needs a command id": "「%@」にコマンド ID が必要です",
"keymap.json is not valid JSON": "keymap.json が正しい JSON ではありません",
"Press the keys…": "キーを押してください…",
"Click, then press the shortcut you want. Esc cancels.": "クリックしてから、使いたいショートカットを押します。Esc で取り消し。",
# Plugin API
"Adds a command. It appears in Telescope (⌘K, then >) and can be bound to a key in keymap.json.":
    "コマンドを追加します。Telescope（⌘K のあと >）に表示され、keymap.json でキーを割り当てられます。",
"Runs any command by its id.": "ID を指定してコマンドを実行します。",
"Replaces the selection, or inserts at the cursor.": "選択範囲を置き換えるか、カーソル位置に挿入します。",
"The note text / the selected text.": "ノートの本文 / 選択中のテキスト。",
"Adds CSS to the editor and the preview.": "エディタとプレビューに CSS を追加します。",
"fn(previewElement) runs after every preview render.": "プレビューが描画されるたびに fn(previewElement) が呼ばれます。",
"The markdown-it instance of the preview. sumi.md.use(plugin) adds Markdown syntax.":
    "プレビューの markdown-it インスタンス。sumi.md.use(plugin) で Markdown 記法を追加できます。",
"The CodeMirror 6 EditorView, for advanced editor changes.": "CodeMirror 6 の EditorView。エディタを高度に変更するときに使います。",
# Editor pane
"No Note Selected": "ノートが選択されていません", "Press ⌘N to create a note.": "⌘N でノートを作成します。",
"Back (⌘←)": "戻る (⌘←)", "Forward (⌘→)": "進む (⌘→)", "Editor": "エディタ", "Side by Side (⌘P)": "左右分割 (⌘P)",
"Preview (⌘E)": "プレビュー (⌘E)", "Distraction Free (⌘⇧D)": "集中モード (⌘⇧D)", "Note Actions (⌘J)": "ノートの操作 (⌘J)",
"Linked from": "リンク元", "This note is in the Trash.": "このノートはゴミ箱にあります。", "Restore": "元に戻す",
"Untitled": "無題", "No Notebook": "ノートブックなし", "Status": "ステータス", " copy": " のコピー",
# Models
"None": "なし", "Active": "進行中", "On Hold": "保留", "Completed": "完了", "Dropped": "中止",
"Date Updated": "更新日", "Date Created": "作成日", "Title": "タイトル",
# Note list
"All Notes": "すべてのノート", "Notebook": "ノートブック", "Trash": "ゴミ箱", "Search": "検索",
"Remove from filter": "絞り込みから外す", "No Notes": "ノートがありません", "No Results": "見つかりません",
"%lld notes selected": "%lld 件のノートを選択中", "Move to Trash (⌘⌫)": "ゴミ箱に入れる (⌘⌫)", "Sort By": "並び順",
"Show Completed and Dropped": "完了・中止したノートを表示", "Sort": "並べ替え", "Empty Trash": "ゴミ箱を空にする",
"New Note (⌘N)": "新規ノート (⌘N)", "Filter by this tag (⌥-click: only this tag)": "このタグで絞り込む（⌥クリック: このタグだけ）",
"Delete Permanently": "完全に削除", "%lld notes": "%lld 件のノート", "Unpin": "ピン留めを外す", "Pin to Top": "一番上にピン留め",
"Move to Notebook": "ノートブックへ移動", "Move to Notebook…": "ノートブックへ移動…", "Tags": "タグ", "No Tags": "タグがありません",
"Duplicate": "複製", "Copy Links": "リンクをコピー", "Copy Link": "リンクをコピー", "Move to Trash": "ゴミ箱に入れる",
# Revisions
"%lld chars": "%lld 文字", "No Revisions Yet": "履歴はまだありません", "Select a Revision": "履歴を選んでください",
"A copy is kept each time you start editing a note.": "ノートの編集を始めるたびに、その時点の内容が保存されます。",
"Restore This Version": "この版に戻す",
# Settings
"Default": "標準", "General": "一般", "Appearance": "外観", "Keys": "キー", "Plugins": "プラグイン",
"Language": "言語", "Match System": "システムに合わせる",
"The language changes the next time Sumi starts.": "言語は、次に Sumi を起動したときに切り替わります。", "Relaunch Now": "今すぐ再起動",
"iCloud Drive is not available": "iCloud Drive が使えません", "OK": "OK",
"Turn on iCloud Drive in System Settings › Apple Account › iCloud, then try again.":
    "システム設定 › Apple アカウント › iCloud で iCloud Drive をオンにしてから、もう一度試してください。",
"Sync": "同期", "Sync with iCloud Drive": "iCloud Drive で同期",
"Notes are stored in iCloud Drive › Sumi and shared with your other Macs.": "ノートは iCloud Drive › Sumi に保存され、ほかの Mac と共有されます。",
"Notes are stored on this Mac only.": "ノートはこの Mac にだけ保存されます。",
"Shortcut": "ショートカット", "Reset": "リセット",
"Click the button, then press the keys you want (with ⌘, ⌃ or ⌥). Esc cancels.":
    "ボタンをクリックしてから、使いたいキーを押します（⌘、⌃、⌥ のいずれかと組み合わせ）。Esc で取り消し。",
"Use this shortcut from any app (global hotkey)": "ほかのアプリを使っているときもこのショートカットを使う",
"Notes": "ノート", "Show completed and dropped notes in lists": "完了・中止したノートを一覧に表示",
"Font size: %lld pt": "文字サイズ: %lld pt", "Show line numbers": "行番号を表示", "Wrap long lines": "長い行を折り返す",
"Limit line length to a readable width": "1 行の長さを読みやすい幅に抑える",
"Show formatting toolbar when text is selected": "文字を選択したときに書式ツールバーを表示",
"Vim": "Vim", "Enable Vim keybindings": "Vim キーバインドを使う",
"Switch to ASCII input when returning to normal mode": "ノーマルモードに戻ったら英数入力に切り替える",
"Use system clipboard for yank and paste": "ヤンクとペーストにシステムのクリップボードを使う",
"Theme": "テーマ", "App appearance": "アプリの外観", "Light": "ライト", "Dark": "ダーク",
"Editor and preview theme": "エディタとプレビューのテーマ",
"Each theme has a light and a dark variant that follows the app appearance. For Solarized Dark, choose Solarized and set the app appearance to Dark.":
    "どのテーマにもライトとダークがあり、アプリの外観に合わせて切り替わります。Solarized Dark にするには、テーマで Solarized を選び、アプリの外観を「ダーク」にします。",
"Custom CSS": "カスタム CSS", "Not used": "未使用", "Loaded": "読み込み済み", "Open": "開く",
"Your own CSS for the editor and the preview. Changes apply when you come back to Sumi.":
    "エディタとプレビューに適用する独自の CSS です。変更は Sumi に戻ったときに反映されます。",
"Keymap": "キーマップ", "%lld custom bindings": "%lld 件の独自の割り当て", "Copy All Command IDs": "すべてのコマンド ID をコピー",
"Vim mappings (map, nmap, imap…) are set in vimrc on the Editor tab.": "Vim のマッピング（map、nmap、imap…）は「エディタ」タブの vimrc で設定します。",
"Plugins folder": "プラグインのフォルダ", "Open Folder": "フォルダを開く", "Reload": "再読み込み",
"A plugin is a JavaScript file (.js) in this folder. It is loaded into the editor when Sumi starts, when you press Reload, or when you come back to Sumi. Plugins can do anything the editor can, so only add code you trust.":
    "プラグインは、このフォルダに置いた JavaScript ファイル（.js）です。Sumi の起動時、「再読み込み」を押したとき、Sumi に戻ったときにエディタへ読み込まれます。プラグインはエディタにできることを何でも実行できるので、信頼できるコードだけを入れてください。",
"Installed": "インストール済み", "No plugins installed": "プラグインはありません", "Writing a plugin": "プラグインの書き方",
"Each plugin receives one object named sumi:": "プラグインは sumi という名前のオブジェクトを 1 つ受け取ります:",
"Example": "例",
"example.js is installed. Try “Example: Insert Today’s Date” in Telescope (⌘K, then >).":
    "example.js を追加しました。Telescope（⌘K のあと >）で「Example: Insert Today’s Date」を試してください。",
"Adds this code to the plugins folder as example.js.": "このコードを example.js としてプラグインのフォルダに追加します。",
"Add Example Plugin": "例のプラグインを追加", "Apple Intelligence": "Apple Intelligence",
"Available on this Mac": "この Mac で使えます",
"Suggest the next words while typing (Tab to accept)": "入力中に続きを提案する（Tab で確定）",
'''Map keys to command ids, for example  { "cmd-shift-j": "core:telescope-tags", "cmd-e": "none" }
Modifiers: cmd, ctrl, alt, shift. Keys: letters, digits, enter, tab, space, escape, backspace, left/right/up/down, f1–f12.
Use "none" to turn a default shortcut off. Command ids are listed in Telescope (⌘K, then >).
Changes apply when you come back to Sumi. Menus keep showing the default shortcuts.''':
'''キーをコマンド ID に割り当てます。例:  { "cmd-shift-j": "core:telescope-tags", "cmd-e": "none" }
修飾キー: cmd, ctrl, alt, shift。キー: 英字, 数字, enter, tab, space, escape, backspace, left/right/up/down, f1–f12。
"none" を指定すると既定のショートカットを無効にできます。コマンド ID は Telescope（⌘K のあと >）で確認できます。
変更は Sumi に戻ったときに反映されます。メニューには既定のショートカットが表示されたままになります。''',
'''AI actions run on this Mac with Apple Intelligence; note text is not sent to a server by Sumi.
Open them with ⌘⇧A, the AI menu, or the AI button in the selection toolbar. They work on the selected text, or on the whole note.
The on-device model reads about the first %d characters of long text.''':
'''AI の操作は Apple Intelligence を使ってこの Mac 上で実行されます。Sumi がノートの内容をサーバーに送ることはありません。
⌘⇧A、AI メニュー、または選択ツールバーの AI ボタンから開きます。選択範囲があればそこだけ、なければノート全体が対象です。
長い文章では、先頭の約 %d 文字までを読みます。''',
# Sidebar
"Rename Notebook": "ノートブックの名前を変更", "Show all notebooks": "すべてのノートブックを表示", "Notebooks": "ノートブック",
"Sub-notebooks": "サブノートブック", "Add to Filter": "絞り込みに追加", "Tag Settings…": "タグの設定…", "Tag Settings": "タグの設定",
"Color": "色", "Copy Tag ID": "タグ ID をコピー", "Delete Tag": "タグを削除", "Synced %@": "%@ に同期",
"Name": "名前", "Cancel": "キャンセル", "Delete “%@”?": "「%@」を削除しますか？", "Delete Notebook": "ノートブックを削除",
"Its sub-notebooks are deleted and all notes inside are moved to the Trash.": "サブノートブックも削除され、中のノートはすべてゴミ箱に移動します。",
"Detail": "詳細", "Move to Top Level": "最上位に移動", "New Sub-notebook…": "新規サブノートブック…", "Rename…": "名前を変更…",
"Delete…": "削除…",
# Files
"Open File…": "ファイルを開く…", "Markdown File": "Markdown ファイル", "Show in Finder": "Finder に表示",
"This file could not be opened": "このファイルは開けませんでした",
"Sumi opens text files saved as UTF-8.": "Sumi で開けるのは、UTF-8 で保存されたテキストファイルです。",
# Updates
"A new version is available": "最新のバージョンがあります", "Version %@ — click to update": "バージョン %@ — クリックでアップデート",
"Check for Updates…": "アップデートを確認…",
"Updates": "アップデート", "Check for updates automatically": "アップデートを自動で確認", "Version %@": "バージョン %@",
"Check Now": "今すぐ確認",
"Sumi asks GitHub once a day whether a newer release exists. Nothing about you or your notes is sent. Updates are accepted only when they carry the developer's signature.":
    "1 日に 1 回、新しいリリースがあるかを GitHub に問い合わせます。あなたやノートに関する情報は送りません。開発者の署名が付いたアップデートだけを受け付けます。",
# Tag bar
"Create “%@”": "「%@」を作成", "Remove tag": "タグを外す", "Show Notes with This Tag": "このタグのノートを表示",
"Remove from Note": "ノートから外す",
# Telescope
"Search notes…   ( > commands   b notebooks   t tags   # headings )": "ノートを検索…   ( > コマンド   b ノートブック   t タグ   # 見出し )",
"Run a command…": "コマンドを実行…", "Go to notebook…   ( ⌘↩ open as workspace )": "ノートブックへ移動…   ( ⌘↩ ワークスペースとして開く )",
"Go to tag…   ( ⌘↩ add to filter   ⇧↩ tag this note )": "タグへ移動…   ( ⌘↩ 絞り込みに追加   ⇧↩ このノートに付ける )",
"Note actions…": "ノートの操作…", "Choose a template…": "テンプレートを選ぶ…", "Move to notebook…": "ノートブックへ移動…",
"Jump to heading…": "見出しへ移動…", "AI actions…   ( works on the selection, or the whole note )": "AI の操作…   ( 選択範囲、なければノート全体が対象 )",
}

def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = "/* Generated by scripts/ja.py — edit that file. */\n\n" + "".join(f'"{esc(k)}" = "{esc(v)}";\n' for k, v in T.items())
    open(os.path.join(root, "Sumi/ja.lproj/Localizable.strings"), "w").write(out)
    open(os.path.join(root, "Sumi/en.lproj/Localizable.strings"), "w").write('/* English is the source language. */\n"OK" = "OK";\n')
    print(len(T), "strings")
