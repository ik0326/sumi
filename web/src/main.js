import { EditorView, keymap, drawSelection, highlightActiveLine, lineNumbers, showTooltip, Decoration, WidgetType } from '@codemirror/view'
import { EditorState, EditorSelection, Compartment, Prec, StateField, StateEffect } from '@codemirror/state'
import { defaultKeymap, history, historyKeymap, indentMore, indentLess, selectLine } from '@codemirror/commands'
import { markdown, markdownLanguage } from '@codemirror/lang-markdown'
import { languages } from '@codemirror/language-data'
import { syntaxHighlighting, HighlightStyle, indentUnit, bracketMatching } from '@codemirror/language'
import { autocompletion, acceptCompletion } from '@codemirror/autocomplete'
import { tags as t, classHighlighter } from '@lezer/highlight'
import { searchKeymap, highlightSelectionMatches } from '@codemirror/search'
import { vim, Vim, getCM } from '@replit/codemirror-vim'
import MarkdownIt from 'markdown-it'
import taskLists from 'markdown-it-task-lists'
import footnote from 'markdown-it-footnote'
import hljs from 'highlight.js'
import katex from 'katex'
import texmath from 'markdown-it-texmath'
import DOMPurify from 'dompurify'
import { full as emojiPlugin } from 'markdown-it-emoji'
import emojiDefs from 'markdown-it-emoji/lib/data/full.mjs'
import 'katex/dist/katex.min.css'
import './themes.css'
import './style.css'
import { hclDescription, hclHighlight } from './hcl.js'

hljs.registerLanguage('hcl', hclHighlight)
const codeLanguages = [...languages, hclDescription]

const post = (m) => {
  try { window.webkit.messageHandlers.sumi.postMessage(m) } catch (e) { /* not in app */ }
}

// ---------- Markdown preview ----------
const md = new MarkdownIt({
  html: true,
  linkify: true,
  breaks: true,
  highlight(str, lang) {
    if (lang && hljs.getLanguage(lang)) {
      try { return hljs.highlight(str, { language: lang, ignoreIllegals: true }).value } catch (e) {}
    }
    return ''
  },
}).use(taskLists, { enabled: true }).use(footnote)
  .use(emojiPlugin, { shortcuts: {} })
  .use(texmath, { engine: katex, delimiters: 'dollars', katexOptions: { throwOnError: false } })

// Image size specifiers in the alt text: ![width:200px](…), ![w:320 h:240](…), ![width:50%](…)
const SIZE_RE = /\b(width|height|w|h):(\d+(?:\.\d+)?)(px|pt|pc|in|cm|mm|em|ex|ch|%)?/g
const defaultImage = md.renderer.rules.image
md.renderer.rules.image = (tokens, idx, options, env, self) => {
  const token = tokens[idx]
  const styles = new Set()
  const strip = (text) => text.replace(SIZE_RE, (_m, k, n, unit) => {
    styles.add(`${k[0] === 'w' ? 'width' : 'height'}:${n}${unit || 'px'}`)
    return ''
  }).trim()
  token.content = strip(token.content)
  for (const child of token.children || []) if (child.type === 'text') child.content = strip(child.content)
  if (styles.size) token.attrSet('style', [...styles].join(';'))
  return defaultImage(tokens, idx, options, env, self)
}

const $ = (id) => document.getElementById(id)
const root = $('root')
const previewEl = $('preview')
const elMode = $('vim-mode')
const elPos = $('pos')
const elCount = $('count')

// ---------- State ----------
let opts = { vim: false, lineNumbers: false, lineWrap: true, fontSize: 14, vimrc: '', clipboard: true, toolbar: true, readable: false }
let current = null // { id, readOnly }
let mode = 'edit'
let vimState = 'normal'
let changeTimer = null
let previewTimer = null
const stateCache = new Map()

const vimC = new Compartment()
const numC = new Compartment()
const wrapC = new Compartment()
const tbC = new Compartment()

const inInsert = () => !opts.vim || vimState === 'insert' || vimState === 'replace'

const mdStyle = HighlightStyle.define([
  { tag: t.heading1, class: 'tok-h tok-h1' },
  { tag: t.heading2, class: 'tok-h tok-h2' },
  { tag: [t.heading3, t.heading4, t.heading5, t.heading6], class: 'tok-h' },
  { tag: t.monospace, class: 'tok-mono' },
  { tag: t.quote, class: 'tok-quote' },
  { tag: t.strikethrough, class: 'tok-strike' },
  { tag: t.processingInstruction, class: 'tok-mark' },
  { tag: t.contentSeparator, class: 'tok-mark' },
  { tag: t.list, class: 'tok-list' },
])

// ---------- Tables ----------
const WIDE = /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]/
function dispWidth(s) {
  let w = 0
  for (const ch of s) w += ch.length > 1 || WIDE.test(ch) ? 2 : 1
  return w
}

const isTableLine = (s) => /^\s*\|/.test(s)

function splitRow(text) {
  let s = text.trim()
  if (s.startsWith('|')) s = s.slice(1)
  if (s.endsWith('|') && !s.endsWith('\\|')) s = s.slice(0, -1)
  const cells = []
  let cur = ''
  let code = false
  for (let i = 0; i < s.length; i++) {
    const ch = s[i]
    if (ch === '\\' && s[i + 1] === '|') { cur += '\\|'; i++; continue }
    if (ch === '`') code = !code
    if (ch === '|' && !code) { cells.push(cur.trim()); cur = '' } else cur += ch
  }
  cells.push(cur.trim())
  return cells
}

function findTable(state, pos) {
  const doc = state.doc
  const ln = doc.lineAt(pos)
  if (!isTableLine(ln.text)) return null
  let a = ln.number
  let b = ln.number
  while (a > 1 && isTableLine(doc.line(a - 1).text)) a--
  while (b < doc.lines && isTableLine(doc.line(b + 1).text)) b++
  const rows = []
  for (let i = a; i <= b; i++) rows.push(splitRow(doc.line(i).text))
  const hasDelim = rows.length > 1 && rows[1].every((c) => /^:?-*:?$/.test(c)) && rows[1].some((c) => c.includes('-'))
  const aligns = hasDelim
    ? rows[1].map((c) => (c.startsWith(':') && c.endsWith(':') ? 'c' : c.endsWith(':') ? 'r' : c.startsWith(':') ? 'l' : ''))
    : []
  const r = ln.number - a
  const before = ln.text.slice(0, pos - ln.from)
  let pipes = 0
  let code = false
  for (let i = 0; i < before.length; i++) {
    if (before[i] === '\\') { i++; continue }
    if (before[i] === '`') code = !code
    if (before[i] === '|' && !code) pipes++
  }
  return {
    from: doc.line(a).from,
    to: doc.line(b).to,
    indent: doc.line(a).text.match(/^\s*/)[0],
    head: rows[0],
    aligns,
    body: rows.slice(hasDelim ? 2 : 1),
    lr: hasDelim ? (r <= 1 ? 0 : r - 1) : r,
    c: Math.max(0, pipes - 1),
  }
}

function renderTable(indent, head, aligns, body) {
  const n = head.length
  const w = []
  for (let c = 0; c < n; c++) w[c] = Math.max(3, dispWidth(head[c]), ...body.map((r) => dispWidth(r[c])))
  const end = []
  let text = ''
  const line = (cells, lr) => {
    let s = indent + '|'
    const ends = []
    cells.forEach((cell, c) => {
      const gap = w[c] - dispWidth(cell)
      let l = 0
      let r = gap
      if (aligns[c] === 'r') { l = gap; r = 0 } else if (aligns[c] === 'c') { l = gap >> 1; r = gap - l }
      s += ' ' + ' '.repeat(l) + cell
      ends.push(text.length + s.length)
      s += ' '.repeat(r) + ' |'
    })
    end[lr] = ends
    text += s
  }
  line(head, 0)
  text += '\n' + indent + '|' + aligns.map((a, c) =>
    ' ' + (a === 'l' || a === 'c' ? ':' : '-') + '-'.repeat(w[c] - 2) + (a === 'r' || a === 'c' ? ':' : '-') + ' |').join('')
  body.forEach((r, i) => { text += '\n'; line(r, i + 1) })
  return { text, end }
}

