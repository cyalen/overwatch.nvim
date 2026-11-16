-- overwatch.nvim: review what changed and leave PR comments on any line, for whatever agent you use.
-- The diff work is all gitsigns; this file holds review state, the file tree, the input float and marks.
local gh = require('overwatch.gh')

local M = {
  -- On start, show only files you haven't seen, or that changed since you ticked them
  -- (diffed against what you saw). false: always the whole PR. `a` in the file list flips it.
  opts = { since_last_review = true },
}
local ns = vim.api.nvim_create_namespace('overwatch')
local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR
local PLUGIN = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
local PROMPT = 'Address the review feedback for this branch by following .overwatch/PROTOCOL.md.'
local SEP = '── reply ──'
local SNIPPET_MAX = 20

local S -- active review: { root, base, pr?, threads, convo, seen_file, tab?, ... }
local convo_render -- the PR conversation buffer's renderer, defined with it below

-- Runs in the reviewed tree while a review is active, so switching tabs doesn't matter.
local function git(...)
  local r = vim.system({ 'git', ... }, { text = true, cwd = S and S.root or nil }):wait()
  return r.code == 0 and vim.trim(r.stdout) or nil
end

local function read(path)
  return vim.uv.fs_stat(path) and vim.fn.readfile(path) or {}
end

-- Your ticks for this branch: .overwatch/<branch>.seen in the reviewed tree.
local function seen_file(root)
  local branch = git('branch', '--show-current')
  return ('%s/.overwatch/%s.seen'):format(root, (branch and branch ~= '') and branch or 'detached')
end

-- Self-ignoring dir with the protocol copied in, so sandboxed agents can read everything inside the repo.
local function ensure(root, file)
  local dir = root .. '/.overwatch'
  vim.fn.mkdir(vim.fs.dirname(file), 'p')
  vim.fn.writefile({ '*' }, dir .. '/.gitignore')
  vim.uv.fs_copyfile(PLUGIN .. '/PROTOCOL.md', dir .. '/PROTOCOL.md')
end

---------------------------------------------------------------------------
-- Marks
---------------------------------------------------------------------------

-- File comments made for lines outside the diff name their lines in the text (a #L12-L20
-- permalink, or the older "**L12-20:**" prefix). Returns them so the mark can sit there.
function M._comment_lines(body)
  local a, b = body:match('#L(%d+)%-L(%d+)')
  if not a then
    a, b = body:match('^%*%*L(%d+)%-?(%d*):')
  end
  if not a then
    a = body:match('#L(%d+)')
  end
  a = tonumber(a)
  return a, tonumber(b) or a
end

-- What you wrote, for the one-line mark: past any permalink line, code block or "**L12-20:**" prefix.
function M._comment_text(body)
  body = (body or ''):gsub('\r', '')
  body = body:gsub('^%[`[^\n]-#L%d[^\n]*\n', '')
  body = body:gsub('^(`+)[^\n]*\n.-\n%1\n?', '')
  body = body:gsub('^%*%*L[%d%-]+:%*%*%s*', '')
  return body:match('^%s*([^\n]*)')
end

