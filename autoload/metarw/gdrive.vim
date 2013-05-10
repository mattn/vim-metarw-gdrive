function! metarw#gdrive#complete(arglead, cmdline, cursorpos)
  if !s:load_settings()
    return [[], '', '']
  endif
  let candidates = []
  if a:arglead !~ '[\/]$'
    let path = substitute(a:arglead, '/[^/]\+$', '', '')
  else
    let path = a:arglead[:-2]
  endif
  let _ = s:parse_incomplete_fakepath(path)
  let res = s:read_list(_)
  if res[0] == 'browse'
    return [filter(map(res[1], 'v:val["fakepath"]'), 'stridx(v:val, a:arglead)==0'), a:cmdline, '']
  endif
  return [[], '', '']
endfunction

function! metarw#gdrive#read(fakepath)
  let _ = s:parse_incomplete_fakepath(a:fakepath)
  if _.path == '' || _.path =~ '[\/]$'
    let result = s:read_list(_)
  else
    let result = s:read_content(_)
  endif
  return result
endfunction

function! metarw#gdrive#write(fakepath, line1, line2, append_p)
  let _ = s:parse_incomplete_fakepath(a:fakepath)
  if _.path == '' || _.path =~ '[\/]$'
    echoerr 'Unexpected a:incomplete_fakepath:' string(a:incomplete_fakepath)
    throw 'metarw:gdrive#e1'
  else
    let content = iconv(join(getline(a:line1, a:line2), "\n"), &encoding, 'utf-8')
    let result = s:write_content(_, content)
  endif
  return result
endfunction

function! s:parse_incomplete_fakepath(incomplete_fakepath)
  let _ = {}
  let fragments = split(a:incomplete_fakepath, '^\l\+\zs:', !0)
  if len(fragments) <= 1
    echoerr 'Unexpected a:incomplete_fakepath:' string(a:incomplete_fakepath)
    throw 'metarw:gdrive#e1'
  endif
  let _.given_fakepath = a:incomplete_fakepath
  let _.scheme = fragments[0]
  let _.path = fragments[1]
  if fragments[1] == '' || fragments[1] =~ '^[\/]$'
    let _.id = 'root'
  else
    let _.id = split(fragments[1], '[\/]')[-1]
  endif
  return _
endfunction

function! s:read_content(_, ...)
  if !s:load_settings()
    return ['error', v:errmsg]
  endif
  let res = webapi#json#decode(webapi#http#get('https://www.googleapis.com/drive/v2/files/' . webapi#http#encodeURI(a:_.id), {'access_token': s:settings['access_token']}).content)
  if has_key(res, 'error')
    if res.error.code != 401 || a:0 != 0
      return ['error', res.error.message]
    endif
    if !s:refresh_token()
      return ['error', v:errmsg]
    endif
    return s:read_content(a:_, 1)
  endif
  if !has_key(res, 'downloadUrl')
    return ['error', 'This file seems impossible to edit in vim!']
  endif
  let resp = webapi#http#get(res.downloadUrl, '', {'Authorization': 'Bearer ' . s:settings['access_token']})
  if resp.status !~ '^2'
    return ['error', resp.header[0]]
  endif
  let content = resp.content
  call setline(2, split(iconv(content, 'utf-8', &encoding), "\n"))

  let ext = '.' . res.fileExtension
  if has_key(s:extmap, ext)
    let &filetype = s:extmap[ext]
  endif
  let b:metarw_gdrive_id = a:_.id
  return ['done', '']
endfunction