const swap = (arr, i, j) => { const x = arr[i]; arr[i] = arr[j]; arr[j] = x }

function tableOp(op) {
  const st = view.state
  if (st.readOnly) return false
  const tb = findTable(st, st.selection.main.head)
  if (!tb) return false
  const { head, aligns, body } = tb
  let { lr, c } = tb
  const n = Math.max(1, head.length, ...body.map((r) => r.length))
  const pad = (r) => { while (r.length < n) r.push(''); return r }
  pad(head); body.forEach(pad); pad(aligns)
  aligns.length = n
  c = Math.min(c, n - 1)
  const rows = [head, ...body]
  const blank = () => Array(n).fill('')
  let exit = false
  switch (op) {
    case 'next-cell':
      c++
      if (c >= n) { c = 0; lr++; if (lr >= rows.length) body.push(blank()) }
      break
    case 'previous-cell':
      c--
      if (c < 0) { if (lr === 0) c = 0; else { lr--; c = n - 1 } }
      break
    case 'next-row':
      if (lr > 0 && rows[lr].every((x) => x === '')) { body.splice(lr - 1, 1); exit = true }
      else { body.splice(lr, 0, blank()); lr++; c = 0 }
      break
    case 'insert-row': body.splice(lr, 0, blank()); lr++; break
    case 'delete-row': if (lr > 0) { body.splice(lr - 1, 1); lr = Math.min(lr, body.length) } break
    case 'move-row-up': if (lr > 1) { swap(body, lr - 1, lr - 2); lr-- } break
    case 'move-row-down': if (lr > 0 && lr < body.length) { swap(body, lr - 1, lr); lr++ } break
    case 'insert-column': rows.forEach((r) => r.splice(c + 1, 0, '')); aligns.splice(c + 1, 0, ''); c++; break
    case 'delete-column':
      if (n > 1) { rows.forEach((r) => r.splice(c, 1)); aligns.splice(c, 1); c = Math.min(c, n - 2) }
      break
    case 'move-column-left': if (c > 0) { rows.forEach((r) => swap(r, c, c - 1)); swap(aligns, c, c - 1); c-- } break
    case 'move-column-right': if (c < n - 1) { rows.forEach((r) => swap(r, c, c + 1)); swap(aligns, c, c + 1); c++ } break
    case 'align-left': aligns[c] = 'l'; break
    case 'align-right': aligns[c] = 'r'; break
    case 'align-center': aligns[c] = 'c'; break
    case 'align-none': aligns[c] = ''; break
    case 'format': break
    default: return false
  }
  const out = renderTable(tb.indent, head, aligns, body)
  let insert = out.text
  let anchor
  if (exit) { insert += '\n'; anchor = tb.from + insert.length } else anchor = tb.from + out.end[lr][c]
  view.dispatch({ changes: { from: tb.from, to: tb.to, insert }, selection: { anchor }, scrollIntoView: true, userEvent: 'input' })
  return true
}

function formatAllTables() {
  const doc = view.state.doc
  const changes = []
  for (let i = 1; i <= doc.lines; i++) {
    if (!isTableLine(doc.line(i).text)) continue
    const tb = findTable(view.state, doc.line(i).from)
    const n = Math.max(1, tb.head.length, ...tb.body.map((r) => r.length))
    const pad = (r) => { while (r.length < n) r.push(''); return r }
    pad(tb.head); tb.body.forEach(pad); pad(tb.aligns); tb.aligns.length = n
    changes.push({ from: tb.from, to: tb.to, insert: renderTable(tb.indent, tb.head, tb.aligns, tb.body).text })
    i = doc.lineAt(tb.to).number
  }
  if (changes.length) view.dispatch({ changes, userEvent: 'input' })
}

// ---------- Formatting commands ----------
function toggleWrap(open, close = open) {
  const st = view.state
  const A = open.length
  const B = close.length
  view.dispatch(st.update(st.changeByRange((range) => {
    const text = st.sliceDoc(range.from, range.to)
    if (text.length >= A + B && text.startsWith(open) && text.endsWith(close)) {
      return {
        changes: { from: range.from, to: range.to, insert: text.slice(A, text.length - B) },
        range: EditorSelection.range(range.from, range.to - A - B),
      }
    }
    if (range.from >= A && st.sliceDoc(range.from - A, range.from) === open && st.sliceDoc(range.to, range.to + B) === close) {
      return {
        changes: [{ from: range.from - A, to: range.from }, { from: range.to, to: range.to + B }],
        range: EditorSelection.range(range.from - A, range.to - A),
      }
    }
    return {
      changes: [{ from: range.from, insert: open }, { from: range.to, insert: close }],
      range: EditorSelection.range(range.from + A, range.to + A),
    }
  }), { userEvent: 'input' }))
}

const LIST_ANY = /^(\s*)(?:[-*+] \[[ xX]\] |[-*+] |\d+[.)] )/
const LINE_KIND = {
  quote: { re: /^(\s*)> ?/, prefix: () => '> ' },
  bullet: { re: /^(\s*)[-*+] (?!\[[ xX]\] )/, prefix: () => '- ' },
  number: { re: /^(\s*)\d+[.)] /, prefix: (i) => `${i + 1}. ` },
  task: { re: /^(\s*)[-*+] \[[ xX]\] /, prefix: () => '- [ ] ' },
}

function selectedLines() {
  const st = view.state
  const { from, to } = st.selection.main
  const a = st.doc.lineAt(from).number
  const b = st.doc.lineAt(to).number
  const lines = []
  for (let i = a; i <= b; i++) lines.push(st.doc.line(i))
  return lines
}

function toggleLines(kind) {
  const { re, prefix } = LINE_KIND[kind]
  const lines = selectedLines()
  const all = lines.every((l) => re.test(l.text))
  const changes = []
  lines.forEach((l, i) => {
    const m = l.text.match(re)
    if (all) { changes.push({ from: l.from + m[1].length, to: l.from + m[0].length }); return }
    if (m) return
    const other = kind === 'quote' ? null : l.text.match(LIST_ANY)
    const indent = l.text.match(/^\s*/)[0].length
    if (other) changes.push({ from: l.from + other[1].length, to: l.from + other[0].length, insert: prefix(i) })
    else changes.push({ from: l.from + indent, insert: prefix(i) })
  })
  view.dispatch({ changes, userEvent: 'input' })
}