-- Colours say whose turn it is: a thread is purple while you have the last word, and yellow once
-- someone else (the agent) does, until you reply or resolve it.
local function render(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if S and buf == S.convo_buf then
    return convo_render()
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local rel = S and vim.bo[buf].buftype == '' and vim.fs.relpath(S.root, vim.api.nvim_buf_get_name(buf))
  if not rel then
    return
  end
  local n = vim.api.nvim_buf_line_count(buf)
  local function mark(lnum, sign, hl, text, replies, author)
    if replies > 0 then
      text = ('%s  (+%d, last @%s)'):format(text, replies, author)
    end
    vim.api.nvim_buf_set_extmark(buf, ns, math.min(lnum, n) - 1, 0, {
      sign_text = sign,
      sign_hl_group = hl,
      virt_text = { { '  ' .. text, hl } },
      priority = 20,
    })
  end
  for _, t in ipairs(S.threads) do
    if t.path == rel then
      local c = t.comments.nodes
      local who = function(x)
        return x.author and x.author.login or 'ghost'
      end
      local text = (t.isOutdated and '(outdated) ' or '') .. '@' .. who(c[1]) .. ': ' .. M._comment_text(c[1].body)
      mark(t.from, '●', t.waiting and 'DiagnosticWarn' or 'DiagnosticHint', text, #c - 1, who(c[#c]))
    end
  end
end

---------------------------------------------------------------------------
-- Seen state. Ticking a file records a snapshot commit of the tree as you saw it
-- (.overwatch/<branch>.seen: "<commit> <path>"). If the file later differs from that snapshot
-- (new commits, a rebase, uncommitted agent edits) it comes back, diffed against the snapshot.
---------------------------------------------------------------------------

local function read_seen()
  local seen = {}
  for _, l in ipairs(read(S.seen_file)) do
    local c, p = l:match('^(%S+) (.+)$')
    if p then
      seen[p] = c
    end
  end
  return seen
end

-- A commit holding the working tree as it is right now (HEAD when clean). Touches nothing.
local function snapshot()
  local stash = git('stash', 'create')
  return stash and stash ~= '' and stash or git('rev-parse', 'HEAD')
end

-- Ticks save immediately. The snapshot records the tree at the moment you saw the file.
-- Unticking puts a file back how it was when this review opened (S.seen0), so undoing a misclick
-- on a file from an earlier review restores that review's tick instead of forgetting it.
local function set_seen(paths, on)
  local seen, snap = read_seen(), on and snapshot() or nil
  for _, p in ipairs(paths) do
    local before = S.seen0[p]
    seen[p] = on and snap or (before ~= seen[p] and before or nil)
  end
  local out = {}
  for p, c in pairs(seen) do
    out[#out + 1] = c .. ' ' .. p
  end
  table.sort(out)
  vim.fn.writefile(out, S.seen_file)
end

-- Files changed against base (working tree included); nil if base is unknown.
local function numstat(base)
  local s = git('diff', '--numstat', '--no-renames', base)
  if not s then
    return nil
  end
  local out = {}
  -- ponytail: paths git has to quote (odd characters) show quoted and won't open
  for l in vim.gsplit(s, '\n', { trimempty = true }) do
    local add, del, path = l:match('^(%S+)\t(%S+)\t(.+)$')
    if path then
      out[#out + 1] = { path = path, add = add, del = del }
    end
  end
  return out
end

-- Tree order: at the first differing path component, directories before files, then by name.
local function tree_lt(a, b)
  local pa, pb = vim.split(a, '/'), vim.split(b, '/')
  for i = 1, math.min(#pa, #pb) do
    if pa[i] ~= pb[i] then
      local da, db = i < #pa, i < #pb
      if da ~= db then
        return da
      end
      return pa[i] < pb[i]
    end
  end
  return #pa < #pb
end

local function base_for(rel)
  return S.bases[rel] or S.base
end

-- Point an attached buffer's gitsigns diff at its file's base.
local function apply_base(buf)
  -- gitsigns' first update fires before the buffer is fully attached (change_base would no-op);
  -- hunk counts in the status dict mean it's ready
  local sd = S and vim.api.nvim_buf_is_loaded(buf) and vim.b[buf].gitsigns_status_dict
  if not (sd and sd.added) then
    return
  end
  local rel = vim.fs.relpath(S.root, vim.api.nvim_buf_get_name(buf))
  local want = rel and base_for(rel)
  if want and (vim.b[buf].overwatch_base or S.base) ~= want then
    vim.b[buf].overwatch_base = want
    vim.api.nvim_buf_call(buf, function()
      require('gitsigns').change_base(want)
    end)
  end
end

-- Your latest submitted review on the PR. The empty COMMENTED reviews GitHub creates behind each
-- single comment don't count: one comment mid-review isn't having reviewed the PR.
function M._last_review(reviews, me)
  local pick
  for _, r in ipairs(reviews or {}) do
    local submitted = r.state == 'APPROVED'
      or r.state == 'CHANGES_REQUESTED'
      or r.state == 'DISMISSED'
      or r.state == 'COMMENTED' and (r.body or '') ~= ''
    if submitted and r.author and r.author.login == me and r.commit and (not pick or r.submittedAt > pick.submittedAt) then
      pick = r
    end
  end
  return pick
end

-- Every file the PR changes, each with a tick state:
--   ' '  not ticked
--   '~'  ticked, but changed since
--   'x'  ticked and unchanged
-- Your last submitted GitHub review (S.reviewed) counts as a tick on every file, unless a local tick
-- is newer.
-- "Since last review" is measured from the ticks as they were when this review opened (S.seen0):
-- a file changed since then gets that snapshot as its diff base (`since`) and counts only what's
-- new. Ticking during the review changes the tick, never the diff you're looking at.
-- Refreshes S.bases, grows S.shown, and re-points open buffers to match.
local function review_files()
  local seen, cache, newer, files = read_seen(), {}, {}, numstat(S.base) or {}
  local waiting = {}
  for _, t in ipairs(S.threads) do
    waiting[t.path] = waiting[t.path] or t.waiting
  end
  -- the newer of a local tick and your GitHub review
  -- ponytail: a local tick older than that review loses to it, as on GitHub
  local function baseline(snap)
    local r = S.reviewed
    if not (r and snap) then
      return snap or r
    end
    if newer[snap] == nil then
      newer[snap] = git('merge-base', '--is-ancestor', r, snap) ~= nil
    end
    return newer[snap] and snap or r
  end
  -- snapshot -> { path -> numstat } of what changed since it; false if the snapshot is gone
  -- (gc'd, or an older .seen format), which counts as never ticked
  local function since(snap)
    if cache[snap] == nil then
      local d = numstat(snap)
      cache[snap] = d and {} or false
      for _, x in ipairs(d or {}) do
        cache[snap][x.path] = x
      end
    end
    return cache[snap]
  end
  table.sort(files, function(a, b)
    return tree_lt(a.path, b.path)
  end)
  S.bases = {}
  for _, f in ipairs(files) do
    f.deleted = not vim.uv.fs_stat(S.root .. '/' .. f.path)
    local b = baseline(seen[f.path])
    local d = b and since(b)
    f.state = not d and ' ' or d[f.path] and '~' or 'x'
    local s0 = baseline(S.seen0[f.path])
    local d0 = s0 and since(s0)
    if d0 and d0[f.path] then
      f.since = s0
      if not S.all then
        f.add, f.del = d0[f.path].add, d0[f.path].del
        S.bases[f.path] = s0
      end
    end
    -- the "since" tree: whatever needed review when you opened it, plus anything that changes
    -- while you're in it, plus files with a thread waiting on you. Ticking doesn't remove a file,
    -- so you can see (and undo) what you ticked.
    if f.state ~= 'x' or waiting[f.path] then
      S.shown[f.path] = true
    end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    apply_base(b)
  end
  return files
end

local function to_review(f)
  return S.all or f.state ~= 'x'
end

-- Quickfix of hunks in the files to review, each against its own base.
local function set_qf(files)
  local groups, items = {}, {}
  for _, f in ipairs(files) do
    if to_review(f) and not f.deleted then
      local b = base_for(f.path)
      groups[b] = groups[b] or {}
      table.insert(groups[b], f.path)
    end
  end
  for b, paths in pairs(groups) do
    local file
    for l in vim.gsplit(git('diff', '-U0', '--no-renames', b, '--', unpack(paths)) or '', '\n') do
      file = l:match('^%+%+%+ b/(.+)$') or file
      local lnum = l:match('^@@ %-%S+ %+(%d+)')
      if lnum and file then
        items[#items + 1] = { path = file, filename = S.root .. '/' .. file, lnum = math.max(tonumber(lnum), 1), text = l:match('^@@.-@@%s*(.*)') }
      end
    end
  end
  table.sort(items, function(a, b)
    if a.path == b.path then
      return a.lnum < b.lnum
    end
    return tree_lt(a.path, b.path)
  end)
  vim.fn.setqflist({}, 'r', { title = 'overwatch', items = items })
  return items
end

local function nav_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if S and S.nav and vim.api.nvim_win_get_buf(w) == S.nav then
      return w
    end
  end
end

-- Directory tree of files (already in tree order). Single-child directory chains collapse into
-- one row ("src/train/"). Rows: { depth, dir = 'name/', files = {...} } or { depth, file = f }.
local function tree_rows(files)
  local root = { dirs = {}, list = {}, files = {} }
  for _, f in ipairs(files) do
    local node, parts = root, vim.split(f.path, '/')
    for i = 1, #parts - 1 do
      if not node.dirs[parts[i]] then
        node.dirs[parts[i]] = { name = parts[i], dirs = {}, list = {}, files = {} }
        table.insert(node.list, node.dirs[parts[i]])
      end
      node = node.dirs[parts[i]]
    end
    table.insert(node.files, f)
  end
  local rows = {}
  local function walk(node, depth, acc)
    for _, d in ipairs(node.list) do
      local name = d.name .. '/'
      while #d.list == 1 and #d.files == 0 do
        d = d.list[1]
        name = name .. d.name .. '/'
      end
      local row = { depth = depth, dir = name, files = {} }
      rows[#rows + 1] = row
      walk(d, depth + 1, row.files)
      vim.list_extend(acc, row.files)
    end
    for _, f in ipairs(node.files) do
      rows[#rows + 1] = { depth = depth, file = f }
      acc[#acc + 1] = f
    end
  end
  walk(root, 0, {})
  return rows
end

-- foldexpr for the file list: each directory row opens a fold holding its contents.
function M._fold(lnum)
  return S and S.nav_folds and S.nav_folds[lnum] or 0
end

function M._since_label()
  if S.all then
    return 'all changes'
  end
  return S.reviewed and ('since your review of ' .. S.reviewed:sub(1, 7)) or 'since last review'
end

local function nav_render()
  if not (S and S.nav and vim.api.nvim_buf_is_valid(S.nav) and nav_win()) then
    return
  end
  local files, threads, waiting = review_files(), {}, {}
  for _, t in ipairs(S.threads) do
    threads[t.path] = (threads[t.path] or 0) + 1
    waiting[t.path] = waiting[t.path] or t.waiting
  end

  local queued = #vim.tbl_filter(function(f)
    return f.state ~= 'x'
  end, files)
  local shown = S.all and files or vim.tbl_filter(function(f)
    return S.shown[f.path]
  end, files)
  local what = S.pr and ('PR #' .. S.pr.number) or 'no PR'
  local status = S.all and ('%d to review · all %d files · a: since'):format(queued, #files)
    or ('%d to review · %d unchanged hidden · a: all'):format(queued, #files - #shown)
  local rows = {
    { line = { { what .. ' · ' .. M._since_label(), 'Title' } } },
    { line = { { status, 'Comment' } } },
  }
  if S.convo and #S.convo > 0 then
    local waiting = #vim.tbl_filter(function(c)
      return c.waiting
    end, S.convo)
    rows[#rows + 1] = {
      convo = true,
      line = { { '💬 PR conversation' }, { ' ●' .. #S.convo, waiting > 0 and 'DiagnosticWarn' or 'DiagnosticHint' } },
    }
  end
  S.nav_folds = {}
  for i = 1, #rows do
    S.nav_folds[i] = 0
  end
  for _, r in ipairs(tree_rows(shown)) do
    local pad = string.rep('  ', r.depth)
    if r.dir then
      r.line = { { pad .. r.dir, 'Directory' } }
      S.nav_folds[#rows + 1] = '>' .. (r.depth + 1)
    else
      local f, st = r.file, r.file.state
      r.line = {
        { pad .. (st == 'x' and '✓ ' or st == '~' and '◐ ' or '○ '), st == 'x' and 'DiagnosticOk' or st == '~' and 'DiagnosticWarn' or 'Comment' },
        { vim.fs.basename(f.path), f.deleted and 'Removed' or nil },
        { f.add == '-' and ' bin' or f.add ~= '0' and (' +' .. f.add) or '', 'Added' },
        { f.del ~= '-' and f.del ~= '0' and (' -' .. f.del) or '', 'Removed' },
        { threads[f.path] and (' ●' .. threads[f.path]) or '', waiting[f.path] and 'DiagnosticWarn' or 'DiagnosticHint' },
      }
      S.nav_folds[#rows + 1] = r.depth
    end
    rows[#rows + 1] = r
  end
  S.nav_rows = rows

  local lines, marks = {}, {}
  for i, row in ipairs(rows) do
    local text = ''
    for _, c in ipairs(row.line) do
      if c[2] and c[1] ~= '' then
        marks[#marks + 1] = { i - 1, #text, #text + #c[1], c[2] }
      end
      text = text .. c[1]
    end
    lines[i] = text
  end
  vim.bo[S.nav].modifiable = true
  vim.api.nvim_buf_set_lines(S.nav, 0, -1, false, lines)
  vim.bo[S.nav].modifiable = false
  local nsn = vim.api.nvim_create_namespace('overwatch_nav')
  vim.api.nvim_buf_clear_namespace(S.nav, nsn, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(S.nav, nsn, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
end

-- Repo path of the file a buffer shows: a normal file, or the read-only view of a deleted one.
local function buf_rel(buf, root)
  local name = vim.api.nvim_buf_get_name(buf)
  root = root or (S and S.root)
  return name:match('^overwatch://deleted/(.+)$') or (root and vim.fs.relpath(root, name))
end

local function is_base_pane(w)
  return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match('^gitsigns://') ~= nil
end

-- Close the side-by-side base panes in this tab and turn diff mode off. True if there were any.
local function close_split()
  local had = false
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_base_pane(w) then
      vim.api.nvim_win_close(w, true)
      had = true
    end
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[w].diff then
      vim.api.nvim_win_call(w, function()
        vim.cmd.diffoff()
      end)
    end
  end
  return had
end

-- Where files open: the current window if it's an ordinary one, else the side-by-side file pane,
-- the window you came from, or the first ordinary window. Never the file tree, a base pane or the
-- goto pane.
local function file_window()
  local nav = nav_win()
  local function ok(w)
    return w ~= 0
      and w ~= nav
      and w ~= (S and S.goto_win)
      and vim.api.nvim_win_is_valid(w)
      and vim.api.nvim_win_get_config(w).relative == ''
      and not is_base_pane(w)
  end
  local wins, cur = vim.api.nvim_tabpage_list_wins(0), vim.api.nvim_get_current_win()
  if ok(cur) then
    return cur
  end
  for _, w in ipairs(wins) do
    if ok(w) and vim.wo[w].diff then
      return w
    end
  end
  local prev = vim.fn.win_getid(vim.fn.winnr('#'))
  if ok(prev) then
    return prev
  end
  for _, w in ipairs(wins) do
    if ok(w) then
      return w
    end
  end
end

-- Open a changed file in the main window (deleted files show their base version, read-only).
-- With the side-by-side view open, its base pane follows (see follow_split).
local function open_file(f)
  local target = file_window()
  if not target then
    vim.cmd('rightbelow vnew')
    target = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(target)
  if not f.deleted then
    return vim.cmd.edit(vim.fn.fnameescape(S.root .. '/' .. f.path))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(git('show', S.base .. ':' .. f.path) or '', '\n'))
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = vim.filetype.match({ filename = f.path }) or ''
  vim.api.nvim_win_set_buf(target, buf)
  -- named after it's shown: an earlier view of the same file has been wiped by then
  pcall(vim.api.nvim_buf_set_name, buf, 'overwatch://deleted/' .. f.path)

  local by = git('log', '--diff-filter=D', '-1', '--format=%h (%s)', S.base .. '..HEAD', '--', f.path)
  local msg = (' %s was deleted %s '):format(f.path, by and by ~= '' and ('in commit ' .. by) or '(not committed yet)')
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { msg })
  local width = vim.api.nvim_win_get_width(target)
  local float = vim.api.nvim_open_win(fbuf, false, {
    relative = 'win',
    win = target,
    anchor = 'NE',
    row = 0,
    col = width,
    width = math.min(vim.fn.strdisplaywidth(msg), width - 2),
    height = 1,
    style = 'minimal',
    border = 'rounded',
    focusable = false,
    zindex = 45,
  })
  vim.wo[float].winhighlight = 'NormalFloat:DiagnosticWarn,FloatBorder:DiagnosticWarn'
  vim.api.nvim_create_autocmd('BufWinLeave', {
    buffer = buf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_win_close, float, true)
    end,
  })
end

---------------------------------------------------------------------------
-- PR conversation: comments on the PR itself rather than on code. In the tree it's a row; <CR> opens
-- it in the main window, where <leader>rc replies, <leader>rx hides a comment as resolved and
-- ]r / [r move between comments.
---------------------------------------------------------------------------

-- Unhidden comments in date order, each `waiting` when someone else wrote it after your own latest
-- comment (all of theirs, if you never commented).
function M._convo(comments, me)
  local mine, out = '', {}
  for _, c in ipairs(comments or {}) do
    if not c.isMinimized then
      out[#out + 1] = c
      if c.author and c.author.login == me and c.createdAt > mine then
        mine = c.createdAt
      end
    end
  end
  for _, c in ipairs(out) do
    c.waiting = not (c.author and c.author.login == me) and c.createdAt > mine
  end
  table.sort(out, function(a, b)
    return a.createdAt < b.createdAt
  end)
  return out
end

local function who(c)
  return c.author and c.author.login or 'ghost'
end

convo_render = function()
  local buf = S and S.convo_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local lines, rows, heads = {}, {}, {}
  for _, c in ipairs(S.convo or {}) do
    lines[#lines + 1] = ('@%s · %s'):format(who(c), (c.createdAt:gsub('T', ' ')):sub(1, 16))
    heads[#heads + 1] = { #lines, c }
    rows[#lines] = c
    for _, l in ipairs(vim.split((c.body:gsub('\r', '')), '\n')) do
      lines[#lines + 1] = l
      rows[#lines] = c
    end
    lines[#lines + 1] = ''
  end
  if #lines == 0 then
    lines = { 'No PR-level comments.' }
  end
  S.convo_rows, S.convo_heads = rows, heads
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(heads) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1] - 1, 0, {
      sign_text = '●',
      sign_hl_group = h[2].waiting and 'DiagnosticWarn' or 'DiagnosticHint',
      end_col = #lines[h[1]],
      hl_group = 'Title',
    })
  end
end

-- Open the conversation in the main window, on the first comment waiting on you (else the last).
local function open_convo()
  if not (S.convo_buf and vim.api.nvim_buf_is_valid(S.convo_buf)) then
    S.convo_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[S.convo_buf].filetype = 'markdown'
    pcall(vim.api.nvim_buf_set_name, S.convo_buf, 'overwatch://conversation')
  end
  local target = file_window()
  if not target then
    vim.cmd('rightbelow vnew')
    target = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(target)
  vim.api.nvim_win_set_buf(target, S.convo_buf)
  convo_render()
  local land
  for _, h in ipairs(S.convo_heads) do
    land = land or (h[2].waiting and h[1])
  end
  land = land or (S.convo_heads[#S.convo_heads] or { 1 })[1]
  vim.api.nvim_win_set_cursor(target, { land, 0 })
end

-- Once, on start: with no code to review but PR comments waiting on you, open the conversation.
-- Runs when both the quickfix (S.empty) and the comments (S.convo) are known, whichever is last.
local function maybe_open_convo()
  if not (S and S.convo and S.empty ~= nil) or S.convo_checked then
    return
  end
  S.convo_checked = true
  local n = #vim.tbl_filter(function(c)
    return c.waiting
  end, S.convo)
  if n == 0 then
    return
  end
  if S.empty then
    open_convo()
  end
  vim.notify(('overwatch: %d PR-level comment%s waiting on you%s'):format(n, n == 1 and '' or 's', S.empty and '' or ' (💬 in the file tree)'))
end

function M.files()
  if not S then
    return vim.notify('overwatch: start a review first', WARN)
  end
  local w = nav_win()
  if w then
    return vim.api.nvim_win_close(w, true)
  end
  if not (S.nav and vim.api.nvim_buf_is_valid(S.nav)) then
    S.nav = vim.api.nvim_create_buf(false, true)
    vim.bo[S.nav].filetype = 'overwatch'
    local function map(lhs, fn)
      vim.keymap.set('n', lhs, fn, { buffer = S.nav, nowait = true })
    end
    local function under_cursor()
      return S.nav_rows and S.nav_rows[vim.fn.line('.')]
    end
    map('<CR>', function()
      local r = under_cursor()
      if r and r.convo then
        open_convo()
      elseif r and r.file then
        open_file(r.file)
      elseif r and r.dir then
        vim.cmd('normal! za')
      end
    end)
    -- x on a file ticks it; on a directory, ticks everything in it (or unticks, if all were ticked)
    map('x', function()
      local r = under_cursor()
      local fs = r and (r.file and { r.file } or r.files)
      if not fs then
        return
      end
      local all_seen = #vim.tbl_filter(function(f)
        return f.state ~= 'x'
      end, fs) == 0
      set_seen(vim.tbl_map(function(f)
        return f.path
      end, fs), not all_seen)
      nav_render()
      vim.cmd('normal! j')
    end)
    map('a', function()
      S.all = not S.all
      set_qf(review_files())
      nav_render()
    end)
    map('R', nav_render)
    map('q', M.files)
  end
  local win = vim.api.nvim_open_win(S.nav, true, { split = 'left', win = -1 })
  local wo = {
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    wrap = false,
    cursorline = true,
    winfixwidth = true,
    winfixbuf = true,
    foldmethod = 'expr',
    foldexpr = "v:lua.require'overwatch'._fold(v:lnum)",
    foldtext = '',
    foldlevel = 99,
    foldcolumn = '1',
    -- foldinner: no nesting-level digits in the fold column for nested directories
    fillchars = 'fold: ,foldopen:▾,foldclose:▸,foldsep: ,foldinner: ,eob: ',
  }
  for k, v in pairs(wo) do
    vim.wo[win][k] = v
  end
  nav_render()
  local width = 0
  for _, l in ipairs(vim.api.nvim_buf_get_lines(S.nav, 0, -1, false)) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  -- ponytail: capped at 40 columns; long names clip (the full path is in the statusline once opened)
  vim.api.nvim_win_set_width(win, math.min(width + 2, 40, math.floor(vim.o.columns / 3)))
  for i, r in ipairs(S.nav_rows) do
    if r.file then
      vim.api.nvim_win_set_cursor(win, { i, 0 })
      break
    end
  end
end

-- Done with this file: tick it seen and open the next unseen one.
function M.seen()
  if not S then
    return vim.notify('overwatch: start a review first', WARN)
  end
  -- the file you're on, even if the cursor is in the side-by-side base pane or the tree
  local w = file_window()
  local rel = w and buf_rel(vim.api.nvim_win_get_buf(w))
  local files, cur = review_files(), 0
  for i, f in ipairs(files) do
    if f.path == rel then
      cur = i
      f.state = 'x'
      set_seen({ rel }, true)
    end
  end
  for k = 1, #files do
    local f = files[(cur + k - 1) % #files + 1]
    if f.state ~= 'x' then
      open_file(f)
      nav_render()
      return
    end
  end
  nav_render()
  vim.notify(('overwatch: all %d files seen'):format(#files))
end

local function render_all()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      render(b)
    end
  end
  nav_render()
end

local function refresh()
  if not (S and S.pr) then
    return render_all()
  end
  gh.threads(S.pr.number, function(nodes, me, comments)
    if S then
      S.me = me
      S.convo = M._convo(comments, me)
      S.threads = vim.tbl_filter(function(t)
        return not t.isResolved
      end, nodes)
      for _, t in ipairs(S.threads) do
        -- outdated threads lose `line`: pin them where they were written; file comments sit on the
        -- lines they name (else line 1)
        -- ponytail: an outdated thread's original line can drift from the code it meant
        if t.subjectType == 'FILE' then -- GitHub puts these on line 1
          local a, b = M._comment_lines(t.comments.nodes[1] and t.comments.nodes[1].body or '')
          t.from, t.to = a or 1, b or 1
        else
          t.to = t.line or t.originalLine or 1
          t.from = t.line and (t.startLine or t.line) or t.originalStartLine or t.to
        end
        local last = t.comments.nodes[#t.comments.nodes]
        t.waiting = not (last and last.author and last.author.login == me)
      end
      render_all()
      maybe_open_convo()
    end
  end)
end

---------------------------------------------------------------------------
-- Input float
---------------------------------------------------------------------------

-- cb(lines) with the text typed below the separator; empty input is dropped unless allow_empty.
local function input(title, context, cb, allow_empty)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'markdown'
  local lines = #context > 0 and vim.list_extend(vim.deepcopy(context), { SEP, '' }) or { '' }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = math.min(80, vim.o.columns - 4),
    height = math.min(math.max(#lines + 4, 6), 20),
    border = 'rounded',
    style = 'minimal',
    title = ' ' .. title .. ' ',
    footer = ' <CR> send · q cancel ',
    footer_pos = 'right',
  })
  vim.wo[win].wrap = true
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })
  vim.cmd.startinsert()

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  -- q only: an <Esc> cancel would eat the comment on a habitual double-Esc
  vim.keymap.set('n', 'q', close, { buffer = buf })
  vim.keymap.set('n', '<CR>', function()
    local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local start = 1
    for i, l in ipairs(all) do
      if l == SEP then
        start = i + 1
      end
    end
    local text = vim.list_slice(all, start)
    while text[1] and not text[1]:match('%S') do
      table.remove(text, 1)
    end
    while text[#text] and not text[#text]:match('%S') do
      table.remove(text)
    end
    close()
    if #text > 0 or allow_empty then
      cb(text)
    end
  end, { buffer = buf })
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function range()
  if vim.fn.mode():match('^[vV\22]') then
    local a, b = vim.fn.line('v'), vim.fn.line('.')
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
    return math.min(a, b), math.max(a, b)
  end
  local l = vim.fn.line('.')
  return l, l
end

-- root and buffer path relative to it, or nil after notifying.
local function here()
  local root = S and S.root or git('rev-parse', '--show-toplevel')
  if not root then
    return vim.notify('overwatch: not in a git repo', ERROR)
  end
  local rel = buf_rel(0, root)
  if not rel then
    return vim.notify('overwatch: this buffer is not a file in the repo', WARN)
  end
  return root, rel
end

local function thread_at(rel, lnum)
  for _, t in ipairs(S and S.threads or {}) do
    if t.path == rel and t.from <= lnum and lnum <= t.to then
      return t
    end
  end
end

local function thread_lines(t)
  local out = {}
  for _, c in ipairs(t.comments.nodes) do
    out[#out + 1] = '@' .. (c.author and c.author.login or 'ghost') .. ':'
    vim.list_extend(out, vim.split((c.body:gsub('\r', '')), '\n'))
    out[#out + 1] = ''
  end
  return out
end

-- base: rev to diff against (default: merge-base with the PR's base). n: PR number (default: this branch's PR).
-- tab: a tab we opened for this review, closed again on stop.
function M.start(base, n, tab)
  local root = git('rev-parse', '--show-toplevel')
  if not root then
    return vim.notify('overwatch: not in a git repo', ERROR)
  end
  gh.pr(n, function(pr)
    gh.me(function(me)
      M._begin(root, base, n, tab, pr, me)
    end)
  end)
end

function M._begin(root, base, n, tab, pr, me)
  if not base then
    local ref = pr and ('origin/' .. pr.baseRefName) or git('rev-parse', '--abbrev-ref', 'origin/HEAD')
    base = ref and git('merge-base', 'HEAD', ref)
    if not base then
      return vim.notify('overwatch: no base found, pass one: :Overwatch <rev>', ERROR)
    end
  end
  local file = seen_file(root)
  local rv = pr and me and M._last_review(pr.reviews, me)
  local reviewed = rv and rv.commit.oid
  if reviewed and not git('cat-file', '-e', reviewed .. '^{commit}') then
    git('fetch', '-q', 'origin', reviewed)
    if not git('cat-file', '-e', reviewed .. '^{commit}') then
      vim.notify(('overwatch: your last review was on %s, which isn\'t available locally; using your local ticks only'):format(reviewed:sub(1, 8)), WARN)
      reviewed = nil
    end
  end
  S = {
    root = root,
    base = base,
    pr = pr,
    reviewed = reviewed,
    threads = {},
    seen_file = file,
    tab = tab,
    bases = {},
    shown = {},
    all = not M.opts.since_last_review,
  }
  ensure(root, file)
  S.seen0 = read_seen()

  local gs = require('gitsigns')
  gs.change_base(base, true, function()
    vim.schedule(function()
      if not S then
        return
      end
      gs.toggle_linehl(true)
      gs.toggle_word_diff(true)
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        vim.b[b].overwatch_base = nil -- the global change just put every buffer on `base`
      end
      local files = review_files()
      local qf = set_qf(files)
      S.empty = #qf == 0
      if n and #qf > 0 then
        vim.cmd.cfirst()
      end
      local todo = #vim.tbl_filter(to_review, files)
      local what = pr and ('PR #' .. pr.number) or 'no PR'
      vim.notify(('overwatch: %s · %d of %d files to review, %d hunks (%s)'):format(what, todo, #files, #qf, M._since_label()))
      maybe_open_convo()
    end)
  end)
  if pr and git('rev-parse', 'HEAD') ~= pr.headRefOid then
    vim.notify('overwatch: local HEAD is not the PR head; comments may land on the wrong lines', WARN)
  end
  refresh()
end

function M.stop()
  local gs = require('gitsigns')
  gs.reset_base(true)
  gs.toggle_linehl(false)
  gs.toggle_word_diff(false)
  local tab, nav, convo = S and S.tab, S and S.nav, S and S.convo_buf
  S = nil
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    vim.b[b].overwatch_base = nil
  end
  render_all()
  if nav and vim.api.nvim_buf_is_valid(nav) then
    for _, w in ipairs(vim.fn.win_findbuf(nav)) do
      pcall(vim.api.nvim_win_close, w, true)
    end
    pcall(vim.api.nvim_buf_delete, nav, { force = true })
  end
  if convo and vim.api.nvim_buf_is_valid(convo) then
    pcall(vim.api.nvim_buf_delete, convo, { force = true })
  end
  if tab and vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd.tabclose, vim.api.nvim_tabpage_get_number(tab))
  end
end

-- <leader>rr: end the review; or review this branch's PR right here; or, with none, pick a PR.
function M.toggle()
  if S then
    return M.stop()
  end
  gh.pr(nil, function(pr)
    if pr then
      M.start()
    else
      M.pr()
    end
  end)
end

local function worktree_for(branch)
  local path
  for l in vim.gsplit(git('worktree', 'list', '--porcelain') or '', '\n') do
    path = l:match('^worktree (.+)') or path
    if l == 'branch refs/heads/' .. branch then
      return path
    end
  end
end

local function open_tree(path, n)
  if S then
    M.stop()
  end
  local tab
  if git('rev-parse', '--show-toplevel') ~= path then
    vim.cmd.tabnew()
    vim.cmd.tcd(vim.fn.fnameescape(path))
    tab = vim.api.nvim_get_current_tabpage()
  end
  M.start(nil, n, tab)
end

-- Review PR n without touching this checkout: use the worktree that already has its branch
-- (e.g. the agent's), else check it out into a fresh one. No n: pick from open PRs.
function M.pr(n)
  if not n then
    return gh.list(function(prs)
      vim.ui.select(prs, {
        prompt = 'Review PR',
        format_item = function(p)
          return ('#%d %s  (%s, @%s)'):format(p.number, p.title, p.headRefName, p.author.login)
        end,
      }, function(p)
        if p then
          vim.schedule(function()
            M.pr(p.number)
          end)
        end
      end)
    end)
  end
  gh.pr(n, function(pr)
    if not pr then
      return vim.notify('overwatch: no PR #' .. n, ERROR)
    end
    local path = worktree_for(pr.headRefName)
    if path then
      return open_tree(path, n)
    end
    -- ponytail: fresh worktrees are left in place; `git worktree remove .overwatch/pr-N` when done
    local main = vim.fs.dirname(git('rev-parse', '--path-format=absolute', '--git-common-dir'))
    path = ('%s/.overwatch/pr-%d'):format(main, n)
    vim.fn.mkdir(main .. '/.overwatch', 'p')
    vim.fn.writefile({ '*' }, main .. '/.overwatch/.gitignore')
    if not git('worktree', 'add', '--detach', path) then
      return vim.notify('overwatch: could not create worktree ' .. path, ERROR)
    end
    vim.notify(('overwatch: checking out PR #%d into %s'):format(n, path))
    vim.system({ 'gh', 'pr', 'checkout', tostring(n) }, { cwd = path, text = true }, function(r)
      vim.schedule(function()
        if r.code ~= 0 then
          return vim.notify('overwatch: gh pr checkout failed: ' .. vim.trim(r.stderr), ERROR)
        end
        open_tree(path, n)
      end)
    end)
  end)
end

-- Full-file side-by-side for the file window, against the file's review base. Says why when nothing
-- can be shown, unless quiet (when it's only following you between files).
local function open_split(quiet)
  local w = file_window()
  if not w then
    return
  end
  vim.api.nvim_set_current_win(w)
  local buf = vim.api.nvim_win_get_buf(w)
  local function why(msg)
    if not quiet then
      vim.notify('overwatch: ' .. msg, WARN)
    end
  end
  if vim.bo[buf].buftype ~= '' then
    return why('side-by-side needs a file in the repo, not ' .. vim.api.nvim_buf_get_name(buf))
  end
  -- gitsigns silently refuses a window still in diff mode, e.g. left over after its base pane closed
  if vim.wo[w].diff then
    vim.cmd.diffoff()
  end
  local sd = vim.b[buf].gitsigns_status_dict
  if not (sd and sd.added) then
    if not S then
      return why("gitsigns isn't tracking this file")
    end
    -- just opened, and gitsigns hasn't attached yet: finish when it has (GitSignsUpdate, in setup)
    S.split_for = { win = w, buf = buf, quiet = quiet }
    return
  end
  local rel = S and vim.fs.relpath(S.root, vim.api.nvim_buf_get_name(buf))
  local base = rel and base_for(rel) or nil
  require('gitsigns').diffthis(base, { vertical = true }, function(err)
    vim.schedule(function()
      local shown = false
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        shown = shown or is_base_pane(win)
        if vim.wo[win].diff then
          vim.wo[win].foldenable = false
        end
      end
      if not shown then
        local at = base and (' at ' .. base:sub(1, 7)) or ''
        why(('nothing to compare %s against%s%s'):format(rel or 'this file', at, err and (' (' .. tostring(err) .. ')') or ''))
      end
    end)
  end)
end

-- Toggle side-by-side by what's on screen: base panes showing, close them; otherwise open one. It's
-- a mode: once on, it follows you between files until you toggle it off.
function M.diff()
  if close_split() then
    if S then
      S.split = false
    end
    return
  end
  if S then
    S.split = true
  end
  open_split()
end

-- The side-by-side view follows you: when the file pane moves to another file (<leader>rv, ]q,
-- the tree, :e), swap the base pane for that file's; a non-file (deleted file view) closes it.
local function follow_split(win, buf)
  if not (S and S.split and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf) then
    return
  end
  if is_base_pane(win) or win == nav_win() or win == S.goto_win then
    return
  end
  local rel = vim.bo[buf].buftype == '' and vim.fs.relpath(S.root, vim.api.nvim_buf_get_name(buf))
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
    if rel and name:match('^gitsigns://') and name:sub(-#rel - 1) == ':' .. rel then
      return -- already paired with this file
    end
  end
  close_split()
  if rel then
    -- diffthis needs gitsigns attached, and a file that was just opened isn't yet: finish on its
    -- first update (see setup)
    S.split_for = { win = win, buf = buf, quiet = true }
    local sd = vim.b[buf].gitsigns_status_dict
    if sd and sd.added then
      M._resplit(buf)
    end
  end
end

function M._resplit(buf)
  local want = S and S.split_for
  if not (want and want.buf == buf) then
    return
  end
  S.split_for = nil
  if vim.api.nvim_win_is_valid(want.win) and vim.api.nvim_win_get_buf(want.win) == buf then
    vim.api.nvim_set_current_win(want.win)
    open_split(want.quiet)
  end
end

-- Goto during a review (wrap a telescope LSP picker, e.g. lsp_definitions): the result opens in one
-- pane to the right, a plain editable buffer, so the file you're reviewing stays put. The lookup
-- still uses your cursor in the review window. Outside a review it just runs the picker.
-- ponytail: a lookup that finds nothing leaves a new pane showing the reviewed file
function M.in_pane(picker)
  if not S then
    return picker()
  end
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  if not (S.goto_win and vim.api.nvim_win_is_valid(S.goto_win)) then
    S.goto_win = vim.api.nvim_open_win(buf, false, { split = 'right', win = win })
    -- a split copies the review window's diff/scrollbind/fold settings; this pane is a plain one
    for k, v in pairs({ diff = false, scrollbind = false, cursorbind = false, foldmethod = 'manual', foldenable = false }) do
      vim.wo[S.goto_win][k] = v
    end
  end
  vim.api.nvim_set_current_win(S.goto_win)
  picker({ bufnr = buf, winnr = win })
end

-- ]q / [q: the next/previous change from the cursor, through the file and on into the next file
-- in tree order. Plain :cnext goes from wherever you last were *in the list*, which falls behind
-- when you move with <leader>rv or the tree. Outside a review it's just :cnext / :cprev.
local function jump(dir)
  local items = S and vim.fn.getqflist() or {}
  if #items == 0 then
    local ok, err = pcall(vim.cmd, dir > 0 and 'cnext' or 'cprev')
    if not ok then
      vim.notify((err:gsub('^.-:E', 'E')), WARN)
    end
    return
  end
  local rel, lnum = buf_rel(0) or '', vim.fn.line('.')
  local function ahead(it) -- is this change after the cursor (dir > 0) or before it?
    local p = vim.fs.relpath(S.root, vim.api.nvim_buf_get_name(it.bufnr)) or ''
    if p == rel then
      return dir > 0 and it.lnum > lnum or dir < 0 and it.lnum < lnum
    end
    return dir > 0 and tree_lt(rel, p) or dir < 0 and tree_lt(p, rel)
  end
  local from, to = 1, #items
  if dir < 0 then
    from, to = #items, 1
  end
  for i = from, to, dir do
    if ahead(items[i]) then
      return vim.cmd('cc ' .. i)
    end
  end
  vim.notify('overwatch: no more changes ' .. (dir > 0 and 'after' or 'before') .. ' this one')
end

function M.next()
  jump(1)
end

function M.prev()
  jump(-1)
end

-- ]r / [r: cycle through the PR threads in this file (the lines carrying their marks).
local function cycle(dir)
  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})) do
    rows[m[2] + 1] = true
  end
  local lines = vim.tbl_keys(rows)
  if #lines == 0 then
    return vim.notify('overwatch: no PR comments in this file')
  end
  table.sort(lines)
  local cur, pick = vim.fn.line('.'), nil
  for i = dir > 0 and 1 or #lines, dir > 0 and #lines or 1, dir do
    if dir > 0 and lines[i] > cur or dir < 0 and lines[i] < cur then
      pick = lines[i]
      break
    end
  end
  vim.api.nvim_win_set_cursor(0, { pick or lines[dir > 0 and 1 or #lines], 0 }) -- wraps around
end

function M.next_comment()
  cycle(1)
end

function M.prev_comment()
  cycle(-1)
end

-- PR comment on the line/range, or a reply if a thread is already there. Inside the diff it's a line
-- comment; outside it, a file comment carrying a link to the lines and the code (see gh.comment).
function M.comment()
  if not (S and S.pr) then
    return vim.notify('overwatch: start a review on a branch with a PR first', WARN)
  end
  if vim.api.nvim_get_current_buf() == S.convo_buf then
    -- a reply links the comment under the cursor, so the agent knows what you're answering
    local c = S.convo_rows and S.convo_rows[vim.fn.line('.')]
    local context = c and vim.list_extend({ '@' .. who(c) .. ':' }, vim.split((c.body:gsub('\r', '')), '\n')) or {}
    return input(c and 'Reply on the PR conversation' or 'PR comment', context, function(text)
      local body = table.concat(text, '\n')
      gh.pr_comment(S.pr.number, c and ('Re: ' .. c.url .. '\n\n' .. body) or body, refresh)
    end)
  end
  local l1, l2 = range()
  local _, rel = here()
  if not rel then
    return
  end
  local t = thread_at(rel, l1)
  if t then
    return input('Reply on PR thread', thread_lines(t), function(text)
      gh.reply(S.pr.number, t.comments.nodes[1].databaseId, table.concat(text, '\n'), refresh)
    end)
  end
  local buf = vim.api.nvim_get_current_buf()
  local snippet = vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false)
  if #snippet > SNIPPET_MAX then
    snippet = vim.list_extend(vim.list_slice(snippet, 1, SNIPPET_MAX), { '...' })
  end
  -- ponytail: RIGHT side only; commenting on deleted lines needs the LEFT side from the base buffer
  input(('PR comment %s:%s'):format(rel, l1 == l2 and l1 or l1 .. '-' .. l2), {}, function(text)
    gh.comment(S.pr, { path = rel, l1 = l1, l2 = l2, body = table.concat(text, '\n'), snippet = snippet, ft = vim.bo[buf].filetype }, refresh)
  end)
end

-- Resolve the PR thread on this line; in the conversation, hide the comment as resolved.
function M.resolve()
  if S and vim.api.nvim_get_current_buf() == S.convo_buf then
    local c = S.convo_rows and S.convo_rows[vim.fn.line('.')]
    if not c then
      return vim.notify('overwatch: no comment under the cursor', WARN)
    end
    return gh.hide(c.id, function()
      vim.notify('overwatch: hid @' .. who(c) .. "'s comment as resolved")
      refresh()
    end)
  end
  local _, rel = here()
  if not rel then
    return
  end
  local t = thread_at(rel, vim.fn.line('.'))
  if not t then
    return vim.notify('overwatch: no open PR thread on this line', WARN)
  end
  gh.resolve(t.id, refresh)
end

-- Bring your own agent: paste this into whatever you run.
function M.handoff()
  local root = S and S.root or git('rev-parse', '--show-toplevel')
  if root then
    ensure(root, seen_file(root))
  end
  vim.fn.setreg('+', PROMPT)
  vim.notify('overwatch: agent prompt copied, paste it into your agent')
end

function M.verdict()
  if not (S and S.pr) then
    return vim.notify('overwatch: start a review on a branch with a PR first', WARN)
  end
  local n = S.pr.number
  vim.ui.select({ 'approve', 'request-changes', 'comment' }, { prompt = 'Review PR #' .. n }, function(kind)
    if not kind then
      return
    end
    vim.schedule(function()
      input(kind .. ' PR #' .. n, {}, function(text)
        gh.review(n, kind, table.concat(text, '\n'), function()
          vim.notify(('overwatch: %s posted on PR #%d'):format(kind, n))
        end)
      end, kind == 'approve')
    end)
  end)
end

function M.setup(opts)
  M.opts = vim.tbl_extend('force', M.opts, opts or {})
  local g = vim.api.nvim_create_augroup('overwatch', {})
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = g,
    callback = function(a)
      local win = vim.api.nvim_get_current_win()
      vim.schedule(function()
        follow_split(win, a.buf)
      end)
    end,
  })
  -- a re-read (:e, a file changed on disk) re-attaches gitsigns on the global base; re-apply ours
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = g,
    callback = function(a)
      vim.b[a.buf].overwatch_base = nil
    end,
  })
  -- gitsigns attaches buffers asynchronously; give each its file's base once it has
  vim.api.nvim_create_autocmd('User', {
    group = g,
    pattern = 'GitSignsUpdate',
    callback = function(a)
      local buf = a.data and a.data.buffer
      if buf then
        apply_base(buf)
        local sd = vim.b[buf].gitsigns_status_dict
        if sd and sd.added then
          vim.schedule(function()
            M._resplit(buf)
          end)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = g,
    callback = function(a)
      render(a.buf)
    end,
  })
  vim.api.nvim_create_autocmd('FocusGained', { group = g, callback = render_all })
  -- any save can change the diff, and so the file tree
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = g,
    callback = function()
      if S then
        render_all()
      end
    end,
  })
  vim.api.nvim_create_user_command('Overwatch', function(o)
    local sub, arg = o.fargs[1], o.fargs[2]
    if sub == 'handoff' then
      return M.handoff()
    elseif sub == 'pr' then
      return M.pr(tonumber(arg))
    elseif not sub then
      return M.toggle()
    end
    if S then
      M.stop()
    end
    M.start(sub)
  end, { nargs = '*', desc = 'Toggle review | <rev>: review against rev | pr [N]: review a PR in its worktree | handoff' })
end

return M
