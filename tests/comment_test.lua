-- Run from the repo root: nvim -l tests/comment_test.lua
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local ow = require('overwatch')

-- file comments for lines outside the diff: permalink + code + text, read back to their lines
local gh = require('overwatch.gh')
local pr = { url = 'https://github.com/o/r/pull/304', headRefOid = 'abc123' }
local body = gh._file_comment_body(pr, { path = 'm/precompute.py', l1 = 340, l2 = 349, body = 'Own function?\nSecond line', snippet = { 'def check_spec():', '    pass' }, ft = 'python' })
assert(body == table.concat({
  '[`m/precompute.py#L340-L349`](https://github.com/o/r/blob/abc123/m/precompute.py#L340-L349)',
  '```python',
  'def check_spec():',
  '    pass',
  '```',
  '',
  'Own function?',
  'Second line',
}, '\n'), body)
local a, b = ow._comment_lines(body)
assert(a == 340 and b == 349)
assert(ow._comment_text(body) == 'Own function?', ow._comment_text(body))
-- a snippet containing ``` gets a longer fence
assert(gh._file_comment_body(pr, { path = 'f', l1 = 1, l2 = 1, body = 'x', snippet = { 'a ``` b' } }):find('\n````\na ``` b\n````\n'))
-- the older "**L340-349:**" form (the comment already on PR #304)
a, b = ow._comment_lines('**L340-349:** Does this need to be its own function?')
assert(a == 340 and b == 349)
assert(ow._comment_text('**L340-349:** Does this need to be its own function?') == 'Does this need to be its own function?')
assert(select(1, ow._comment_lines('**L12:** one line')) == 12)
-- a normal comment has no lines and keeps its text
assert(ow._comment_lines('just a comment') == nil and ow._comment_text('just a comment') == 'just a comment')

-- PR conversation: waiting = someone else wrote it after your latest comment; hidden ones drop out
local function c(who, at, hidden) return { author = { login = who }, createdAt = at, isMinimized = hidden or false, body = '' } end
local convo = ow._convo({ c('agent', '2026-01-03'), c('me', '2026-01-02'), c('agent', '2026-01-01'), c('agent', '2026-01-04', true) }, 'me')
assert(#convo == 3, 'hidden comment dropped')
assert(convo[1].createdAt == '2026-01-01' and convo[3].createdAt == '2026-01-03', 'date order')
assert(not convo[1].waiting and not convo[2].waiting and convo[3].waiting, 'only what came after my latest comment waits')
convo = ow._convo({ c('agent', '2026-01-01'), c('bot', '2026-01-02') }, 'me')
assert(convo[1].waiting and convo[2].waiting, 'never commented: all of theirs waits')

print('ok')