function! s:write_content(_, content, ...)
  if !s:load_settings()
    return ['error', v:errmsg]
  endif
  let id = a:_.id
  if !has_key(b:, 'metarw_gdrive_id')
    let title = id
    let path = split(a:_.path, '[\/]')[0]
    let res = webapi#json#decode(webapi#http#post('https://www.googleapis.com/drive/v2/files', webapi#json#encode({"title": title, "mimeType": "application/octet-stream", "description": "", "parents": [{"id": path}]}), {'Authorization': 'Bearer ' . s:settings['access_token'], 'Content-Type': 'application/json'}, 'POST').content)
    let id = res['id']
  endif
  let res = webapi#json#decode(webapi#http#post('https://www.googleapis.com/upload/drive/v2/files/' . webapi#http#encodeURI(id), a:content, {'Authorization': 'Bearer ' . s:settings['access_token'], 'Content-Type': 'application/octet-stream'}, 'PUT').content)
  if has_key(res, 'error')
    if res.error.code != 401 || a:0 != 0
      return ['error', res.error.message]
    endif
    if !s:refresh_token()
      return ['error', v:errmsg]
    endif
    return s:write_content(a:_, a:content, 1)
  endif
  return ['done', '']
endfunction

function! s:refresh_token()
  let res = webapi#json#decode(webapi#http#post('https://accounts.google.com/o/oauth2/token', {'client_id': '557347129504.apps.googleusercontent.com', 'client_secret': 'C9SVT4PHZe_U_wRSWJK67zUA', 'refresh_token': s:settings['refresh_token'], 'grant_type': 'refresh_token'}).content)
  if has_key(res, 'error')
    let v:errmsg = res.error.message
    return 0
  endif
  if has_key(res, 'access_token')
    let s:settings['access_token'] = res['access_token']
  endif
  if has_key(res, 'refresh_token')
    let s:settings['refresh_token'] = res['refresh_token']
  endif
  call s:save_settings()
  return 1
endfunction

function! s:read_list(_, ...)
  if !s:load_settings()
    return ['error', v:errmsg]
  endif
  let result = []
  let res = webapi#json#decode(webapi#http#get('https://www.googleapis.com/drive/v2/files', {'access_token': s:settings['access_token'], 'q': printf("'%s' in parents", a:_.id)}).content)
  if has_key(res, 'error')
    if res.error.code != 401 || a:0 != 0
      return ['error', res.error.message]
    endif
    if !s:refresh_token()
      return ['error', v:errmsg]
    endif
    return s:read_list(a:_, 1)
  endif
  for item in res.items
    if item.labels.trashed != 0
      continue
    endif
    let title = item.title
    let file = item.id
    if item.mimeType == 'application/vnd.google-apps.folder'
      let title .= '/'
      let file .= '/'
    endif
    if len(a:_.path) == 0
      let file = '/' . file
    else
      let file = a:_.path . file
    endif
    call add(result, {
    \    'label': title,
    \    'fakepath': printf('%s:%s', a:_.scheme, file)
    \ })
  endfor
  return ['browse', result]
endfunction

let s:configfile = expand('~/.vim-metarw-gdrive-vim')

function! s:load_settings()
  if !exists('s:settings')
    let s:settings = {}
    if filereadable(s:configfile)
      silent! sandbox let s:settings = eval(join(readfile(s:configfile), ''))
    else
      let v:errmsg = "[Please setup with :GdriveSetup] "
      return 0
    endif
  endif
  return 1
endfunction

function! s:save_settings()
  call writefile([string(s:settings)], s:configfile)
endfunction

function! s:revoke()
  call remove(s:settings, 'access_token')
  call s:save_settings()
endfunction

