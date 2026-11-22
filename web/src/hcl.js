// HCL / Terraform support: editor highlighting, preview highlighting and completion words.
import { StreamLanguage, LanguageSupport, LanguageDescription } from '@codemirror/language'

const BLOCKS = ['resource', 'data', 'variable', 'output', 'locals', 'module', 'provider', 'terraform', 'backend',
  'provisioner', 'connection', 'dynamic', 'lifecycle', 'required_providers', 'moved', 'import', 'removed', 'check',
  'content', 'validation', 'precondition', 'postcondition']
const KEYWORDS = ['for', 'in', 'if', 'else', 'endif', 'endfor', 'for_each', 'count', 'depends_on', 'source', 'version']
const LITERALS = ['true', 'false', 'null']
const TYPES = ['string', 'number', 'bool', 'list', 'map', 'set', 'object', 'tuple', 'any', 'optional']
const REFS = ['var', 'local', 'module', 'data', 'each', 'self', 'path', 'terraform']
const FUNCTIONS = ['abs', 'abspath', 'alltrue', 'anytrue', 'base64decode', 'base64encode', 'base64gzip', 'base64sha256',
  'base64sha512', 'basename', 'bcrypt', 'can', 'ceil', 'chomp', 'chunklist', 'cidrhost', 'cidrnetmask', 'cidrsubnet',
  'cidrsubnets', 'coalesce', 'coalescelist', 'compact', 'concat', 'contains', 'csvdecode', 'dirname', 'distinct',
  'element', 'endswith', 'file', 'filebase64', 'filebase64sha256', 'fileexists', 'filemd5', 'fileset', 'filesha256',
  'flatten', 'floor', 'format', 'formatdate', 'formatlist', 'indent', 'index', 'join', 'jsondecode', 'jsonencode',
  'keys', 'length', 'log', 'lookup', 'lower', 'matchkeys', 'max', 'md5', 'merge', 'min', 'nonsensitive', 'one',
  'parseint', 'pathexpand', 'pow', 'range', 'regex', 'regexall', 'replace', 'reverse', 'rsadecrypt', 'sensitive',
  'setintersection', 'setproduct', 'setsubtract', 'setunion', 'sha1', 'sha256', 'sha512', 'signum', 'slice', 'sort',
  'split', 'startswith', 'strcontains', 'strrev', 'substr', 'sum', 'templatefile', 'textdecodebase64',
  'textencodebase64', 'timeadd', 'timecmp', 'timestamp', 'title', 'tobool', 'tolist', 'tomap', 'tonumber', 'toset',
  'tostring', 'transpose', 'trim', 'trimprefix', 'trimspace', 'trimsuffix', 'try', 'upper', 'urlencode', 'uuid',
  'uuidv5', 'values', 'yamldecode', 'yamlencode', 'zipmap']

const set = (list) => new Set(list)
const blocks = set(BLOCKS), keywords = set(KEYWORDS), literals = set(LITERALS), types = set(TYPES), refs = set(REFS)
const functions = set(FUNCTIONS)

const mode = {
  name: 'hcl',
  startState: () => ({ comment: false, heredoc: null, string: false }),
  token(stream, state) {
    if (state.heredoc) {
      if (stream.sol() && stream.match(new RegExp('^\\s*' + state.heredoc + '\\s*$'))) { state.heredoc = null; return 'string' }
      stream.skipToEnd()
      return 'string'
    }
    if (state.comment) {
      if (stream.skipTo('*/')) { stream.next(); stream.next(); state.comment = false } else stream.skipToEnd()
      return 'comment'
    }
    if (state.string) {
      while (!stream.eol()) {
        const ch = stream.next()
        if (ch === '\\') stream.next()
        else if (ch === '"') { state.string = false; break }
      }
      return 'string'
    }
    if (stream.eatSpace()) return null
    if (stream.match('#') || stream.match('//')) { stream.skipToEnd(); return 'comment' }
    if (stream.match('/*')) { state.comment = true; return 'comment' }
    const here = stream.match(/^<<-?([A-Za-z_]\w*)/)
    if (here) { state.heredoc = here[1]; return 'string' }
    if (stream.eat('"')) { state.string = true; return 'string' }
    if (stream.match(/^-?(0x[0-9a-fA-F]+|\d+(\.\d+)?([eE][+-]?\d+)?)/)) return 'number'
    const word = stream.match(/^[A-Za-z_][\w-]*/)
    if (word) {
      const w = word[0]
      if (literals.has(w)) return 'atom'
      if (stream.match(/^\s*\(/, false)) return functions.has(w) ? 'builtin' : 'variable'
      if (stream.match(/^\s*=(?!=)/, false)) return 'property'
      if (blocks.has(w)) return 'keyword'
      if (keywords.has(w)) return 'keyword'
      if (types.has(w)) return 'type'
      if (refs.has(w) && stream.match(/^\./, false)) return 'keyword'
      return 'variable'
    }
    stream.next()
    return null
  },
  languageData: { commentTokens: { line: '#', block: { open: '/*', close: '*/' } } },
}

export const hclDescription = LanguageDescription.of({
  name: 'HCL',
  alias: ['hcl', 'terraform', 'tf', 'tfvars'],
  extensions: ['tf', 'tfvars', 'hcl'],
  support: new LanguageSupport(StreamLanguage.define(mode)),
})

/** highlight.js definition, used for the preview and for completion words. */
export function hclHighlight(hljs) {
  const interpolation = { className: 'subst', begin: /\$\{/, end: /\}/, keywords: { built_in: FUNCTIONS, literal: LITERALS } }
  return {
    name: 'HCL',
    aliases: ['terraform', 'tf', 'tfvars'],
    keywords: { keyword: [...BLOCKS, ...KEYWORDS, ...REFS], built_in: FUNCTIONS, literal: LITERALS, type: TYPES },
    contains: [
      hljs.HASH_COMMENT_MODE, hljs.C_LINE_COMMENT_MODE, hljs.C_BLOCK_COMMENT_MODE,
      { className: 'string', begin: /<<-?([A-Za-z_]\w*)/, end: /^\s*[A-Za-z_]\w*\s*$/, contains: [interpolation] },
      { className: 'string', begin: /"/, end: /"/, contains: [hljs.BACKSLASH_ESCAPE, interpolation] },
      { className: 'attr', begin: /^\s*[A-Za-z_][\w-]*(?=\s*=(?!=))/, relevance: 0 },
      hljs.C_NUMBER_MODE,
    ],
  }
}
