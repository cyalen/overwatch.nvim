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

-- PR conversation chains: `Re: <url>` and quote replies join the comment they answer
local function c(id, who, at, body, hidden)
  return { id = 'C' .. id, url = 'https://github.com/o/r/pull/1#issuecomment-' .. id, author = { login = who }, createdAt = at, body = body, isMinimized = hidden or false }
end
local chains = ow._threads({
  c(1, 'agent', '2026-01-01', 'Rebased onto main and force-pushed.'),
  c(2, 'me', '2026-01-02', 'Re: https://github.com/o/r/pull/1#issuecomment-1\n\nwhy rebase?'),
  c(3, 'agent', '2026-01-03', 'Re: https://github.com/o/r/pull/1#issuecomment-2\n\nmain moved'), -- reply to a reply
  c(4, 'agent', '2026-01-04', 'Unrelated: CI is green.'),
  c(5, 'me', '2026-01-05', '> Unrelated: CI is green.\n\nnice'), -- GitHub Quote reply
  c(6, 'agent', '2026-01-06', 'Re: https://example.invalid/whatever#issuecomment-4\nsame chain, other url'),
}, 'me')
assert(#chains == 2, 'two chains, got ' .. #chains)
assert(chains[1].root.id == 'C1' and #chains[1].items == 3, 'Re: chain incl. reply to a reply')
assert(chains[1].waiting, 'agent spoke last in chain 1')
assert(chains[2].root.id == 'C4' and #chains[2].items == 3, 'quote reply and issuecomment-id match join chain 2')
assert(chains[2].waiting, 'agent spoke last in chain 2')
assert(ow._threads({ c(1, 'agent', '2026-01-01', 'a'), c(2, 'me', '2026-01-02', 'Re: x#issuecomment-1') }, 'me')[1].waiting == false, 'my last word: not waiting')
-- hidden: a fully hidden chain drops out; a new reply brings it back
assert(#ow._threads({ c(1, 'agent', '2026-01-01', 'a', true), c(2, 'me', '2026-01-02', 'Re: x#issuecomment-1', true) }, 'me') == 0, 'fully hidden chain dropped')
chains = ow._threads({ c(1, 'agent', '2026-01-01', 'a', true), c(2, 'agent', '2026-01-03', 'Re: x#issuecomment-1\nmore') }, 'me')
assert(#chains == 1 and #chains[1].items == 2 and chains[1].waiting, 'reply to a resolved chain reopens it')
-- unlinked comments are their own chains
assert(#ow._threads({ c(1, 'agent', '2026-01-01', 'a'), c(2, 'agent', '2026-01-02', 'b') }, 'me') == 2, 'unlinked: separate chains')

print('ok')