function! metarw#gdrive#authenticate()
  "let auth_url = 'https://accounts.google.com/o/oauth2/auth?client_id=557347129504.apps.googleusercontent.com&redirect_uri=urn:ietf:wg:oauth:2.0:oob&scope=https://www.googleapis.com/auth/drive&response_type=code'
  let auth_url = 'http://j.mp/SFggCi'
  echo "Access ".auth_url."\nand type the code that show in the browser into below."
  if has('win32') || has('win64')
    silent! exe '!start rundll32 url.dll,FileProtocolHandler '.auth_url
  else
    call system('xdg-open '''.auth_url.'''')
  endif
  let code = input('CODE: ')
  if len(code) == 0
    return
  endif
  let res = webapi#http#post('https://accounts.google.com/o/oauth2/token', {'client_id': '557347129504.apps.googleusercontent.com', 'client_secret': 'C9SVT4PHZe_U_wRSWJK67zUA', 'code': code, 'redirect_uri': 'urn:ietf:wg:oauth:2.0:oob', 'grant_type': 'authorization_code'})
  silent! unlet s:settings
  let s:settings = webapi#json#decode(res.content)
  call s:save_settings()
endfunction

let s:extmap = {
\".adb": "ada",
\".ahk": "ahk",
\".arc": "arc",
\".as": "actionscript",
\".asm": "asm",
\".asp": "asp",
\".aw": "php",
\".b": "b",
\".bat": "bat",
\".befunge": "befunge",
\".bmx": "bmx",
\".boo": "boo",
\".c-objdump": "c-objdump",
\".c": "c",
\".cfg": "cfg",
\".cfm": "cfm",
\".ck": "ck",
\".cl": "cl",
\".clj": "clj",
\".cmake": "cmake",
\".coffee": "coffee",
\".cpp": "cpp",
\".cppobjdump": "cppobjdump",
\".cs": "csharp",
\".css": "css",
\".cw": "cw",
\".cxx": "cpp",
\".d-objdump": "d-objdump",
\".d": "d",
\".darcspatch": "darcspatch",
\".diff": "diff",
\".duby": "duby",
\".dylan": "dylan",
\".e": "e",
\".ebuild": "ebuild",
\".eclass": "eclass",
\".el": "lisp",
\".erb": "erb",
\".erl": "erlang",
\".f90": "f90",
\".factor": "factor",
\".feature": "feature",
\".fs": "fs",
\".fy": "fy",
\".go": "go",
\".groovy": "groovy",
\".gs": "gs",
\".gsp": "gsp",
\".haml": "haml",
\".hs": "haskell",
\".html": "html",
\".hx": "hx",
\".ik": "ik",
\".ino": "ino",
\".io": "io",
\".j": "j",
\".java": "java",
\".js": "javascript",
\".json": "json",
\".jsp": "jsp",
\".kid": "kid",
\".lhs": "lhs",
\".lisp": "lisp",
\".ll": "ll",
\".lua": "lua",
\".ly": "ly",
\".m": "objc",
\".mak": "mak",
\".man": "man",
\".mao": "mao",
\".matlab": "matlab",
\".md": "markdown",
\".minid": "minid",
\".ml": "ml",
\".moo": "moo",
\".mu": "mu",
\".mustache": "mustache",
\".mxt": "mxt",
\".myt": "myt",
\".n": "n",
\".nim": "nim",
\".nu": "nu",
\".numpy": "numpy",
\".objdump": "objdump",
\".ooc": "ooc",
\".parrot": "parrot",
\".pas": "pas",
\".pasm": "pasm",
\".pd": "pd",
\".phtml": "phtml",
\".pir": "pir",
\".pm": "perl",
\".pl": "perl",
\".psgi": "perl",
\".po": "po",
\".py": "python",
\".pytb": "pytb",
\".pyx": "pyx",
\".r": "r",
\".raw": "raw",
\".rb": "ruby",
\".rhtml": "rhtml",
\".rkt": "rkt",
\".rs": "rs",
\".rst": "rst",
\".s": "s",
\".sass": "sass",
\".sc": "sc",
\".scala": "scala",
\".scm": "scheme",
\".scpt": "scpt",
\".scss": "scss",
\".self": "self",
\".sh": "sh",
\".sml": "sml",
\".sql": "sql",
\".st": "smalltalk",
\".tcl": "tcl",
\".tcsh": "tcsh",
\".tex": "tex",
\".textile": "textile",
\".tpl": "smarty",
\".twig": "twig",
\".txt" : "text",
\".v": "verilog",
\".vala": "vala",
\".vb": "vbnet",
\".vhd": "vhdl",
\".vim": "vim",
\".weechatlog": "weechatlog",
\".xml": "xml",
\".xq": "xquery",
\".xs": "xs",
\".yml": "yaml",
\}