function toggleHeading(n) {
  const changes = selectedLines().map((l) => {
    const m = l.text.match(/^(#{1,6}) +/)
    const want = '#'.repeat(n) + ' '
    if (m && m[1].length === n) return { from: l.from, to: l.from + m[0].length }
    return { from: l.from, to: l.from + (m ? m[0].length : 0), insert: want }
  })
  view.dispatch({ changes, userEvent: 'input' })
}

function insertLink() {
  const st = view.state
  const r = st.selection.main
  const text = st.sliceDoc(r.from, r.to)
  const insert = `[${text}](url)`
  const urlAt = r.from + text.length + 3
  view.dispatch({
    changes: { from: r.from, to: r.to, insert },
    selection: text ? EditorSelection.range(urlAt, urlAt + 3) : { anchor: r.from + 1 },
    userEvent: 'input',
  })
}

/** Inserts a block on its own line(s); `cursor` is an offset into `text`. */
function insertBlock(text, cursor) {
  const st = view.state
  const line = st.doc.lineAt(st.selection.main.head)
  const empty = line.text.trim() === ''
  const from = empty ? line.from : line.to
  const pre = empty ? '' : '\n'
  view.dispatch({
    changes: { from, to: line.to, insert: pre + text },
    selection: { anchor: from + pre.length + (cursor ?? text.length) },
    scrollIntoView: true,
    userEvent: 'input',
  })
}

const NEW_TABLE = '|     |     |     |\n| --- | --- | --- |\n|     |     |     |'
const pad2 = (n) => String(n).padStart(2, '0')
const today = () => { const d = new Date(); return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}` }
const nowTime = () => { const d = new Date(); return `${pad2(d.getHours())}:${pad2(d.getMinutes())}` }

function insertLineBefore() {
  const st = view.state
  const line = st.doc.lineAt(st.selection.main.head)
  const indent = line.text.match(/^\s*/)[0]
  view.dispatch({ changes: { from: line.from, insert: indent + '\n' }, selection: { anchor: line.from + indent.length }, userEvent: 'input' })
  return true
}

function joinLines() {
  const st = view.state
  const line = st.doc.lineAt(st.selection.main.head)
  if (line.number >= st.doc.lines) return true
  const next = st.doc.line(line.number + 1)
  const lead = next.text.match(/^\s*/)[0].length
  view.dispatch({ changes: { from: line.to, to: next.from + lead, insert: ' ' }, selection: { anchor: line.to }, userEvent: 'input' })
  return true
}

const alertBlock = (kind) => () => insertBlock(`> [!${kind}]\n> `)

const commands = {
  'core:strong': () => toggleWrap('**'),
  'core:emphasize': () => toggleWrap('*'),
  'core:strikethrough': () => toggleWrap('~~'),
  'core:toggle-inline-code': () => toggleWrap('`'),
  'core:toggle-inline-mark-tag': () => toggleWrap('<mark>', '</mark>'),
  'core:toggle-heading-1': () => toggleHeading(1),
  'core:toggle-heading-2': () => toggleHeading(2),
  'core:toggle-heading-3': () => toggleHeading(3),
  'core:toggle-heading-4': () => toggleHeading(4),
  'core:toggle-blockquote': () => toggleLines('quote'),
  'core:toggle-bulleted-list': () => toggleLines('bullet'),
  'core:toggle-numbered-list': () => toggleLines('number'),
  'core:toggle-task-list': () => toggleLines('task'),
  'core:insert-link': insertLink,
  'core:insert-code-block': () => insertBlock('```\n\n```', 3),
  'core:insert-horizontal-rule': () => insertBlock('* * *\n'),
  'core:insert-table': () => insertBlock(NEW_TABLE, 2),
  'core:insert-alert-note': alertBlock('NOTE'),
  'core:insert-alert-tip': alertBlock('TIP'),
  'core:insert-alert-important': alertBlock('IMPORTANT'),
  'core:insert-alert-warning': alertBlock('WARNING'),
  'core:insert-alert-caution': alertBlock('CAUTION'),
  'editor:join-lines': joinLines,
  'editor:insert-line-before': insertLineBefore,
  'editor:select-line': () => selectLine(view),
  'table-editor:format-all': formatAllTables,
}
for (const op of ['next-cell', 'previous-cell', 'next-row', 'insert-row', 'delete-row', 'move-row-up', 'move-row-down',
  'insert-column', 'delete-column', 'move-column-left', 'move-column-right',
  'align-left', 'align-right', 'align-center', 'align-none', 'format']) {
  commands['table-editor:' + op] = () => tableOp(op)
}

/** Runs an editor command here, or hands it to the app. */
const pluginCommands = {}
function runCommand(id) {
  if (pluginCommands[id]) {
    try { pluginCommands[id].run() } catch (e) { console.error(e) }
  } else if (commands[id]) {
    if (current && !current.readOnly) commands[id]()
  } else {
    flushChange()
    post({ type: 'command', id })
  }
}

// ---------- Slash commands ----------
const SLASH = [
  ['Heading 1', 'H1', (v, f, to) => put(v, f, to, '# ')],
  ['Heading 2', 'H2', (v, f, to) => put(v, f, to, '## ')],
  ['Heading 3', 'H3', (v, f, to) => put(v, f, to, '### ')],
  ['Bulleted list', '-', (v, f, to) => put(v, f, to, '- ')],
  ['Numbered list', '1.', (v, f, to) => put(v, f, to, '1. ')],
  ['Task list', '[ ]', (v, f, to) => put(v, f, to, '- [ ] ')],
  ['Blockquote', '>', (v, f, to) => put(v, f, to, '> ')],
  ['Code block', '```', (v, f, to) => put(v, f, to, '```\n\n```', 3)],
  ['Table', '|', (v, f, to) => put(v, f, to, NEW_TABLE, 2)],
  ['Horizontal rule', '---', (v, f, to) => put(v, f, to, '* * *\n')],
  ['Link', '[]', (v, f, to) => put(v, f, to, '[](url)', 1)],
  ['Image', '![]', (v, f, to) => put(v, f, to, '![](url)', 2)],
  ['Details', '<details>', (v, f, to) => put(v, f, to, '<details>\n<summary></summary>\n\n\n\n</details>', 19)],
  ['Note alert', '!', (v, f, to) => put(v, f, to, '> [!NOTE]\n> ')],
  ['Tip alert', '!', (v, f, to) => put(v, f, to, '> [!TIP]\n> ')],
  ['Important alert', '!', (v, f, to) => put(v, f, to, '> [!IMPORTANT]\n> ')],
  ['Warning alert', '!', (v, f, to) => put(v, f, to, '> [!WARNING]\n> ')],
  ['Caution alert', '!', (v, f, to) => put(v, f, to, '> [!CAUTION]\n> ')],
  ['Date', 'date', (v, f, to) => put(v, f, to, today())],
  ['Time', 'time', (v, f, to) => put(v, f, to, nowTime())],
]

function put(v, from, to, text, cursor) {
  v.dispatch({ changes: { from, to, insert: text }, selection: { anchor: from + (cursor ?? text.length) }, userEvent: 'input' })
}

function slashSource(ctx) {
  const line = ctx.state.doc.lineAt(ctx.pos)
  const before = line.text.slice(0, ctx.pos - line.from)
  const m = before.match(/^(\s*)\/([\w ]*)$/)
  if (!m) return null
  return {
    from: line.from + m[1].length,
    validFor: /^\/[\w ]*$/,
    options: SLASH.map(([name, detail, apply], i) => ({
      label: '/' + name.toLowerCase(),
      displayLabel: name,
      detail,
      boost: -i,
      apply: (v, _c, from, to) => apply(v, from, to),
    })),
  }
}

// ---------- [[ note links ----------
const pendingNotes = new Map()
let noteReq = 0
const escTitle = (s) => s.replace(/[\[\]]/g, '\\$&')
const noteLink = (n) => `[${escTitle(n.title)}](sumi://note/${n.id})`

function linkSource(ctx) {
  const line = ctx.state.doc.lineAt(ctx.pos)
  const before = line.text.slice(0, ctx.pos - line.from)
  const m = before.match(/\[\[([^\]\n]*)$/)
  if (!m || !current) return null
  const from = ctx.pos - m[0].length
  const q = m[1]
  return new Promise((resolve) => {
    const req = ++noteReq
    pendingNotes.set(req, (items) => {
      const cut = (v, to) => {
        const end = v.state.sliceDoc(to, to + 2) === ']]' ? to + 2 : to
        return end
      }
      const options = items.map((n, i) => ({
        label: n.title,
        detail: n.book,
        boost: -i,
        apply: (v, _c, f, to) => put(v, from, cut(v, to), noteLink(n)),
      }))
      if (q.trim()) {
        options.push({
          label: T('Create new note') + ` “${q.trim()}”`,
          boost: -999,
          apply: (v, _c, f, to) => {
            put(v, from, cut(v, to), '')
            post({ type: 'createLinked', title: q.trim() })
          },
        })
      }
      resolve({ from, to: ctx.pos, options, filter: false })
    })
    post({ type: 'notes', req, q, exclude: current.id })
    setTimeout(() => { if (pendingNotes.delete(req)) resolve(null) }, 1500)
  })
}

// ``` language names
const LANGS = [...new Set(codeLanguages.flatMap((l) => [l.name.toLowerCase().replace(/\s+/g, ''), ...(l.alias || [])]))]
  .concat(['math', 'mermaid']).sort()
function langSource(ctx) {
  const line = ctx.state.doc.lineAt(ctx.pos)
  const before = line.text.slice(0, ctx.pos - line.from)
  const m = before.match(/^\s*(?:```|~~~)([\w+#-]*)$/)
  if (!m) return null
  return { from: ctx.pos - m[1].length, validFor: /^[\w+#-]*$/, options: LANGS.map((label) => ({ label })) }
}

// ---------- Tab key ----------
/**
 * Tab accepts an open completion, indents selected lines and list items,
 * and otherwise inserts spaces up to the next tab stop at the cursor.
 */
function tabKey(view) {
  if (acceptCompletion(view)) return true
  const { state } = view
  const listLine = (r) => /^\s*([-*+]|\d+[.)])\s/.test(state.doc.lineAt(r.head).text)
  if (state.selection.ranges.some((r) => !r.empty || listLine(r))) return indentMore(view)
  const size = state.facet(indentUnit).length || 4
  view.dispatch(state.changeByRange((r) => {
    const line = state.doc.lineAt(r.head)
    let col = 0
    for (const ch of line.text.slice(0, r.head - line.from)) col += ch === '\t' ? size - (col % size) : 1
    const pad = ' '.repeat(size - (col % size))
    return { changes: { from: r.head, insert: pad }, range: EditorSelection.cursor(r.head + pad.length) }
  }), { userEvent: 'input', scrollIntoView: true })
  return true
}

// ---------- Completion inside code blocks ----------
/** The fenced code block that contains `pos`: { lang, line } or null. */
function fenceAt(state, pos) {
  const doc = state.doc, cur = doc.lineAt(pos).number
  let open = null, n = 0
  for (const text of doc.iterLines(1, cur)) {
    n++
    if (text.indexOf('```') < 0 && text.indexOf('~~~') < 0) continue
    const m = /^\s*(`{3,}|~{3,})\s*([\w+#.-]*)/.exec(text)
    if (!m) continue
    if (!open) open = { mark: m[1], lang: m[2].toLowerCase(), line: n }
    else if (m[1][0] === open.mark[0] && m[1].length >= open.mark.length && !m[2]) open = null
  }
  if (open && /^\s*(`{3,}|~{3,})/.test(doc.line(cur).text)) return null
  return open
}

/** Wraps a completion source so it stays quiet inside code blocks. */
function prose(source) {
  return (ctx) => (fenceAt(ctx.state, ctx.pos) ? null : source(ctx))
}

const KEYWORD_TYPES = { keyword: 'keyword', built_in: 'function', type: 'type', literal: 'constant' }
const keywordCache = new Map()
/** Keywords and built-ins of a language, taken from the preview highlighter's definitions. */
function keywordsFor(lang) {
  if (keywordCache.has(lang)) return keywordCache.get(lang)
  const out = new Map()
  const add = (word, type) => {
    word = String(word).split('|')[0]
    if (word.length > 1 && /^[A-Za-z_$@#][\w$-]*$/.test(word) && !out.has(word)) out.set(word, type)
  }
  const def = lang && hljs.getLanguage(lang)
  const k = def && (def.rawDefinition ? def.rawDefinition(hljs).keywords : def.keywords)
  if (typeof k === 'string') k.split(/\s+/).forEach((w) => add(w, 'keyword'))
  else if (Array.isArray(k)) k.forEach((w) => add(w, 'keyword'))
  else if (k) {
    for (const key of Object.keys(k)) {
      if (key === '$pattern') continue
      const v = k[key], type = KEYWORD_TYPES[key] || 'keyword'
      if (typeof v === 'string') v.split(/\s+/).forEach((w) => add(w, type))
      else if (Array.isArray(v)) v.forEach((w) => add(w, type))
    }
  }
  keywordCache.set(lang, out)
  return out
}

/** Identifiers used in the note's code blocks. */
function codeWords(state, skipFrom, skipTo) {
  const words = new Set()
  let inside = false, pos = 0
  for (const text of state.doc.iterLines()) {
    const start = pos
    pos += text.length + 1
    if (/^\s*(`{3,}|~{3,})/.test(text)) { inside = !inside; continue }
    if (!inside) continue
    const re = /[A-Za-z_$][\w$]{2,}/g
    let m
    while ((m = re.exec(text))) {
      const from = start + m.index
      if (from === skipFrom && from + m[0].length === skipTo) continue
      words.add(m[0])
      if (words.size > 3000) return words
    }
  }
  return words
}

async function codeSource(ctx) {
  const fence = fenceAt(ctx.state, ctx.pos)
  if (!fence) return null
  const word = ctx.matchBefore(/[A-Za-z_$@#][\w$-]*/)
  if (!word || (word.to - word.from < 2 && !ctx.explicit)) return null
  const options = [], seen = new Set()
  const push = (o) => { if (!seen.has(o.label)) { seen.add(o.label); options.push(o) } }
  // What the language itself offers (snippets, local names, properties) comes first.
  for (const source of ctx.state.languageDataAt('autocomplete', ctx.pos)) {
    if (typeof source !== 'function') continue
    try {
      const r = await source(ctx)
      if (r && r.from === word.from) r.options.forEach(push)
    } catch (e) { /* a language source must never break typing */ }
  }
  // Languages such as Dockerfile and SQL ignore case: follow the case being typed.
  const typed = ctx.state.sliceDoc(word.from, word.to)
  const def = fence.lang && hljs.getLanguage(fence.lang)
  const upper = def && def.case_insensitive && /^[A-Z]+$/.test(typed)
  for (const [label, type] of keywordsFor(fence.lang)) push({ label: upper ? label.toUpperCase() : label, type, boost: -1 })
  const end = ctx.state.doc.lineAt(ctx.pos)
  const after = /^[\w$]*/.exec(end.text.slice(ctx.pos - end.from))[0].length
  for (const label of codeWords(ctx.state, word.from, ctx.pos + after)) push({ label, type: 'text', boost: -2 })
  return options.length ? { from: word.from, options, validFor: /^[\w$@#-]*$/ } : null
}

// ---------- Floating toolbar (shown while text is selected) ----------
const TOOLBAR = [
  ['B', 'Bold', 'core:strong'], ['I', 'Italic', 'core:emphasize'], ['S', 'Strikethrough', 'core:strikethrough'],
  ['<>', 'Inline code', 'core:toggle-inline-code'], ['Mark', 'Highlight', 'core:toggle-inline-mark-tag'],
  ['Link', 'Link', 'core:insert-link'], ['H', 'Heading', 'core:toggle-heading-2'],
  ['List', 'Bulleted list', 'core:toggle-bulleted-list'], ['Task', 'Task list', 'core:toggle-task-list'],
  ['AI', 'AI actions', 'ai:menu'],
]
const TABLE_BAR = [
  ['Format', 'Format the table', 'format'],
  ['⇤', 'Align column left', 'align-left'], ['↔', 'Align column center', 'align-center'],
  ['⇥', 'Align column right', 'align-right'], ['✕', 'Clear alignment', 'align-none'],
  ['Row↑', 'Move row up', 'move-row-up'], ['Row↓', 'Move row down', 'move-row-down'],
  ['Col←', 'Move column left', 'move-column-left'], ['Col→', 'Move column right', 'move-column-right'],
  ['+Row', 'Add row', 'insert-row'], ['+Col', 'Add column', 'insert-column'],
  ['−Row', 'Delete row', 'delete-row'], ['−Col', 'Delete column', 'delete-column'],
].map(([label, title, op]) => [label, title, 'table-editor:' + op])

const JA = {
  Bold: '太字', Italic: '斜体', Strikethrough: '取り消し線', 'Inline code': 'インラインコード', Highlight: 'ハイライト',
  Link: 'リンク', Heading: '見出し', 'Bulleted list': '箇条書き', 'Task list': 'タスクリスト', 'AI actions': 'AI の操作',
  'Format the table': '表を整形', 'Align column left': '列を左揃え', 'Align column center': '列を中央揃え',
  'Align column right': '列を右揃え', 'Clear alignment': '揃えを解除', 'Move row up': '行を上へ', 'Move row down': '行を下へ',
  'Move column left': '列を左へ', 'Move column right': '列を右へ', 'Add row': '行を追加', 'Add column': '列を追加',
  'Delete row': '行を削除', 'Delete column': '列を削除', Copy: 'コピー', Copied: 'コピーしました',
  'Create new note': '新規ノートを作成', chars: '文字', 'Rendering diagram…': '図を描画中…',
}
/** A display string in the app language. */
function T(s) { return (opts.lang === 'ja' && JA[s]) || s }

function makeBar(items) {
  const dom = document.createElement('div')
  dom.className = 'sel-toolbar'
  for (const [label, title, id] of items) {
    const b = document.createElement('button')
    b.textContent = label
    b.title = T(title)
    b.dataset.k = label
    b.addEventListener('mousedown', (e) => { e.preventDefault(); runCommand(id) })
    dom.appendChild(b)
  }
  return dom
}

/** Formatting toolbar over a selection; table toolbar over the current table row. */
function selectionTip(state) {
  if (state.readOnly) return null
  const r = state.selection.main
  if (!r.empty) {
    return { kind: 'sel', pos: Math.min(r.from, r.to), above: true, create: () => ({ dom: makeBar(opts.ai ? TOOLBAR : TOOLBAR.filter((b) => b[2] !== 'ai:menu')) }) }
  }
  const line = state.doc.lineAt(r.head)
  if (isTableLine(line.text)) {
    return { kind: 'table', pos: line.from, above: true, create: () => ({ dom: makeBar(TABLE_BAR) }) }
  }
  return null
}
const selToolbar = StateField.define({
  create: selectionTip,
  update(value, tr) {
    if (!tr.docChanged && !tr.selection) return value
    const next = selectionTip(tr.state)
    // Keep the same tooltip object while it stays put so its DOM is not rebuilt.
    if (value && next && value.kind === next.kind && value.pos === next.pos) return value
    return next
  },
  provide: (f) => showTooltip.from(f),
})

// :emoji:
const EMOJI = Object.entries(emojiDefs)
function emojiSource(ctx) {
  const line = ctx.state.doc.lineAt(ctx.pos)
  const before = line.text.slice(0, ctx.pos - line.from)
  const m = before.match(/(?:^|\s):([a-z0-9_+-]{2,})$/)
  if (!m) return null
  const from = ctx.pos - m[1].length - 1
  return {
    from,
    validFor: /^:[a-z0-9_+-]*$/,
    options: EMOJI.map(([name, char]) => ({
      label: ':' + name,
      displayLabel: `${char}  ${name}`,
      apply: (v, _c, f, to) => put(v, f, to, char),
    })),
  }
}

// ---------- Editor ----------
// ---------- Inline AI completion (ghost text; Tab accepts) ----------
class GhostWidget extends WidgetType {
  constructor(text) { super(); this.text = text }
  eq(o) { return o.text === this.text }
  toDOM() {
    const el = document.createElement('span')
    el.className = 'cm-ghost'
    el.textContent = this.text
    return el
  }
  ignoreEvent() { return true }
}
const setGhost = StateEffect.define()
const ghostField = StateField.define({
  create: () => null,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setGhost)) return e.value
    if (!value) return null
    if (tr.docChanged) {
      // Typing the suggested characters keeps the rest of the suggestion.
      let kept = null
      let count = 0
      tr.changes.iterChanges((fromA, toA, _fromB, toB, inserted) => {
        count++
        const text = inserted.toString()
        if (fromA === value.pos && toA === value.pos && text && value.text.startsWith(text) && text.length < value.text.length) {
          kept = { pos: toB, text: value.text.slice(text.length) }
        }
      })
      return count === 1 && kept && tr.state.selection.main.head === kept.pos ? kept : null
    }
    if (tr.selection) return null
    return value
  },
  provide: (f) => EditorView.decorations.from(f, (v) => v
    ? Decoration.set([Decoration.widget({ widget: new GhostWidget(v.text), side: 1 }).range(v.pos)])
    : Decoration.none),
})
let ghostSeq = 0
let ghostTimer = null
let ghostPending = null

function acceptGhost(v) {
  const g = v.state.field(ghostField, false)
  if (!g) return false
  v.dispatch({
    changes: { from: g.pos, insert: g.text },
    selection: { anchor: g.pos + g.text.length },
    effects: setGhost.of(null),
    userEvent: 'input.complete',
  })
  return true
}

function scheduleGhost(u) {
  clearTimeout(ghostTimer)
  ghostPending = null
  if (!opts.aiComplete || !current || current.readOnly || !inInsert() || u.view.composing) return
  if (!u.transactions.some((tr) => tr.isUserEvent('input.type') || tr.isUserEvent('input.paste') || tr.isUserEvent('input'))) return
  const st = u.state
  const r = st.selection.main
  if (!r.empty) return
  const line = st.doc.lineAt(r.head)
  // Only at the end of a line, and only once there is something to continue.
  if (st.sliceDoc(r.head, line.to).trim() || st.sliceDoc(Math.max(0, r.head - 40), r.head).trim().length < 3) return
  ghostTimer = setTimeout(() => {
    if (view.composing || view.state.selection.main.head !== r.head) return
    const req = ++ghostSeq
    ghostPending = { req, pos: r.head, len: view.state.doc.length }
    post({ type: 'aiComplete', req, before: view.state.sliceDoc(Math.max(0, r.head - 1500), r.head) })
  }, 650)
}

const ghostKeys = Prec.highest(keymap.of([
  { key: 'Tab', run: acceptGhost },
  { key: 'Escape', run: (v) => { if (v.state.field(ghostField, false)) v.dispatch({ effects: setGhost.of(null) }); return false } },
]))

const editorKeys = Prec.high(keymap.of([
  { key: 'Tab', run: () => inInsert() && tableOp('next-cell') },
  { key: 'Shift-Tab', run: () => inInsert() && tableOp('previous-cell') },
  { key: 'Enter', run: () => inInsert() && tableOp('next-row') },
  { key: 'Shift-Mod-Enter', run: insertLineBefore },
  { key: 'Mod-l', run: selectLine },
  { key: 'Ctrl-j', run: () => inInsert() && joinLines() },
]))

function extensions(readOnly) {
  return [
    vimC.of(opts.vim ? vim() : []),
    numC.of(opts.lineNumbers ? lineNumbers() : []),
    wrapC.of(opts.lineWrap ? EditorView.lineWrapping : []),
    EditorState.readOnly.of(!!readOnly),
    history(),
    drawSelection(),
    bracketMatching(),
    highlightActiveLine(),
    highlightSelectionMatches(),
    indentUnit.of('    '),
    EditorState.tabSize.of(4),
    tbC.of(opts.toolbar ? selToolbar : []),
    autocompletion({ override: [prose(slashSource), prose(linkSource), langSource, prose(emojiSource), codeSource], icons: false }),
    ghostField,
    ghostKeys,
    editorKeys,
    markdown({ base: markdownLanguage, codeLanguages }),
    syntaxHighlighting(mdStyle),
    syntaxHighlighting(classHighlighter),
    keymap.of([{ key: 'Tab', run: tabKey, shift: indentLess }, ...defaultKeymap.filter((k) => k.key !== 'Mod-/'), ...historyKeymap, ...searchKeymap]),
    EditorView.updateListener.of(onUpdate),
    EditorView.domEventHandlers({
      paste(e) {
        if (current && !current.readOnly && takeFiles(e.clipboardData)) { e.preventDefault(); return true }
        return false
      },
      drop(e) {
        if (!current || current.readOnly) return false
        if (takeFiles(e.dataTransfer)) {
          e.preventDefault()
          const at = view.posAtCoords({ x: e.clientX, y: e.clientY })
          if (at != null) view.dispatch({ selection: { anchor: at } })
          return true
        }
        // A note dragged from the note list arrives as its id.
        const text = (e.dataTransfer && e.dataTransfer.getData('text/plain') || '').trim()
        if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(text)) {
          e.preventDefault()
          const pos = view.posAtCoords({ x: e.clientX, y: e.clientY })
          if (pos != null) view.dispatch({ selection: { anchor: pos } })
          view.focus()
          post({ type: 'dropNote', id: text })
          return true
        }
        return false
      },
    }),
  ]
}

const view = new EditorView({
  state: EditorState.create({ doc: '', extensions: extensions(true) }),
  parent: $('editor'),
})

function body() { return view.state.doc.toString() }

function onUpdate(u) {
  if (u.docChanged) {
    if (current) {
      clearTimeout(changeTimer)
      changeTimer = setTimeout(flushChange, 200)
    }
    if (mode !== 'edit') {
      clearTimeout(previewTimer)
      previewTimer = setTimeout(renderPreview, 120)
    }
  }
  if (u.docChanged || u.selectionSet) updateStatus()
  if (u.docChanged) scheduleGhost(u)
  else if (u.selectionSet) { clearTimeout(ghostTimer); ghostPending = null }
}

function flushChange() {
  if (changeTimer === null) return
  clearTimeout(changeTimer)
  changeTimer = null
  if (current) post({ type: 'change', id: current.id, body: body() })
}

function updateStatus() {
  const s = view.state
  const head = s.selection.main.head
  const line = s.doc.lineAt(head)
  elPos.textContent = `Ln ${line.number}, Col ${head - line.from + 1}`
  elCount.textContent = `${s.doc.length} ${T('chars')}`
}

// ---------- Vim ----------
function setModeLabel(m, sub) {
  let label = ''
  if (opts.vim) {
    label = (m || 'normal').toUpperCase()
    if (m === 'visual' && sub === 'linewise') label = 'V-LINE'
    if (m === 'visual' && sub === 'blockwise') label = 'V-BLOCK'
  }
  elMode.textContent = label
  elMode.dataset.mode = m || 'normal'
  elMode.style.display = label ? '' : 'none'
}

function attachVim() {
  const cm = getCM(view)
  vimState = 'normal'
  setModeLabel('normal')
  if (!cm) return
  cm.on('vim-mode-change', (e) => {
    vimState = e.mode
    setModeLabel(e.mode, e.subMode)
    post({ type: 'vimMode', mode: e.mode })
  })
}

// Ex commands.
Vim.defineEx('write', 'w', () => { flushChange(); post({ type: 'save' }) })
Vim.defineEx('next', 'n', () => runCommand('core:open-next-note'))
Vim.defineEx('prev', 'prev', () => runCommand('core:open-prev-note'))
Vim.defineEx('preview', 'p', () => runCommand('view:toggle-preview'))
Vim.defineEx('side', 'side', () => runCommand('view:toggle-side-by-side'))
Vim.defineEx('cmd', 'cmd', (_cm, params) => {
  const id = (params.argString || '').trim()
  if (id) runCommand(id)
})
Vim.defineEx('quit', 'q', () => runCommand('core:focus-note-list-bar'))
Vim.defineEx('wq', 'wq', () => { flushChange(); post({ type: 'save' }); runCommand('core:focus-note-list-bar') })

// System clipboard as the unnamed register (clipboard=unnamed).
try {
  const rc = Vim.getRegisterController()
  const push = rc.pushText.bind(rc)
  rc.pushText = function (name, operator, text, linewise, blockwise) {
    push(name, operator, text, linewise, blockwise)
    if (opts.clipboard && (!name || name === '"' || name === '+' || name === '*') && typeof text === 'string' && text) {
      post({ type: 'clipboard', text })
    }
  }
} catch (e) { console.warn('clipboard hook', e) }

function applyVimrc(text) {
  try { Vim.mapclear() } catch (e) {}
  const ctxOf = { i: 'insert', n: 'normal', v: 'visual' }
  for (const raw of (text || '').split('\n')) {
    const line = raw.trim()
    if (!line || line.startsWith('"')) continue
    try {
      let m
      if ((m = line.match(/^([inv])?(nore)?map\s+(\S+)\s+(.+)$/))) {
        const ctx = ctxOf[m[1]]
        if (m[2]) Vim.noremap(m[3], m[4], ctx)
        else Vim.map(m[3], m[4], ctx)
      } else if ((m = line.match(/^([inv])?unmap\s+(\S+)$/))) {
        Vim.unmap(m[2], ctxOf[m[1]])
      } else if ((m = line.match(/^set\s+(no)?(\w+)(?:=(.+))?$/))) {
        const v = m[3] === undefined ? !m[1] : (isNaN(Number(m[3])) ? m[3] : Number(m[3]))
        Vim.setOption(m[2], v)
      }
    } catch (e) { console.warn('vimrc:', line, e) }
  }
}

// IME guard: outside insert mode, keys must reach Vim as plain ASCII. Ask the app to switch the
// input source when the editor gets focus, and discard anything an IME composed in normal mode.
const wantsAscii = () => opts.vim && !inInsert() && mode !== 'preview'
let strayDoc = null
let straySel = null
view.contentDOM.addEventListener('focus', () => { if (wantsAscii()) post({ type: 'ime' }) })
view.contentDOM.addEventListener('compositionstart', () => {
  if (!wantsAscii()) return
  strayDoc = view.state.doc
  straySel = view.state.selection
  post({ type: 'ime' })
}, true)
view.contentDOM.addEventListener('compositionend', () => {
  if (strayDoc === null) return
  const doc = strayDoc
  const sel = straySel
  strayDoc = null
  setTimeout(() => {
    if (inInsert() || view.state.doc.eq(doc)) return
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: doc }, selection: sel })
  }, 0)
}, true)

// Ctrl+H: move focus to the pane on the left (the note list). Ctrl+L has nothing to the right.
document.addEventListener('keydown', (e) => {
  if (!e.ctrlKey || e.metaKey || e.altKey || e.shiftKey) return
  if (e.key !== 'h' && e.key !== 'l') return
  if (mode !== 'preview' && inInsert()) return
  e.preventDefault()
  e.stopPropagation()
  if (e.key === 'h') runCommand('core:focus-note-list-bar')
}, true)

// Cmd+Left / Cmd+Right: note history, unless typing text.
document.addEventListener('keydown', (e) => {
  if (!e.metaKey || e.shiftKey || e.altKey || e.ctrlKey) return
  if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return
  if (mode !== 'preview' && (!opts.vim || inInsert())) return
  e.preventDefault()
  e.stopPropagation()
  runCommand(e.key === 'ArrowLeft' ? 'core:navigate-back' : 'core:navigate-forward')
}, true)

// ---------- Images and other attachments ----------
const MAX_ATTACHMENT = 50 * 1024 * 1024
function takeFiles(dt) {
  if (!dt || !dt.files || !dt.files.length) return false
  for (const f of dt.files) {
    if (f.size > MAX_ATTACHMENT) { post({ type: 'fileTooLarge', name: f.name }); continue }
    const r = new FileReader()
    r.onload = () => {
      const data = String(r.result).split(',')[1]
      if (f.type.startsWith('image/')) {
        const ext = f.type.split('/')[1].replace('jpeg', 'jpg').replace('svg+xml', 'svg')
        post({ type: 'image', data, ext })
      } else {
        post({ type: 'file', data, name: f.name })
      }
    }
    r.readAsDataURL(f)
  }
  return true
}

// ---------- Preview ----------
const PURIFY = {
  ADD_ATTR: ['target'],
  // A note must not restyle the app or show fake forms.
  FORBID_TAGS: ['style', 'form', 'textarea', 'select', 'button'],
  ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|tel|sumi):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i,
}
const COLOR_RE = /^(#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})|rgba?\([\d\s,.%/]+\)|hsla?\([\d\s,.%/deg]+\))$/i
const mermaidCache = new Map()
let mermaidLoading = null
let mermaidSeq = 0

function loadMermaid() {
  if (!mermaidLoading) {
    mermaidLoading = new Promise((resolve, reject) => {
      const el = document.createElement('script')
      el.src = 'mermaid.min.js'
      el.onload = () => {
        const dark = opts.scheme === 'dark' || (opts.scheme !== 'light' && window.matchMedia('(prefers-color-scheme: dark)').matches)
        window.mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default' })
        resolve(window.mermaid)
      }
      el.onerror = reject
      document.head.appendChild(el)
    })
  }
  return mermaidLoading
}

function renderMermaid(pre, src) {
  const box = document.createElement('div')
  box.className = 'mermaid-box'
  pre.replaceWith(box)
  if (mermaidCache.has(src)) { box.innerHTML = mermaidCache.get(src); return }
  box.textContent = T('Rendering diagram…')
  loadMermaid()
    .then((m) => m.render('mmd' + (++mermaidSeq), src))
    .then(({ svg }) => {
      if (mermaidCache.size > 40) mermaidCache.clear()
      mermaidCache.set(src, svg)
      if (box.isConnected) box.innerHTML = svg
    })
    .catch((err) => { box.className = 'mermaid-box error'; box.textContent = String(err && err.message || err) })
}

const previewHooks = []
function renderPreview() {
  renderPreviewCore()
  for (const fn of previewHooks) {
    try { fn(previewEl) } catch (e) { console.error(e) }
  }
}
function renderPreviewCore() {
  previewEl.innerHTML = current ? DOMPurify.sanitize(md.render(body()), PURIFY) : ''
  for (const bq of previewEl.querySelectorAll('blockquote')) {
    const p = bq.firstElementChild
    if (!p || p.tagName !== 'P') continue
    const m = p.innerHTML.match(/^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(?:<br>\s*)?/i)
    if (!m) continue
    const kind = m[1].toLowerCase()
    p.innerHTML = p.innerHTML.slice(m[0].length)
    if (!p.textContent.trim() && !p.children.length) p.remove()
    const title = document.createElement('p')
    title.className = 'alert-title'
    title.textContent = kind[0].toUpperCase() + kind.slice(1)
    bq.prepend(title)
    bq.classList.add('alert', 'alert-' + kind)
  }
  for (const pre of previewEl.querySelectorAll('pre')) {
    const code = pre.querySelector('code')
    if (!code) continue
    const src = code.textContent
    if (code.classList.contains('language-mermaid')) { renderMermaid(pre, src); continue }
    if (code.classList.contains('language-math')) {
      const box = document.createElement('div')
      box.className = 'math-block'
      box.innerHTML = katex.renderToString(src, { displayMode: true, throwOnError: false })
      pre.replaceWith(box)
      continue
    }
    const btn = document.createElement('button')
    btn.className = 'copy-btn'
    btn.textContent = T('Copy')
    pre.appendChild(btn)
  }
  for (const code of previewEl.querySelectorAll(':not(pre) > code')) {
    const text = code.textContent.trim()
    if (!COLOR_RE.test(text) || !CSS.supports('color', text)) continue
    const sw = document.createElement('span')
    sw.className = 'swatch'
    sw.style.background = text
    code.appendChild(sw)
  }
}

const TASK_RE = /^(\s*(?:[-*+]|\d+[.)])\s+)\[([ xX])\]/
function toggleTask(index) {
  if (!current || current.readOnly) return
  const doc = view.state.doc
  let n = -1
  let fence = null
  for (let i = 1; i <= doc.lines; i++) {
    const line = doc.line(i)
    const f = line.text.match(/^\s*(```+|~~~+)/)
    if (f) {
      if (!fence) fence = f[1][0]
      else if (f[1][0] === fence) fence = null
      continue
    }
    if (fence) continue
    const m = line.text.match(TASK_RE)
    if (!m) continue
    n++
    if (n === index) {
      const at = line.from + m[1].length + 1
      view.dispatch({ changes: { from: at, to: at + 1, insert: m[2] === ' ' ? 'x' : ' ' } })
      return
    }
  }
}

previewEl.addEventListener('dblclick', (e) => {
  if (e.target.tagName !== 'IMG') return
  const overlay = document.createElement('div')
  overlay.id = 'viewer'
  const img = document.createElement('img')
  img.src = e.target.src
  overlay.appendChild(img)
  overlay.addEventListener('click', () => overlay.remove())
  document.body.appendChild(overlay)
})
document.addEventListener('keydown', (e) => {
  const v = document.getElementById('viewer')
  if (v && e.key === 'Escape') { v.remove(); e.preventDefault(); e.stopPropagation() }
}, true)

previewEl.addEventListener('click', (e) => {
  if (e.target.classList.contains('copy-btn')) {
    const code = e.target.parentElement.querySelector('code')
    post({ type: 'clipboard', text: code ? code.textContent : '' })
    e.target.textContent = T('Copied')
    setTimeout(() => { e.target.textContent = T('Copy') }, 1200)
    return
  }
  const a = e.target.closest('a')
  if (a) {
    e.preventDefault()
    const href = a.getAttribute('href') || ''
    if (href.startsWith('sumi://note/')) {
      post({ type: 'openNote', id: href.slice('sumi://note/'.length) })
    } else if (href.startsWith('sumi://attachment/')) {
      post({ type: 'openAttachment', name: href.slice('sumi://attachment/'.length) })
    } else if (href.startsWith('#')) {
      const el = document.getElementById(decodeURIComponent(href.slice(1)))
      if (el) el.scrollIntoView()
    } else {
      post({ type: 'open', url: a.href })
    }
    return
  }
  if (e.target.matches('input[type=checkbox]')) {
    e.preventDefault()
    const boxes = [...previewEl.querySelectorAll('input.task-list-item-checkbox')]
    const idx = boxes.indexOf(e.target)
    if (idx >= 0) setTimeout(() => toggleTask(idx), 0)
  }
})

let pendingG = false
previewEl.addEventListener('keydown', (e) => {
  if (e.metaKey || e.altKey) return
  const page = previewEl.clientHeight
  const by = (d) => { previewEl.scrollTop += d; e.preventDefault() }
  const wasG = pendingG
  pendingG = false
  if (e.ctrlKey) {
    switch (e.key) {
      case 'd': by(page / 2); break
      case 'u': by(-page / 2); break
      case 'f': by(page); break
      case 'b': by(-page); break
    }
    return
  }
  switch (e.key) {
    case 'j': by(60); break
    case 'k': by(-60); break
    case 'g': if (wasG) { previewEl.scrollTop = 0 } else pendingG = true; e.preventDefault(); break
    case 'H': previewEl.scrollTop = 0; e.preventDefault(); break
    case 'G': previewEl.scrollTop = previewEl.scrollHeight; e.preventDefault(); break
    case 'i': case 'Escape': runCommand('view:show-editor'); e.preventDefault(); break
  }
})

view.scrollDOM.addEventListener('scroll', () => {
  if (mode !== 'split') return
  const s = view.scrollDOM
  const max = s.scrollHeight - s.clientHeight
  if (max <= 0) return
  previewEl.scrollTop = (s.scrollTop / max) * (previewEl.scrollHeight - previewEl.clientHeight)
})

// ---------- API for Swift ----------
function focus() {
  if (mode === 'preview') previewEl.focus()
  else view.focus()
}

function pluginAPI(name) {
  return {
    version: 1,
    name,
    /** The markdown-it instance used for the preview: `sumi.md.use(plugin)`. */
    md,
    /** The CodeMirror EditorView. */
    get view() { return view },
    registerCommand(id, title, run) { pluginCommands[id] = { title: title || id, run } },
    runCommand,
    addStyle(css) {
      const el = document.createElement('style')
      el.dataset.plugin = name
      el.textContent = css
      document.head.appendChild(el)
    },
    /** Called with the preview element after every render. */
    onPreviewRender(fn) { previewHooks.push(fn) },
    getText: () => body(),
    getSelection() {
      const r = view.state.selection.main
      return view.state.sliceDoc(r.from, r.to)
    },
    insertText(text) { view.dispatch(view.state.replaceSelection(String(text))) },
  }
}

window.sumi = {
  setNote(p) {
    flushChange()
    if (current) {
      stateCache.delete(current.id)
      stateCache.set(current.id, { state: view.state, readOnly: current.readOnly })
      if (stateCache.size > 30) stateCache.delete(stateCache.keys().next().value)
    }
    if (!p) {
      current = null
      view.setState(EditorState.create({ doc: '', extensions: extensions(true) }))
    } else {
      const c = stateCache.get(p.id)
      const reuse = c && c.readOnly === !!p.readOnly && c.state.doc.toString() === p.body
      view.setState(reuse ? c.state : EditorState.create({ doc: p.body, extensions: extensions(p.readOnly) }))
      current = { id: p.id, readOnly: !!p.readOnly }
      if (!reuse) view.scrollDOM.scrollTop = 0
    }
    attachVim()
    updateStatus()
    renderPreview()
    previewEl.scrollTop = 0
  },
  setMode(p) {
    mode = p.mode
    root.className = 'mode-' + mode
    if (mode !== 'edit') renderPreview()
    view.requestMeasure()
    if (p.focus) focus()
  },
  setOptions(o) {
    opts = Object.assign({}, opts, o)
    document.documentElement.style.setProperty('--font-size', opts.fontSize + 'px')
    document.documentElement.classList.toggle('readable', !!opts.readable)
    if (opts.theme && opts.theme !== 'default') document.documentElement.dataset.theme = opts.theme
    else delete document.documentElement.dataset.theme
    if (opts.scheme === 'light' || opts.scheme === 'dark') document.documentElement.dataset.scheme = opts.scheme
    else delete document.documentElement.dataset.scheme
    let css = document.getElementById('user-css')
    if (!css) {
      css = document.createElement('style')
      css.id = 'user-css'
      document.head.appendChild(css)
    }
    if (css.textContent !== (opts.customCSS || '')) css.textContent = opts.customCSS || ''
    stateCache.clear()
    view.dispatch({
      effects: [
        vimC.reconfigure(opts.vim ? vim() : []),
        numC.reconfigure(opts.lineNumbers ? lineNumbers() : []),
        wrapC.reconfigure(opts.lineWrap ? EditorView.lineWrapping : []),
        tbC.reconfigure(opts.toolbar ? selToolbar : []),
      ],
    })
    applyVimrc(opts.vimrc)
    attachVim()
  },
  setClipboard(p) {
    try {
      const text = p.text || ''
      Vim.getRegisterController().unnamedRegister.setText(text, /\n$/.test(text), false)
    } catch (e) {}
  },
  insertText(p) {
    view.dispatch(view.state.replaceSelection(p.text))
  },
  command(p) { runCommand(p.id) },
  /** Answer to an `aiComplete` request: shown as ghost text if nothing moved meanwhile. */
  aiCompletion(p) {
    const g = ghostPending
    if (!g || g.req !== p.req || !p.text) return
    ghostPending = null
    if (view.state.doc.length !== g.len || view.state.selection.main.head !== g.pos || view.composing || !inInsert()) return
    view.dispatch({ effects: setGhost.of({ pos: g.pos, text: p.text }) })
  },
  /** Text the AI actions work on: the selection, or the whole note. */
  getContext() {
    const r = view.state.selection.main
    return {
      selection: view.state.sliceDoc(r.from, r.to),
      text: body(),
      readOnly: !current || current.readOnly,
    }
  },
  insertAfter(p) {
    const r = view.state.selection.main
    const line = view.state.doc.lineAt(r.to)
    const text = '\n\n' + p.text
    view.dispatch({ changes: { from: line.to, insert: text }, selection: { anchor: line.to + text.length } })
  },
  /** Runs user plugins: [{ name, code }]. Each gets the plugin API as `sumi`. */
  loadPlugins(list) {
    const loaded = []
    const errors = []
    for (const p of list || []) {
      try {
        new Function('sumi', p.code)(pluginAPI(p.name))
        loaded.push(p.name)
      } catch (e) {
        errors.push({ name: p.name, message: String(e && e.message || e) })
      }
    }
    post({
      type: 'plugins', loaded, errors,
      commands: Object.entries(pluginCommands).map(([id, c]) => ({ id, title: c.title })),
    })
    if (current) renderPreview()
  },
  notesResult(p) {
    const done = pendingNotes.get(p.req)
    if (done) { pendingNotes.delete(p.req); done(p.items || []) }
  },
  gotoLine(p) {
    const n = Math.min(Math.max(1, p.line), view.state.doc.lines)
    const pos = view.state.doc.line(n).from
    view.dispatch({ selection: { anchor: pos }, effects: EditorView.scrollIntoView(pos, { y: 'start', yMargin: 40 }) })
    const id = (p.text || '').trim()
    if (mode !== 'edit' && id) {
      const h = [...previewEl.querySelectorAll('h1,h2,h3,h4,h5,h6')].find((el) => el.textContent.trim() === id)
      if (h) h.scrollIntoView()
    }
  },
  preparePrint() { renderPreview() },
  exportHTML() { renderPreview(); return previewEl.innerHTML },
  focus,
  flush: flushChange,
}

window.addEventListener('blur', flushChange)
updateStatus()
attachVim()
post({ type: 'ready' })
