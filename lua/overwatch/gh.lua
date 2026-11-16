-- Thin async wrappers around the `gh` CLI. Everything runs as the reviewer's own gh auth.
local M = {}

-- cb gets decoded JSON (or raw stdout when it isn't JSON). on_err gets stderr; without it we notify.
local function run(args, cb, on_err)
  vim.system(vim.list_extend({ 'gh' }, args), { text = true }, function(r)
    vim.schedule(function()
      if r.code ~= 0 then
        if on_err then
          return on_err(r.stderr)
        end
        return vim.notify('overwatch: gh ' .. args[1] .. ' failed: ' .. vim.trim(r.stderr), vim.log.levels.ERROR)
      end
      if cb then
        local ok, data = pcall(vim.json.decode, r.stdout, { luanil = { object = true, array = true } })
        cb(ok and data or r.stdout)
      end
    end)
  end)
end

-- n: PR number, or nil for the current branch's PR. cb(nil) when there is none.
function M.pr(n, cb)
  local args = { 'pr', 'view', '--json', 'number,headRefName,headRefOid,baseRefName,url,reviews' }
  if n then
    table.insert(args, 3, tostring(n))
  end
  run(args, cb, function()
    cb(nil)
  end)
end

-- Your GitHub login (cached). cb(nil) if gh can't say.
local me
function M.me(cb)
  if me then
    return cb(me)
  end
  run({ 'api', 'user', '--jq', '.login' }, function(login)
    me = vim.trim(tostring(login))
    cb(me)
  end, function()
    cb(nil)
  end)
end

function M.list(cb)
  run({ 'pr', 'list', '--limit', '50', '--json', 'number,title,headRefName,author' }, cb)
end

local THREADS = [[
query($owner:String!, $repo:String!, $pr:Int!) {
  viewer { login }
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$pr) {
      reviewThreads(first:100) {
        nodes {
          id isResolved isOutdated subjectType path line startLine originalLine originalStartLine
          comments(first:50) { nodes { databaseId author { login } body } }
        }
      }
    }
  }
}]]

-- cb(threads, your login). ponytail: first 100 threads only, paginate if a PR ever has more
function M.threads(pr, cb)
  run({ 'api', 'graphql', '-F', 'owner={owner}', '-F', 'repo={repo}', '-F', 'pr=' .. pr, '-f', 'query=' .. THREADS }, function(d)
    cb(d.data.repository.pullRequest.reviewThreads.nodes, d.data.viewer.login)
  end)
end

-- Body of a file comment standing in for a line comment GitHub won't take (lines outside the
-- diff): a permalink to the lines, the code you selected, then what you wrote.
function M._file_comment_body(pr, c)
  local ref = c.l1 == c.l2 and ('L' .. c.l1) or ('L%d-L%d'):format(c.l1, c.l2)
  local repo = pr.url:match('^(.-)/pull/')
  local out = { ('[`%s#%s`](%s/blob/%s/%s#%s)'):format(c.path, ref, repo, pr.headRefOid, c.path, ref) }
  if c.snippet and #c.snippet > 0 then
    local fence = table.concat(c.snippet, '\n'):find('```') and '````' or '```'
    out[#out + 1] = fence .. (c.ft or '')
    vim.list_extend(out, c.snippet)
    out[#out + 1] = fence
  end
  vim.list_extend(out, { '', c.body })
  return table.concat(out, '\n')
end

-- c = { path, l1, l2, body, snippet?, ft? }. Tries, in order: a line comment (lines in the diff);
-- a file comment with the link + code (lines outside the diff); a PR conversation comment with the
-- same (files the PR doesn't touch, which GitHub won't take review comments on at all).
function M.comment(pr, c, cb)
  local endpoint = { 'api', ('repos/{owner}/{repo}/pulls/%d/comments'):format(pr.number), '-f', 'commit_id=' .. pr.headRefOid, '-f', 'path=' .. c.path }
  local args = vim.list_extend(vim.deepcopy(endpoint), { '-f', 'body=' .. c.body, '-F', 'line=' .. c.l2, '-f', 'side=RIGHT' })
  if c.l1 ~= c.l2 then
    vim.list_extend(args, { '-F', 'start_line=' .. c.l1, '-f', 'start_side=RIGHT' })
  end
  local function failed(err)
    vim.notify('overwatch: comment failed: ' .. vim.trim(err), vim.log.levels.ERROR)
  end
  local body = M._file_comment_body(pr, c)
  run(args, cb, function(err)
    if not err:find('422') then
      return failed(err)
    end
    run(vim.list_extend(endpoint, { '-f', 'subject_type=file', '-f', 'body=' .. body }), cb, function(err2)
      if not err2:find('422') then
        return failed(err2)
      end
      run({ 'api', ('repos/{owner}/{repo}/issues/%d/comments'):format(pr.number), '-f', 'body=' .. body }, function(d)
        vim.notify(('overwatch: %s isn\'t part of the PR, so that went to the PR conversation'):format(c.path))
        if cb then
          cb(d)
        end
      end)
    end)
  end)
end

function M.reply(pr, comment_id, body, cb)
  run({ 'api', ('repos/{owner}/{repo}/pulls/%d/comments/%d/replies'):format(pr, comment_id), '-f', 'body=' .. body }, cb)
end

function M.resolve(thread_id, cb)
  run({ 'api', 'graphql', '-f', 'id=' .. thread_id, '-f', 'query=mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id}}}' }, cb)
end

-- kind: 'approve' | 'request-changes' | 'comment'
function M.review(pr, kind, body, cb)
  local args = { 'pr', 'review', tostring(pr), '--' .. kind }
  if body ~= '' then
    vim.list_extend(args, { '--body', body })
  end
  run(args, cb)
end

return M
